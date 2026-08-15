`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
 * Generic AXI4-Lite master bridge.
 *
 * Sits between the CPU's native mem_req_t / mem_rsp_t interface and a
 * master AXI4-Lite port. The native interface is split per direction
 * (stile AXI): req_i carries all master->bridge signals (wvalid/we/
 * addr/wdata/wstrb/rready), rsp_o carries all bridge->master signals
 * (wready/rvalid/rdata).
 *
 * Behaviour:
 *   - Request launch handshake: req_i.wvalid && rsp_o.wready, where
 *     rsp_o.wready is high only in S_IDLE. A single shared FSM tracks
 *     the pending read or write beat.
 *   - For reads: on launch, AR is asserted. In S_RD_WAIT the master's
 *     rready is forwarded to axi.rready, so the AXI slave holds rvalid/
 *     rdata until the master is ready. rsp_o.rvalid is high the cycle
 *     the read data is consumed (rvalid && rready); rsp_o.rdata carries
 *     it. The bridge then returns to S_IDLE.
 *   - For writes: on launch, AW + W are launched in lock-step; on B
 *     the bridge returns to S_IDLE. The write-retirement is NOT
 *     signalled back (no bvalid in mem_rsp_t yet) — TODO for the LSU.
 *   - Read and write share one FSM, so the bridge is single-outstanding
 *     overall: at most one transaction (read OR write) in flight at a
 *     time.
 *
 * The CPU does not need to know whether it is talking to memory or
 * peripherals — the board top picks the topology and instantiates one
 * of these per master port.
 */

module axi4_lite_master_bridge (
    input  wire clk_i,
    input  wire rstn_i,

    // Native CPU interface
    input  mem_req_t req_i,
    output mem_rsp_t rsp_o,

    // Master AXI4-Lite port
    axi4_lite_if.master axi
);

    // -----------------------------------------------------------------
    // Per-channel state
    // -----------------------------------------------------------------
    typedef enum logic [1:0] {
        S_IDLE,
        S_RD_WAIT,
        S_WR_ADDR,
        S_WR_DATA,
        S_WR_WAIT
    } state_t;

    state_t state_q, state_d;

    // The bridge can accept a new request only when idle. Read and
    // write share the single FSM, so wready is low while *either* is
    // in flight (single outstanding overall).
    wire ar_hs = axi.arvalid && axi.arready;
    wire aw_hs = axi.awvalid && axi.awready;
    wire w_hs  = axi.wvalid  && axi.wready;
    wire r_hs  = axi.rvalid  && axi.rready;
    wire b_hs  = axi.bvalid  && axi.bready;

    always_comb begin
        // Defaults
        axi.awaddr  = '0;
        axi.awvalid = 1'b0;
        axi.wdata   = '0;
        axi.wstrb   = '0;
        axi.wvalid  = 1'b0;
        axi.bready  = 1'b1;

        axi.araddr  = req_i.addr;
        axi.arvalid = 1'b0;
        axi.rready  = 1'b0;

        rsp_o.wready = (state_q == S_IDLE);
        rsp_o.rvalid = 1'b0;
        rsp_o.rdata  = '0;

        state_d = state_q;

        unique case (state_q)
            S_IDLE: begin
                if (req_i.wvalid) begin
                    if (req_i.we) begin
                        // Write: launch AW + W in lock-step.
                        axi.awaddr  = req_i.addr;
                        axi.awvalid = 1'b1;
                        axi.wdata   = req_i.wdata;
                        axi.wstrb   = req_i.wstrb;
                        axi.wvalid  = 1'b1;
                        if (aw_hs && w_hs) begin
                            state_d = S_WR_WAIT;
                        end else if (aw_hs) begin
                            state_d = S_WR_DATA;
                        end else if (w_hs) begin
                            state_d = S_WR_ADDR;
                        end
                    end else begin
                        // Read: launch AR.
                        axi.arvalid = 1'b1;
                        if (ar_hs) begin
                            state_d = S_RD_WAIT;
                        end
                    end
                end
            end

            S_RD_WAIT: begin
                // Forward the master's rready to the AXI R channel so the
                // slave holds rvalid/rdata until the master can accept.
                axi.rready   = req_i.rready;
                rsp_o.rvalid = r_hs;
                rsp_o.rdata  = axi.rdata;
                if (r_hs) begin
                    state_d = S_IDLE;
                end
            end

            S_WR_ADDR: begin
                // AW hand-shaken, W still outstanding
                axi.wdata  = req_i.wdata;
                axi.wstrb  = req_i.wstrb;
                axi.wvalid = 1'b1;
                if (w_hs) begin
                    state_d = S_WR_WAIT;
                end
            end

            S_WR_DATA: begin
                // W hand-shoken, AW still outstanding
                axi.awaddr  = req_i.addr;
                axi.awvalid = 1'b1;
                if (aw_hs) begin
                    state_d = S_WR_WAIT;
                end
            end

            S_WR_WAIT: begin
                // Write retired. No bvalid exposed to the native side
                // (TODO LSU); just return to idle.
                if (b_hs) begin
                    state_d = S_IDLE;
                end
            end
        endcase
    end

    always_ff @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i) begin
            state_q <= S_IDLE;
        end else begin
            state_q <= state_d;
        end
    end

endmodule