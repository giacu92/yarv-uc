`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
 * AXI4-Lite 1->2 crossbar: one slave port (from the CPU's single
 * master bridge) is routed to one of two master ports by address.
 *
 *   addr[SEL_BIT] = 0 -> m_mem_axi  (memory / RAM)
 *   addr[SEL_BIT] = 1 -> m_peri_axi (memory-mapped peripherals)
 *
 * SEL_BIT defaults to rv32_pkg::PERI_ADDR_BIT so the address map is
 * defined in the package, not hardcoded here. Override SEL_BIT at
 * instantiation to re-target the decode.
 *
 * The upstream bridge is single-outstanding overall (at most one read
 * OR one write in flight), so this xbar is a simple pass-through: no
 * buffering, no round-robin, no skid. It latches the selected target
 * per direction on the AW / AR handshake and routes the follow-on
 * W/B and R beats to that same target until the transaction retires.
 * A second transaction is not accepted while one is in flight in the
 * same direction (awready / arready are gated by the busy flag), which
 * mirrors the bridge's single-outstanding contract and keeps the
 * latched target stable.
 *
 * Write channel ordering: AXI4-Lite lets AW and W arrive in either
 * order. The bridge asserts AW and W together on a write launch, but
 * either may handshake first (AW-then-W or W-then-AW). Routing:
 *   - While a write is in flight (wr_busy_q), W and B follow the
 *     latched wr_sel_q.
 *   - On the launch cycle (AW valid, not yet busy) W is routed by the
 *     live awaddr decode, which matches the AW target the same cycle.
 *     W valid with AW not valid and not busy does not occur from this
 *     bridge (W only ever accompanies AW or follows an AW that already
 *     handshaked -> busy). So the live decode is only used when AW is
 *     also valid, i.e. the launch cycle.
 *
 * No combinational loop: the slave's ready outputs depend on the two
 * masters' ready outputs (which are register-based in the slaves
 * downstream) and on this xbar's registered busy flags, never on the
 * slave's own valid outputs.
 *
 * Naming: ports use *_i/_o; the AXI interface members follow the spec
 * (awvalid, arready, ...). Flops end _q, next-state _d. The two master
 * ports are named (not an interface array) to stay Gowin-synthesis-
 * friendly and match the rest of the bus layer.
 */
module axi4_lite_xbar #(
    parameter int unsigned SEL_BIT = PERI_ADDR_BIT  // addr[SEL_BIT]=1 -> peri
) (
    input wire clk_i,
    input wire rstn_i,

    // Slave side: the CPU's single AXI4-Lite master bridge.
    axi4_lite_if.slave s_axi,

    // Master side: two memory-mapped targets.
    axi4_lite_if.master m_mem_axi,  // addr[SEL_BIT] = 0
    axi4_lite_if.master m_peri_axi  // addr[SEL_BIT] = 1
);

    // -----------------------------------------------------------------
    // Per-direction in-flight target latch + busy flag.
    // Set on the AW / AR handshake; cleared on the B / R handshake.
    // -----------------------------------------------------------------
    logic wr_busy_q;  // a write is in flight (AW handshaked, B not yet)
    logic wr_sel_q;  // 1 = peri, 0 = mem (while wr_busy_q)
    logic rd_busy_q;  // a read is in flight (AR handshaked, R not yet)
    logic rd_sel_q;  // 1 = peri, 0 = mem (while rd_busy_q)

    // -----------------------------------------------------------------
    // Combinational target decode of the live address (used on the
    // launch cycle, before the latch is set).
    // -----------------------------------------------------------------
    wire  wr_sel_live = s_axi.awaddr[SEL_BIT];
    wire  rd_sel_live = s_axi.araddr[SEL_BIT];

    // Effective target for the in-flight W/B (latched) and R (latched).
    // AW and AR use the live decode (gated by !busy).
    wire  wr_sel_eff = wr_busy_q ? wr_sel_q : wr_sel_live;
    wire  rd_sel_eff = rd_busy_q ? rd_sel_q : rd_sel_live;

    // -----------------------------------------------------------------
    // Handshake predicates
    // -----------------------------------------------------------------
    wire  aw_hs = s_axi.awvalid && s_axi.awready;
    wire  b_hs = s_axi.bvalid && s_axi.bready;
    wire  ar_hs = s_axi.arvalid && s_axi.arready;
    wire  r_hs = s_axi.rvalid && s_axi.rready;

    // =================================================================
    // Slave -> master routing
    // =================================================================
    always_comb begin
        // ---- Defaults: drive nothing on either master ----
        // Address / data are passed through to both (only the selected
        // master sees its valid high, so the unselected master ignores
        // them). Ready outputs are computed per-channel below.
        m_mem_axi.awaddr   = s_axi.awaddr;
        m_mem_axi.awvalid  = 1'b0;
        m_mem_axi.wdata    = s_axi.wdata;
        m_mem_axi.wstrb    = s_axi.wstrb;
        m_mem_axi.wvalid   = 1'b0;
        m_mem_axi.bready   = 1'b0;
        m_mem_axi.araddr   = s_axi.araddr;
        m_mem_axi.arvalid  = 1'b0;
        m_mem_axi.rready   = 1'b0;

        m_peri_axi.awaddr  = s_axi.awaddr;
        m_peri_axi.awvalid = 1'b0;
        m_peri_axi.wdata   = s_axi.wdata;
        m_peri_axi.wstrb   = s_axi.wstrb;
        m_peri_axi.wvalid  = 1'b0;
        m_peri_axi.bready  = 1'b0;
        m_peri_axi.araddr  = s_axi.araddr;
        m_peri_axi.arvalid = 1'b0;
        m_peri_axi.rready  = 1'b0;

        // ---- Slave response defaults ----
        s_axi.awready      = 1'b0;
        s_axi.wready       = 1'b0;
        s_axi.bvalid       = 1'b0;
        s_axi.bresp        = 2'b00;
        s_axi.arready      = 1'b0;
        s_axi.rvalid       = 1'b0;
        s_axi.rdata        = '0;
        s_axi.rresp        = 2'b00;

        // =============================================================
        // Write path (AW / W / B)
        // =============================================================

        // AW: forward to the decoded target only when no write is in
        // flight (single outstanding). The selected master's awready
        // routes back to the slave.
        if (!wr_busy_q && s_axi.awvalid) begin
            if (wr_sel_live) begin
                m_peri_axi.awvalid = 1'b1;
                s_axi.awready      = m_peri_axi.awready;
            end else begin
                m_mem_axi.awvalid = 1'b1;
                s_axi.awready     = m_mem_axi.awready;
            end
        end

        // W: route to the in-flight write's target. On the launch cycle
        // (!wr_busy_q) W is valid only alongside AW, so wr_sel_eff uses
        // the live awaddr decode and matches the AW target. While busy,
        // the latched wr_sel_q routes W (and B below).
        if (s_axi.wvalid) begin
            if (wr_sel_eff) begin
                m_peri_axi.wvalid = 1'b1;
                s_axi.wready      = m_peri_axi.wready;
            end else begin
                m_mem_axi.wvalid = 1'b1;
                s_axi.wready     = m_mem_axi.wready;
            end
        end

        // B: route the in-flight write's B response back to the slave.
        // Only meaningful while a write is in flight.
        if (wr_busy_q) begin
            if (wr_sel_q) begin
                s_axi.bvalid      = m_peri_axi.bvalid;
                s_axi.bresp       = m_peri_axi.bresp;
                m_peri_axi.bready = s_axi.bready;
            end else begin
                s_axi.bvalid     = m_mem_axi.bvalid;
                s_axi.bresp      = m_mem_axi.bresp;
                m_mem_axi.bready = s_axi.bready;
            end
        end

        // =============================================================
        // Read path (AR / R)
        // =============================================================

        // AR: forward to the decoded target only when no read is in
        // flight.
        if (!rd_busy_q && s_axi.arvalid) begin
            if (rd_sel_live) begin
                m_peri_axi.arvalid = 1'b1;
                s_axi.arready      = m_peri_axi.arready;
            end else begin
                m_mem_axi.arvalid = 1'b1;
                s_axi.arready     = m_mem_axi.arready;
            end
        end

        // R: route the in-flight read's R response back to the slave.
        if (rd_busy_q) begin
            if (rd_sel_q) begin
                s_axi.rvalid      = m_peri_axi.rvalid;
                s_axi.rdata       = m_peri_axi.rdata;
                s_axi.rresp       = m_peri_axi.rresp;
                m_peri_axi.rready = s_axi.rready;
            end else begin
                s_axi.rvalid     = m_mem_axi.rvalid;
                s_axi.rdata      = m_mem_axi.rdata;
                s_axi.rresp      = m_mem_axi.rresp;
                m_mem_axi.rready = s_axi.rready;
            end
        end
    end

    // =================================================================
    // State: latch target on launch, clear on retire
    // =================================================================
    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            wr_busy_q <= 1'b0;
            wr_sel_q  <= 1'b0;
            rd_busy_q <= 1'b0;
            rd_sel_q  <= 1'b0;
        end else begin
            // Write target latched on AW handshake; cleared on B
            // handshake. (aw_hs and b_hs are mutually exclusive: b_hs
            // needs wr_busy_q, aw_hs needs !wr_busy_q.)
            if (aw_hs) begin
                wr_busy_q <= 1'b1;
                wr_sel_q  <= wr_sel_live;
            end else if (b_hs) begin
                wr_busy_q <= 1'b0;
            end

            // Read target latched on AR handshake; cleared on R
            // handshake.
            if (ar_hs) begin
                rd_busy_q <= 1'b1;
                rd_sel_q  <= rd_sel_live;
            end else if (r_hs) begin
                rd_busy_q <= 1'b0;
            end
        end
    end

endmodule

`resetall
