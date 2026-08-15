`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * AXI4-Lite slave single-beat RAM.
 *
 * Byte-addressed, parameterised depth (2^ADDR_W bytes), data width fixed
 * by the interface DATA_WIDTH. No bursts: awlen/arlen ignored (slave
 * always treats each transfer as a single beat).
 *
 * Read latency: 1 cycle (registered).
 * Write response: combinational bvalid asserted the same cycle AW and W
 * both hand-shake.
 *
 * The storage array uses (* ram_style = "block" *) so the Gowin
 * synthesizer infers BSRAM.
 *
 * Naming: ports use *_i/_o; internal signals have no prefix. Flop
 * registers end in _q, their next-state counterparts in _d. Localparams
 * and AXI interface member names are unchanged.
 */

module axi4_lite_ram #(
    // Address width in bits (depth = 2^ADDR_W bytes)
    parameter int ADDR_W   = 16,
    // Optional $readmemh init file (relative to simulation working dir)
    parameter string INIT_FILE = ""
) (
    input  wire clk_i,
    input  wire rstn_i,

    axi4_lite_if.slave axi
);

    // -----------------------------------------------------------------
    // Local params
    // -----------------------------------------------------------------
    localparam int DATA_W    = axi.DATA_WIDTH;
    localparam int STRB_W    = DATA_W / 8;
    localparam int DEPTH     = 1 << ADDR_W;
    localparam int WORD_ADDR_W = ADDR_W - $clog2(STRB_W);

    // -----------------------------------------------------------------
    // Storage
    // -----------------------------------------------------------------
    (* ram_style = "block" *)
    logic [DATA_W-1:0] mem [DEPTH];

    // Optional preload (simulation / bitstream init)
    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
        end
    end

    // -----------------------------------------------------------------
    // Address decoding
    // -----------------------------------------------------------------
    // AXI addresses are byte addresses; we index the word-addressed array.
    wire [WORD_ADDR_W-1:0] waddr_word = axi.awaddr[ADDR_W-1:$clog2(STRB_W)];
    wire [WORD_ADDR_W-1:0] raddr_word = axi.araddr[ADDR_W-1:$clog2(STRB_W)];

    // -----------------------------------------------------------------
    // Write path
    // -----------------------------------------------------------------
    // AW and W can handshake independently; we capture both and assert
    // bvalid the cycle the second one arrives.
    logic aw_seen_q, aw_seen_d;
    logic [WORD_ADDR_W-1:0] aw_word_q, aw_word_d;
    logic [STRB_W-1:0]      wstrb_q,  wstrb_d;
    logic [DATA_W-1:0]      wdata_q,  wdata_d;

    wire aw_hs = axi.awvalid && axi.awready;
    wire w_hs  = axi.wvalid  && axi.wready;

    always_comb begin
        // Defaults
        axi.awready = 1'b0;
        axi.wready  = 1'b0;
        axi.bvalid  = 1'b0;
        axi.bresp   = 2'b00;

        aw_seen_d = aw_seen_q;
        aw_word_d = aw_word_q;
        wstrb_d   = wstrb_q;
        wdata_d   = wdata_q;

        // Address phase
        if (!aw_seen_q) begin
            axi.awready = 1'b1;
            if (aw_hs) begin
                aw_seen_d = 1'b1;
                aw_word_d = waddr_word;
            end
        end

        // Data phase: only accept W once AW has been captured.
        if (aw_seen_q) begin
            axi.wready = 1'b1;
            if (w_hs) begin
                wstrb_d = axi.wstrb;
                wdata_d = axi.wdata;
                // B valid as soon as both AW and W have been seen in the
                // same transaction (the W handshake is the second event).
                axi.bvalid = 1'b1;
                axi.awready = 1'b1; // accept next AW immediately
                aw_seen_d  = 1'b0; // transaction complete
            end
        end
    end

    // BREADY just gates the bvalid hold (no skid).
    wire b_fire = axi.bvalid && axi.bready;

    always_ff @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i) begin
            aw_seen_q <= 1'b0;
            aw_word_q <= '0;
            wstrb_q   <= 1'b0;
            wdata_q   <= 1'b0;
        end else begin
            aw_seen_q <= aw_seen_d;
            aw_word_q <= aw_word_d;
            wstrb_q   <= wstrb_d;
            wdata_q   <= wdata_d;
        end
    end

    // Write enable to the BRAM, registered, byte-strobed.
    logic mem_we_q;
    logic [WORD_ADDR_W-1:0] mem_waddr_q;
    logic [DATA_W-1:0]      mem_wdata_q;
    logic [STRB_W-1:0]      mem_wstrb_q;

    always_ff @(posedge clk_i) begin
        mem_we_q    <= w_hs && aw_seen_q;
        mem_waddr_q <= aw_word_q;
        mem_wdata_q <= wdata_d;
        mem_wstrb_q <= wstrb_d;
    end

    always_ff @(posedge clk_i) begin
        if (mem_we_q) begin
            for (integer i = 0; i < STRB_W; i++) begin
                if (mem_wstrb_q[i]) begin
                    mem[mem_waddr_q][8*i +: 8] <= mem_wdata_q[8*i +: 8];
                end
            end
        end
    end

    // -----------------------------------------------------------------
    // Read path (1-cycle registered latency)
    // -----------------------------------------------------------------
    logic                    rvalid_q;
    logic [DATA_W-1:0]       rdata_q;

    wire ar_hs = axi.arvalid && axi.arready;

    always_comb begin
        // Default: not ready to accept a new AR.
        axi.arready = 1'b0;
        // Accept AR whenever the read data register is free (not holding
        // an unread response, or the master is draining the current one).
        if (!rvalid_q || (rvalid_q && axi.rready)) begin
            axi.arready = 1'b1;
        end

        axi.rvalid = rvalid_q;
        axi.rdata  = rdata_q;
        axi.rresp  = 2'b00;
    end

    always_ff @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i) begin
            rvalid_q <= 1'b0;
            rdata_q  <= '0;
        end else begin
            if (ar_hs) begin
                // Latch new read data; rvalid stays high until master rready.
                rvalid_q <= 1'b1;
                rdata_q  <= mem[raddr_word];
            end else if (axi.rready) begin
                // Master consumed the response; clear rvalid.
                rvalid_q <= 1'b0;
            end
        end
    end

endmodule

`resetall