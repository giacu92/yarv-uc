`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
* UART peripheral (AXI4-Lite slave), 8N1, no FIFO (single-buffer TX/RX).
*
* Register map (word-addressed, byte offsets from the peripheral's base;
* the LSU/bridge only ever issues single-beat, word-aligned accesses):
*
*   0x00 TXDATA  (W)  : write byte[7:0] -> pushes into the TX shift buffer.
*                        Ignored (no effect, no error) if TX is busy — poll
*                        STATUS.TX_READY first. Read returns 0.
*   0x04 RXDATA  (R)  : read byte[7:0] of the last received char and CLEARS
*                        STATUS.RX_READY (read-to-clear, standard UART RX
*                        semantics). Read when RX_READY=0 returns stale
*                        data (undefined from the software contract).
*   0x08 STATUS  (R)  : bit0 TX_READY  (1 = TX buffer free, can accept a byte)
*                        bit1 RX_READY  (1 = a received byte is waiting)
*                        bit2 RX_OVERRUN (1 = a byte arrived while RX_READY
*                             was still set, i.e. software didn't read in
*                             time; sticky, cleared by reading RXDATA)
*   0x0C CTRL    (RW) : bit0 TX_IE (TX-ready interrupt enable)
*                        bit1 RX_IE (RX-ready interrupt enable)
*   0x10 BAUDDIV (RW) : clk_i cycles per bit - 1 (16-bit). Reset value is
*                        BAUD_DIV_RESET (computed from CLK_FREQ_HZ / BAUD_RATE
*                        at elaboration). Software may reprogram it; a write
*                        only takes effect once both TX and RX are idle (a
*                        write mid-transfer is latched but not applied until
*                        the in-flight frame finishes, so it never corrupts
*                        a byte already in flight).
*
* Interrupt: uart_irq_o is LEVEL-SENSITIVE, no separate clear register.
*   uart_irq_o = (STATUS.TX_READY & CTRL.TX_IE) | (STATUS.RX_READY & CTRL.RX_IE)
* Software services it the same way it would poll: write TXDATA (which
* drops TX_READY until the byte ships) or read RXDATA (which drops
* RX_READY). This mirrors msip_peri's philosophy of no hidden edge-detect
* state, at the cost of the ISR needing to actually drain the condition
* (standard for a non-FIFO UART: if you don't feed TX / drain RX, the
* interrupt stays asserted, which is correct behaviour, not a bug).
*
* TX: 1 start bit, 8 data bits (LSB first), 1 stop bit, no parity. Shifts
* out on the falling edge of the baud tick counter (LSB-first shift
* register), busy-flagged for the whole frame (10 bit-times).
*
* RX: start-bit detected on rxd falling edge while idle; samples each
* subsequent bit at mid-period (half the baud divisor after the edge /
* previous sample) for noise margin. Frames with stop bit sampled low are
* silently accepted anyway (no framing-error flag) — add one only if you
* need it; kept out to keep this peripheral minimal.
*
* rxd_i is NOT synchronized/debounced by this module: the caller must hand
* it an already-synchronized signal. An external serial line is asynchronous
* to clk_i by definition (the far-end transmitter has its own oscillator),
* so top_module.sv double-flops the pin before driving rxd_i here. Do the
* same at any other instantiation site -- sampling the raw pin into
* rx_shift_q risks metastability, and there is no framing-error flag to
* catch a corrupted bit.
*
* Protocol follows msip_peri.sv / axi4_lite_ram.sv: registered BVALID held
* until the B handshake, RVALID held until RREADY, single-outstanding
* (AWREADY/WREADY/ARREADY low while a response is pending).
*
* Reset is synchronous, active-low.
*
* Naming: ports *_i/_o; internals no prefix; flops _q, next-state _d.
*/

module axi4_lite_uart #(
    parameter int unsigned CLK_FREQ_HZ = 40e6,
    parameter int unsigned BAUD_RATE   = 115200
) (
    input wire clk_i,
    input wire rstn_i,

    axi4_lite_if.slave axi,

    // UART pins.
    output wire txd_o,
    input  wire rxd_i,

    // Level-sensitive interrupt (see header comment).
    output wire uart_irq_o
);

    localparam int DATA_W = axi.DATA_WIDTH;
    localparam logic [15:0] BAUD_DIV_RESET =
        16'((CLK_FREQ_HZ / BAUD_RATE) - 1);

    // Word offsets (byte addr[4:2], word-aligned; addr[1:0] ignored like
    // the rest of the fabric — every access here is a single 32-bit beat).
    localparam logic [2:0] REG_TXDATA  = 3'd0;
    localparam logic [2:0] REG_RXDATA  = 3'd1;
    localparam logic [2:0] REG_STATUS  = 3'd2;
    localparam logic [2:0] REG_CTRL    = 3'd3;
    localparam logic [2:0] REG_BAUDDIV = 3'd4;

    // =================================================================
    // Divisor. TX and RX each run their own bit-time counter off div_q
    // (tx_baud_cnt_q / rx_cnt_q below) rather than sharing one — TX and
    // RX are independent full-duplex state machines with no reason to
    // share a phase. RX additionally uses a half-period offset for
    // mid-bit sampling (see rx_half_div below).
    // =================================================================
    logic [15:0] div_q;  // live divisor (BAUDDIV, applied when idle)
    logic [15:0] div_pending_q;
    logic        div_pending_valid_q;

    logic [15:0] tx_baud_cnt_q;
    logic        tx_baud_tick;
    assign tx_baud_tick = (tx_baud_cnt_q == div_q);

    // =================================================================
    // TX path
    // =================================================================
    typedef enum logic [1:0] {
        TX_IDLE,
        TX_START,
        TX_DATA,
        TX_STOP
    } tx_state_e;

    tx_state_e       tx_state_q;
    logic      [7:0] tx_shift_q;
    logic      [2:0] tx_bit_cnt_q;
    logic            tx_pending_q;  // a byte is latched, waiting to start
    logic      [7:0] tx_pending_data_q;
    logic            txd_q;

    wire             tx_idle = (tx_state_q == TX_IDLE);
    wire             tx_ready = tx_idle & ~tx_pending_q;  // STATUS.TX_READY

    assign txd_o = txd_q;

    // =================================================================
    // RX path
    // =================================================================
    typedef enum logic [1:0] {
        RX_IDLE,
        RX_START,
        RX_DATA,
        RX_STOP
    } rx_state_e;

    rx_state_e        rx_state_q;
    logic      [ 7:0] rx_shift_q;
    logic      [ 2:0] rx_bit_cnt_q;
    logic      [15:0] rx_cnt_q;  // per-bit sample counter (this state)
    logic      [ 7:0] rx_data_q;  // last completed byte (RXDATA)
    logic             rx_ready_q;  // STATUS.RX_READY
    logic             rx_overrun_q;  // STATUS.RX_OVERRUN (sticky)

    wire              rx_idle = (rx_state_q == RX_IDLE);

    // =================================================================
    // CTRL
    // =================================================================
    logic tx_ie_q, rx_ie_q;

    // =================================================================
    // AXI write path (register-mapped, same accept pattern as msip_peri).
    // =================================================================
    logic              aw_seen_q;
    logic              w_seen_q;
    logic [DATA_W-1:0] wdata_q;
    logic [       2:0] awaddr_word_q;
    logic              bvalid_q;

    assign axi.awready = !aw_seen_q && !bvalid_q;
    assign axi.wready  = !w_seen_q && !bvalid_q;

    wire              aw_hs = axi.awvalid && axi.awready;
    wire              w_hs = axi.wvalid && axi.wready;

    wire              aw_present = aw_seen_q || aw_hs;
    wire              w_present = w_seen_q || w_hs;
    wire              do_write = aw_present && w_present && !bvalid_q;

    wire [       2:0] waddr_eff = aw_hs ? axi.awaddr[4:2] : awaddr_word_q;
    wire [DATA_W-1:0] wdata_eff = w_hs ? axi.wdata : wdata_q;

    assign axi.bvalid = bvalid_q;
    assign axi.bresp  = 2'b00;  // OKAY
    wire b_hs = axi.bvalid && axi.bready;

    // A TX push this cycle: only accepted (has effect) when TX_READY and
    // nothing already pending; otherwise the write still completes on the
    // AXI side (B still returns OKAY) but the byte is dropped, per the
    // register-map contract above.
    wire tx_push = do_write && (waddr_eff == REG_TXDATA) && tx_ready;

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            aw_seen_q           <= 1'b0;
            w_seen_q            <= 1'b0;
            wdata_q             <= '0;
            awaddr_word_q       <= '0;
            bvalid_q            <= 1'b0;
            tx_ie_q             <= 1'b0;
            rx_ie_q             <= 1'b0;
            div_pending_q       <= '0;
            div_pending_valid_q <= 1'b0;
        end else begin
            if (aw_hs) begin
                aw_seen_q     <= 1'b1;
                awaddr_word_q <= axi.awaddr[4:2];
            end
            if (w_hs) begin
                w_seen_q <= 1'b1;
                wdata_q  <= axi.wdata;
            end

            if (do_write) begin
                aw_seen_q <= 1'b0;
                w_seen_q  <= 1'b0;
                bvalid_q  <= 1'b1;

                unique case (waddr_eff)
                    REG_CTRL: begin
                        tx_ie_q <= wdata_eff[0];
                        rx_ie_q <= wdata_eff[1];
                    end
                    REG_BAUDDIV: begin
                        // Latched; applied by the divisor-update block
                        // below only once TX and RX are both idle, so an
                        // in-flight frame is never corrupted.
                        div_pending_q       <= wdata_eff[15:0];
                        div_pending_valid_q <= 1'b1;
                    end
                    default: ;  // TXDATA handled by tx_push; RXDATA/STATUS read-only
                endcase
            end

            if (b_hs) begin
                bvalid_q <= 1'b0;
            end

            // Apply a pending BAUDDIV update once both engines are idle.
            if (div_pending_valid_q && tx_idle && rx_idle) begin
                div_pending_valid_q <= 1'b0;
            end
        end
    end

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            div_q <= BAUD_DIV_RESET;
        end else if (div_pending_valid_q && tx_idle && rx_idle) begin
            div_q <= div_pending_q;
        end
    end

    // =================================================================
    // AXI read path (1-cycle registered latency, same as msip_peri).
    // =================================================================
    logic              rvalid_q;
    logic [DATA_W-1:0] rdata_q;

    assign axi.arready = !rvalid_q || (rvalid_q && axi.rready);
    wire ar_hs = axi.arvalid && axi.arready;

    assign axi.rvalid = rvalid_q;
    assign axi.rdata  = rdata_q;
    assign axi.rresp  = 2'b00;  // OKAY

    logic [DATA_W-1:0] rdata_mux;
    always_comb begin
        unique case (axi.araddr[4:2])
            REG_TXDATA:  rdata_mux = '0;
            REG_RXDATA:  rdata_mux = {24'b0, rx_data_q};
            REG_STATUS:  rdata_mux = {29'b0, rx_overrun_q, rx_ready_q, tx_ready};
            REG_CTRL:    rdata_mux = {30'b0, rx_ie_q, tx_ie_q};
            REG_BAUDDIV: rdata_mux = {16'b0, div_q};
            default:     rdata_mux = '0;
        endcase
    end

    // RXDATA read-to-clear: consumed on the AR handshake that targets it
    // (same cycle the read is launched — matches the "accept = commit"
    // timing the rest of the bus layer uses).
    wire rx_read_clear = ar_hs && (axi.araddr[4:2] == REG_RXDATA);

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            rvalid_q <= 1'b0;
            rdata_q  <= '0;
        end else begin
            if (ar_hs) begin
                rvalid_q <= 1'b1;
                rdata_q  <= rdata_mux;
            end else if (rvalid_q && axi.rready) begin
                rvalid_q <= 1'b0;
            end
        end
    end

    // =================================================================
    // TX engine
    // =================================================================
    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            tx_state_q        <= TX_IDLE;
            tx_shift_q        <= '0;
            tx_bit_cnt_q      <= '0;
            tx_pending_q      <= 1'b0;
            tx_pending_data_q <= '0;
            txd_q             <= 1'b1;  // idle line high
            tx_baud_cnt_q     <= '0;
        end else begin
            // Latch a pushed byte if TX is mid-frame right at the push
            // cycle (tx_push only fires when tx_ready, i.e. TX_IDLE and
            // nothing pending, so this branch normally starts the frame
            // the same cycle; kept as an explicit latch for clarity/
            // future-proofing if tx_push's gating ever changes).
            if (tx_push) begin
                tx_pending_data_q <= wdata_eff[7:0];
                tx_pending_q      <= 1'b1;
            end

            unique case (tx_state_q)
                TX_IDLE: begin
                    tx_baud_cnt_q <= '0;
                    if (tx_pending_q) begin
                        tx_shift_q   <= tx_pending_data_q;
                        tx_pending_q <= 1'b0;
                        tx_state_q   <= TX_START;
                        txd_q        <= 1'b0;  // start bit
                    end
                end

                TX_START: begin
                    if (tx_baud_tick) begin
                        tx_baud_cnt_q <= '0;
                        tx_state_q    <= TX_DATA;
                        tx_bit_cnt_q  <= '0;
                        txd_q         <= tx_shift_q[0];
                    end else begin
                        tx_baud_cnt_q <= tx_baud_cnt_q + 16'd1;
                    end
                end

                TX_DATA: begin
                    if (tx_baud_tick) begin
                        tx_baud_cnt_q <= '0;
                        if (tx_bit_cnt_q == 3'd7) begin
                            tx_state_q <= TX_STOP;
                            txd_q      <= 1'b1;  // stop bit
                        end else begin
                            tx_bit_cnt_q <= tx_bit_cnt_q + 3'd1;
                            tx_shift_q   <= tx_shift_q >> 1;
                            txd_q        <= tx_shift_q[1];
                        end
                    end else begin
                        tx_baud_cnt_q <= tx_baud_cnt_q + 16'd1;
                    end
                end

                TX_STOP: begin
                    if (tx_baud_tick) begin
                        tx_baud_cnt_q <= '0;
                        tx_state_q    <= TX_IDLE;
                    end else begin
                        tx_baud_cnt_q <= tx_baud_cnt_q + 16'd1;
                    end
                end

                default: tx_state_q <= TX_IDLE;
            endcase
        end
    end

    // =================================================================
    // RX engine
    // =================================================================
    wire [15:0] rx_half_div = {1'b0, div_q[15:1]};  // div_q/2, mid-bit offset

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            rx_state_q   <= RX_IDLE;
            rx_shift_q   <= '0;
            rx_bit_cnt_q <= '0;
            rx_cnt_q     <= '0;
            rx_data_q    <= '0;
            rx_ready_q   <= 1'b0;
            rx_overrun_q <= 1'b0;
        end else begin
            // RXDATA read clears RX_READY (and the overrun latch — a
            // fresh read acknowledges the backlog).
            if (rx_read_clear) begin
                rx_ready_q   <= 1'b0;
                rx_overrun_q <= 1'b0;
            end

            unique case (rx_state_q)
                RX_IDLE: begin
                    rx_cnt_q <= '0;
                    if (!rxd_i) begin
                        // Falling edge: candidate start bit. Sample at
                        // mid-bit to confirm (reject glitches shorter
                        // than half a bit period).
                        rx_state_q <= RX_START;
                    end
                end

                RX_START: begin
                    if (rx_cnt_q == rx_half_div) begin
                        rx_cnt_q <= '0;
                        if (!rxd_i) begin
                            // Confirmed start bit; move to data, sampling
                            // each subsequent bit a full period later
                            // (i.e. at its mid-point too).
                            rx_state_q   <= RX_DATA;
                            rx_bit_cnt_q <= '0;
                        end else begin
                            rx_state_q <= RX_IDLE;  // glitch, not a real start
                        end
                    end else begin
                        rx_cnt_q <= rx_cnt_q + 16'd1;
                    end
                end

                RX_DATA: begin
                    if (rx_cnt_q == div_q) begin
                        rx_cnt_q   <= '0;
                        rx_shift_q <= {rxd_i, rx_shift_q[7:1]};  // LSB first
                        if (rx_bit_cnt_q == 3'd7) begin
                            rx_state_q <= RX_STOP;
                        end else begin
                            rx_bit_cnt_q <= rx_bit_cnt_q + 3'd1;
                        end
                    end else begin
                        rx_cnt_q <= rx_cnt_q + 16'd1;
                    end
                end

                RX_STOP: begin
                    if (rx_cnt_q == div_q) begin
                        rx_cnt_q   <= '0;
                        rx_state_q <= RX_IDLE;
                        // Stop bit not checked (no framing-error flag,
                        // see header comment) — commit the byte
                        // regardless.
                        if (rx_ready_q && !rx_read_clear) begin
                            // Previous byte was never read: overrun.
                            rx_overrun_q <= 1'b1;
                        end
                        rx_data_q  <= rx_shift_q;
                        rx_ready_q <= 1'b1;
                    end else begin
                        rx_cnt_q <= rx_cnt_q + 16'd1;
                    end
                end

                default: rx_state_q <= RX_IDLE;
            endcase
        end
    end

    // =================================================================
    // Interrupt (level-sensitive, see header comment).
    // =================================================================
    assign uart_irq_o = (tx_ready & tx_ie_q) | (rx_ready_q & rx_ie_q);

endmodule

`resetall
