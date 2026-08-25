`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
* UART peripheral (AXI4-Lite slave), 8N1, with TX and RX FIFOs.
*
* WHY FIFOS: with a single-byte RX buffer, a full-duplex echo program
* loses input. Echoing a byte with a blocking "poll TX_READY then write
* TXDATA" costs a whole frame time (87 us at 115200), and a terminal that
* ships a typed line in one burst delivers the next byte 87 us after the
* previous one — so every byte that arrives while software is stuck in the
* echo is dropped. That is not a corner case: it is what pasting a line
* into a serial console does, and it made YarvMon look like it ignored
* every command. An RX FIFO absorbs the burst; the TX FIFO stops the echo
* from blocking in the first place. See sim/hw/uart_tb.
*
* Register map (word-addressed, byte offsets from the peripheral's base;
* the LSU/bridge only ever issues single-beat, word-aligned accesses):
*
*   0x00 TXDATA  (W)  : write byte[7:0] -> pushes into the TX FIFO.
*                        If the FIFO is full the write is HELD, not
*                        dropped: AW/W are taken but B is withheld until a
*                        byte ships and room appears (at most one frame
*                        time). Software that polls STATUS.TX_READY first
*                        never sees the stall; software that does not still
*                        loses no data, it only waits. Read returns 0.
*   0x04 RXDATA  (R)  : read byte[7:0] at the head of the RX FIFO and POP
*                        it (read-to-consume, standard UART RX semantics).
*                        Read when RX_READY=0 pops nothing and returns the
*                        stale head (undefined from the software contract).
*   0x08 STATUS  (R)  : bit0 TX_READY  (1 = TX FIFO has room for a byte)
*                        bit1 RX_READY  (1 = at least one received byte is
*                             waiting in the RX FIFO)
*                        bit2 RX_OVERRUN (1 = a byte arrived while the RX
*                             FIFO was full, i.e. software didn't drain in
*                             time; the byte is dropped. Sticky, cleared by
*                             reading RXDATA)
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
* Both enables reset to 0, so a polling program (YarvMon) never sees an
* interrupt until it writes CTRL. Software services the IRQ the same way
* it would poll: fill the TX FIFO (which drops TX_READY once full) or read
* RXDATA until the RX FIFO drains (which drops RX_READY). This mirrors
* msip_peri's philosophy of no hidden edge-detect state, at the cost of
* the ISR needing to actually drain the condition — if you don't, the
* interrupt stays asserted, which is correct behaviour, not a bug.
* NOTE: TX_IE therefore fires on "FIFO not full", i.e. almost always;
* enable it only while you have data queued to send.
*
* TX: 1 start bit, 8 data bits (LSB first), 1 stop bit, no parity. Shifts
* out on the falling edge of the baud tick counter (LSB-first shift
* register). The engine pulls its next byte from the TX FIFO whenever it
* is idle, so queued bytes ship back-to-back with no software involvement.
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
    parameter int unsigned BAUD_RATE = 115200,
    // FIFO depths, in bytes. Must be powers of two >= 2 (the pointer
    // arithmetic below relies on it). 16 bytes of RX covers a pasted
    // command line at 115200 against a byte-at-a-time echo.
    parameter int unsigned TX_FIFO_DEPTH = 16,
    parameter int unsigned RX_FIFO_DEPTH = 16
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
    localparam logic [15:0] BAUD_DIV_RESET = 16'((CLK_FREQ_HZ / BAUD_RATE) - 1);

    // Word offsets (byte addr[4:2], word-aligned; addr[1:0] ignored like
    // the rest of the fabric — every access here is a single 32-bit beat).
    localparam logic [2:0] REG_TXDATA = 3'd0;
    localparam logic [2:0] REG_RXDATA = 3'd1;
    localparam logic [2:0] REG_STATUS = 3'd2;
    localparam logic [2:0] REG_CTRL = 3'd3;
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
    logic            txd_q;

    wire             tx_idle = (tx_state_q == TX_IDLE);

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
    logic             rx_overrun_q;  // STATUS.RX_OVERRUN (sticky)

    wire              rx_idle = (rx_state_q == RX_IDLE);

    // =================================================================
    // TX / RX FIFOs.
    //
    // Plain synchronous ring buffers: one extra pointer bit distinguishes
    // full from empty (wrap bit differs, index equal => full; both equal
    // => empty), which is why the depths must be powers of two. Both are
    // shallow enough that the synthesiser maps them to LUT RAM / flops,
    // not BSRAM (the BSRAMs are spoken for by I-mem, D-mem and the
    // regfile).
    //
    // The head of each FIFO is read combinationally: the TX engine needs
    // its next byte in the same cycle it leaves TX_IDLE, and an RXDATA
    // read must return the head in the cycle the AR handshake latches
    // rdata_q (accept = commit, like the rest of the bus layer).
    // =================================================================
    localparam int TX_PTR_W = $clog2(TX_FIFO_DEPTH);
    localparam int RX_PTR_W = $clog2(RX_FIFO_DEPTH);

    logic [7:0] tx_fifo_q[TX_FIFO_DEPTH];
    logic [7:0] rx_fifo_q[RX_FIFO_DEPTH];

    logic [TX_PTR_W:0] tx_wptr_q, tx_rptr_q;
    logic [RX_PTR_W:0] rx_wptr_q, rx_rptr_q;

    wire tx_fifo_empty = (tx_wptr_q == tx_rptr_q);
    wire tx_fifo_full = (tx_wptr_q[TX_PTR_W] != tx_rptr_q[TX_PTR_W]) &&
        (tx_wptr_q[TX_PTR_W-1:0] == tx_rptr_q[TX_PTR_W-1:0]);

    wire rx_fifo_empty = (rx_wptr_q == rx_rptr_q);
    wire rx_fifo_full = (rx_wptr_q[RX_PTR_W] != rx_rptr_q[RX_PTR_W]) &&
        (rx_wptr_q[RX_PTR_W-1:0] == rx_rptr_q[RX_PTR_W-1:0]);

    wire [7:0] tx_fifo_head = tx_fifo_q[tx_rptr_q[TX_PTR_W-1:0]];
    wire [7:0] rx_fifo_head = rx_fifo_q[rx_rptr_q[RX_PTR_W-1:0]];

    // STATUS flags (see the register map in the header).
    wire tx_ready = !tx_fifo_full;
    wire rx_ready = !rx_fifo_empty;

    // The TX engine consumes a byte the cycle it is idle with the FIFO
    // non-empty; the RX engine produces one at the end of a frame.
    wire tx_fifo_pop = tx_idle && !tx_fifo_empty;

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

    // AWREADY also drops for a TXDATA write while the TX FIFO is full: the
    // address phase is refused outright, so the transaction never enters
    // the peripheral and the backpressure is visible to the master at the
    // first handshake rather than at B. A slave may derive READY from the
    // request payload; the address is only meaningful while AWVALID is
    // high, and the handshake needs both.
    //
    // Only TXDATA is gated. Blocking every write while the FIFO is full
    // would also block CTRL and BAUDDIV, i.e. the registers software would
    // use to change the situation.
    //
    // WREADY is not gated: the write data phase carries no address, so
    // there is nothing to decode -- refusing it would mean refusing every
    // write. Data may therefore be accepted before the address; the
    // do_write hold below covers that ordering.
    wire [2:0] awaddr_in = axi.awaddr[4:2];
    wire tx_full_block_aw = (awaddr_in == REG_TXDATA) && !tx_ready;

    assign axi.awready = !aw_seen_q && !bvalid_q && !tx_full_block_aw;
    assign axi.wready  = !w_seen_q && !bvalid_q;

    wire              aw_hs = axi.awvalid && axi.awready;
    wire              w_hs = axi.wvalid && axi.wready;

    wire              aw_present = aw_seen_q || aw_hs;
    wire              w_present = w_seen_q || w_hs;

    wire [       2:0] waddr_eff = aw_hs ? axi.awaddr[4:2] : awaddr_word_q;
    wire [DATA_W-1:0] wdata_eff = w_hs ? axi.wdata : wdata_q;

    assign axi.bvalid = bvalid_q;
    assign axi.bresp  = 2'b00;  // OKAY
    wire b_hs = axi.bvalid && axi.bready;

    // A TXDATA write with no room is held rather than dropped. AWREADY
    // above refuses the address phase, and this term covers the case where
    // the data phase arrived first: the write commits -- with B, and with
    // the push -- only once the engine has shipped a byte and freed a slot.
    // The wait is bounded by one frame time, since the TX engine drains the
    // FIFO on its own. Nothing else can be issued meanwhile: a single
    // outstanding transaction is the contract, and the FIFO only ever fills
    // from these writes, so once a slot is seen it stays.
    //
    // Dropping was the earlier contract, and it made a lost byte
    // indistinguishable from a byte that was never written: output simply
    // came out truncated, with the bus reporting OKAY for a write that had
    // no effect. Holding turns that silent data loss into backpressure the
    // master can see. Note it costs interrupt latency in the pathological
    // case: an interrupt is taken at a retire boundary, so a store parked
    // on a full FIFO delays entry until the write completes.
    wire tx_addr_sel = (waddr_eff == REG_TXDATA);
    wire tx_write_hold = tx_addr_sel && !tx_ready;

    wire do_write = aw_present && w_present && !bvalid_q && !tx_write_hold;

    wire tx_push = do_write && tx_addr_sel;

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
            REG_RXDATA:  rdata_mux = {24'b0, rx_fifo_head};
            REG_STATUS:  rdata_mux = {29'b0, rx_overrun_q, rx_ready, tx_ready};
            REG_CTRL:    rdata_mux = {30'b0, rx_ie_q, tx_ie_q};
            REG_BAUDDIV: rdata_mux = {16'b0, div_q};
            default:     rdata_mux = '0;
        endcase
    end

    // RXDATA read: consumed on the AR handshake that targets it (same
    // cycle the read is launched — matches the "accept = commit" timing the
    // rest of the bus layer uses). rdata_q latches rx_fifo_head in that
    // same cycle, so the popped byte is the one the master receives.
    // A read of an empty FIFO pops nothing (no pointer underflow) but
    // still acknowledges the overrun latch.
    wire rx_read = ar_hs && (axi.araddr[4:2] == REG_RXDATA);
    wire rx_fifo_pop = rx_read && rx_ready;

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
            tx_state_q    <= TX_IDLE;
            tx_shift_q    <= '0;
            tx_bit_cnt_q  <= '0;
            txd_q         <= 1'b1;  // idle line high
            tx_baud_cnt_q <= '0;
        end else begin
            unique case (tx_state_q)
                TX_IDLE: begin
                    tx_baud_cnt_q <= '0;
                    // Pull the next queued byte and start its frame. The
                    // FIFO head is combinational, so a byte pushed while
                    // the engine is idle starts one cycle later (the push
                    // is registered), same latency as before.
                    if (tx_fifo_pop) begin
                        tx_shift_q <= tx_fifo_head;
                        tx_state_q <= TX_START;
                        txd_q      <= 1'b0;  // start bit
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
    // FIFO storage and pointers.
    //
    // rx_frame_done is the end of a received frame (mid-stop-bit); it
    // pushes when there is room and latches RX_OVERRUN when there is not.
    // A pop that retires a byte in the same cycle frees the slot, so the
    // frame is still accepted -- no spurious overrun on a full FIFO that
    // software is draining at that exact moment.
    // =================================================================
    wire rx_frame_done = (rx_state_q == RX_STOP) && (rx_cnt_q == div_q);
    wire rx_fifo_push = rx_frame_done && (!rx_fifo_full || rx_fifo_pop);

    always_ff @(posedge clk_i) begin
        if (tx_push) tx_fifo_q[tx_wptr_q[TX_PTR_W-1:0]] <= wdata_eff[7:0];
        if (rx_fifo_push) rx_fifo_q[rx_wptr_q[RX_PTR_W-1:0]] <= rx_shift_q;
    end

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            tx_wptr_q <= '0;
            tx_rptr_q <= '0;
            rx_wptr_q <= '0;
            rx_rptr_q <= '0;
        end else begin
            if (tx_push) tx_wptr_q <= tx_wptr_q + 1'b1;
            if (tx_fifo_pop) tx_rptr_q <= tx_rptr_q + 1'b1;
            if (rx_fifo_push) rx_wptr_q <= rx_wptr_q + 1'b1;
            if (rx_fifo_pop) rx_rptr_q <= rx_rptr_q + 1'b1;
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
            rx_overrun_q <= 1'b0;
        end else begin
            // An RXDATA read acknowledges the overrun backlog. The byte
            // itself is popped by the FIFO pointer block below.
            if (rx_read) begin
                rx_overrun_q <= 1'b0;
            end

            // A completed frame that finds the FIFO full is dropped and
            // latches RX_OVERRUN (rx_fifo_push below is the accepted case).
            if (rx_frame_done && rx_fifo_full && !rx_fifo_pop) begin
                rx_overrun_q <= 1'b1;
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
                        // Stop bit not checked (no framing-error flag, see
                        // header comment) — commit the byte regardless.
                        // The push itself happens in the FIFO blocks below,
                        // keyed off rx_frame_done.
                        rx_cnt_q   <= '0;
                        rx_state_q <= RX_IDLE;
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
    assign uart_irq_o = (tx_ready & tx_ie_q) | (rx_ready & rx_ie_q);

endmodule

`resetall
