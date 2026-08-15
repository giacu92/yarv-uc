`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
 * Generic AXI4-Lite master bridge.
 *
 * Sits between the CPU's native mem_req_t / mem_rsp_t interface and a
 * master AXI4-Lite port. Translates one-cycle request/response
 * semantics into AR/AW/W + R/B transactions.
 *
 * Behaviour:
 *   - The master side accepts a request on `req_valid && req_ready`
 *     (a small per-channel FSM tracks pending read / write beats).
 *   - For reads: on handshake, AR is launched. When R arrives, rdata
 *     is presented on rsp_o.valid for one cycle.
 *   - For writes: on handshake, AW + W are launched in lock-step.
 *     When B arrives, rsp_o.valid pulses high so the producer knows
 *     the write retired.
 *   - The two channels are independent; the bridge can have one
 *     outstanding read and one outstanding write at the same time.
 *
 * This replaces the old fetch-only bridge. The CPU does not need to
 * know whether it is talking to memory or peripherals — the board
 * top picks the topology and instantiates one of these per master
 * port.
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
        axi.rready  = 1'b1;

        rsp_o.valid = 1'b0;
        rsp_o.rdata = '0;

        state_d = state_q;

        unique case (state_q)
            S_IDLE: begin
                if (req_i.valid) begin
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
                if (r_hs) begin
                    rsp_o.valid = 1'b1;
                    rsp_o.rdata = axi.rdata;
                    state_d     = S_IDLE;
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
                // W hand-shaken, AW still outstanding
                axi.awaddr  = req_i.addr;
                axi.awvalid = 1'b1;
                if (aw_hs) begin
                    state_d = S_WR_WAIT;
                end
            end

            S_WR_WAIT: begin
                if (b_hs) begin
                    rsp_o.valid = 1'b1;
                    rsp_o.rdata = '0;
                    state_d     = S_IDLE;
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
