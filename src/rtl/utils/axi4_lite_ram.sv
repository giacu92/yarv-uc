`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * AXI4-Lite slave single-beat RAM (protocol-compliant).
 *
 * Byte-addressed, parameterised depth (2^ADDR_W bytes), data width fixed
 * by the interface DATA_WIDTH. No bursts: AXI4-Lite has no len/id signals,
 * so every transfer is a single beat.
 *
 * Write path:
 *   - AW and W are independent channels and may arrive in either order.
 *     Each is captured into its own holding register (aw_seen_q / w_seen_q);
 *     the transaction completes the cycle BOTH have been seen, the BRAM
 *     write fires, and BVALID is raised.
 *   - BVALID is REGISTERED and held high until the B channel handshakes
 *     (bvalid && bready). This is the AXI rule "VALID must remain asserted
 *     until the handshake" and is the key compliance point.
 *   - Single outstanding: while BVALID is pending (bvalid_q=1) both
 *     AWREADY and WREADY are low, so no second write is accepted until the
 *     current B response is consumed.
 *
 * Read path (1-cycle registered latency):
 *   - ARREADY is asserted when no unread response is being held (or the
 *     master is draining the current one). It depends only on registers
 *     and RREADY, never on ARVALID.
 *   - On the AR handshake the BRAM read is launched (registered), RVALID
 *     raised the next cycle, and held until RREADY.
 *
 * The storage array uses (* ram_style = "block" *) so the Gowin
 * synthesizer infers a simple dual-port BSRAM (one write port + one
 * read port, single clock). Byte-strobed writes use the BSRAM byte
 * enables.
 *
 * Reset is synchronous (matches the bus layer: axi4_lite_master_bridge),
 * active-low. The memory contents are NOT reset (BRAM has no reset); only
 * the control / response registers are.
 *
 * Naming: ports use *_i/_o; internal signals have no prefix. Flop
 * registers end in _q, their next-state counterparts in _d. Localparams
 * and AXI interface member names are unchanged.
 */

module axi4_lite_ram #(
    // Address width in bits (depth = 2^ADDR_W bytes)
    parameter int ADDR_W = 16,
    // Optional $readmemh init file (relative to simulation working dir)
    parameter string INIT_FILE = ""
) (
    input wire clk_i,
    input wire rstn_i,

    axi4_lite_if.slave axi
);

    // -----------------------------------------------------------------
    // Local params
    // -----------------------------------------------------------------
    localparam int DATA_W      = axi.DATA_WIDTH;
    localparam int STRB_W      = DATA_W / 8;
    localparam int BYTES_W     = $clog2(STRB_W);    // byte-select bits
    localparam int WORD_ADDR_W = ADDR_W - BYTES_W;
    localparam int DEPTH_WORDS = 1 << WORD_ADDR_W;  // addressable words

    // -----------------------------------------------------------------
    // Storage (BRAM)
    // -----------------------------------------------------------------
    (* ram_style = "block" *)
    logic [DATA_W-1:0] mem[DEPTH_WORDS];

    // Optional preload (simulation / bitstream init)
    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
        end
    end

    // -----------------------------------------------------------------
    // Address decoding (byte address -> word index)
    // -----------------------------------------------------------------
    wire  [WORD_ADDR_W-1:0] aw_word = axi.awaddr[ADDR_W-1:BYTES_W];
    wire  [WORD_ADDR_W-1:0] ar_word = axi.araddr[ADDR_W-1:BYTES_W];

    // =================================================================
    // Write path
    // =================================================================
    // Holding registers for the two independent write address / data
    // phases. Either may arrive first; the transaction completes once
    // both have been seen (and no B response is pending -> single
    // outstanding).
    logic                   aw_seen_q;
    logic                   w_seen_q;
    logic [WORD_ADDR_W-1:0] aw_word_q;
    logic [     STRB_W-1:0] wstrb_q;
    logic [     DATA_W-1:0] wdata_q;

    // Registered, held write-response valid.
    logic                   bvalid_q;

    // READY outputs: register-based, NEVER depend on the same-channel
    // VALID (AXI requirement). Held low while a B response is pending
    // (single outstanding).
    assign axi.awready = !aw_seen_q && !bvalid_q;
    assign axi.wready  = !w_seen_q && !bvalid_q;

    wire                   aw_hs = axi.awvalid && axi.awready;
    wire                   w_hs = axi.wvalid && axi.wready;

    // A phase "is present" this cycle if it was captured earlier OR it
    // handshakes right now (lets AW and W arriving the same cycle complete
    // in a single cycle).
    wire                   aw_present = aw_seen_q || aw_hs;
    wire                   w_present = w_seen_q || w_hs;
    wire                   do_write = aw_present && w_present && !bvalid_q;

    // Effective write operands: take the live channel value when it
    // handshakes this cycle, else the held value from the earlier phase.
    wire [WORD_ADDR_W-1:0] waddr_eff = aw_hs ? aw_word : aw_word_q;
    wire [     DATA_W-1:0] wdata_eff = w_hs ? axi.wdata : wdata_q;
    wire [     STRB_W-1:0] wstrb_eff = w_hs ? axi.wstrb : wstrb_q;

    // B response: registered, held until bready (compliant). bresp is
    // always OKAY (no decode errors on this RAM).
    assign axi.bvalid = bvalid_q;
    assign axi.bresp  = 2'b00;  // OKAY
    wire b_hs = axi.bvalid && axi.bready;

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            aw_seen_q <= 1'b0;
            w_seen_q  <= 1'b0;
            aw_word_q <= '0;
            wstrb_q   <= '0;
            wdata_q   <= '0;
            bvalid_q  <= 1'b0;
        end else begin
            // Capture each phase independently when it handshakes.
            if (aw_hs) begin
                aw_seen_q <= 1'b1;
                aw_word_q <= aw_word;
            end
            if (w_hs) begin
                w_seen_q <= 1'b1;
                wstrb_q  <= axi.wstrb;
                wdata_q  <= axi.wdata;
            end

            // Both phases present: complete the transaction. Clear the
            // holding flags (overrides any capture above when AW and W
            // land together) and raise BVALID. BVALID stays high until
            // the B handshake below clears it.
            if (do_write) begin
                aw_seen_q <= 1'b0;
                w_seen_q  <= 1'b0;
                bvalid_q  <= 1'b1;
            end

            // B channel handshake: drop BVALID. (If do_write and b_hs
            // were both possible the same cycle they are not: bvalid_q
            // must be 0 for do_write, and b_hs needs bvalid_q=1.)
            if (b_hs) begin
                bvalid_q <= 1'b0;
            end
        end
    end

    // Synchronous byte-strobed BRAM write (fires the cycle both phases
    // are present). Registered write port -> infers BSRAM.
    always_ff @(posedge clk_i) begin
        if (do_write) begin
            for (integer i = 0; i < STRB_W; i++) begin
                if (wstrb_eff[i]) begin
                    mem[waddr_eff][8*i+:8] <= wdata_eff[8*i+:8];
                end
            end
        end
    end

    // =================================================================
    // Read path (1-cycle registered latency)
    // =================================================================
    logic              rvalid_q;
    logic [DATA_W-1:0] rdata_q;

    // ARREADY: accept a new AR when no unread response is held, or while
    // the master is draining the current one (back-to-back reads).
    // Register + RREADY based only -> no ARVALID dependency, no comb loop.
    assign axi.arready = !rvalid_q || (rvalid_q && axi.rready);

    wire ar_hs = axi.arvalid && axi.arready;

    // R response: registered, held until RREADY. rresp is always OKAY.
    assign axi.rvalid = rvalid_q;
    assign axi.rdata  = rdata_q;
    assign axi.rresp  = 2'b00;  // OKAY

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            rvalid_q <= 1'b0;
            rdata_q  <= '0;
        end else begin
            if (ar_hs) begin
                // Launch the BRAM read; data is registered and RVALID
                // raised next cycle. If a response was still being held
                // it is consumed by rready this same cycle (arready was
                // high only because rready was), so overwriting is safe.
                rvalid_q <= 1'b1;
                rdata_q  <= mem[ar_word];
            end else if (rvalid_q && axi.rready) begin
                // Master consumed the response; drop RVALID.
                rvalid_q <= 1'b0;
            end
        end
    end

endmodule

`resetall
