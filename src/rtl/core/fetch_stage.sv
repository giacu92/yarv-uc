`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
 * Fetch stage of the pipeline.
 *
 * Owns the PC and exposes a small native interface for instruction
 * memory access. The stage does NOT drive any bus protocol — it just
 * publishes a request every cycle (the external bridge turns it into
 * AXI4-Lite or whatever the system bus is).
 *
 * Behaviour:
 *   - pc_q: the address of the current fetch (registered).
 *   - pc_d = pc_q + 4 by default; can be replaced by `next_pc_d` when
 *     a redirect is in flight (see stall_i / branch_valid_i below).
 *   - imem_req_o.valid = 1 every cycle (continuous fetching). The
 *     external bridge is responsible for back-pressure: if it cannot
 *     accept a request this cycle, it must hold ready low AND stall
 *     the fetch stage via `stall_i` so the request stays pending.
 *   - imem_rsp_i.valid is high for exactly one cycle when the
 *     instruction arrives; that cycle's rdata is captured into the
 *     F/D pipeline register as fd_instr_o.
 *
 * Forward-compat inputs (currently tied off in the CPU top):
 *   - stall_i: hold the PC and request; useful for hazard / multi-cycle.
 *   - branch_valid_i + branch_addr_i: on the next cycle, use
 *     branch_addr_i as the new PC (flushes the in-flight fetch).
 *
 * next_pc_o: the PC value that the fetch stage WANTS to use next cycle
 * (i.e. pc_d, the result of `pc_q + 4` or the redirect target). The
 * external bridge can compare this against the response address to
 * detect pipeline flushes if it wants.
 */

module fetch_stage (
    input  wire clk_i,
    input  wire rstn_i,

    // Reset vector boot address
    input  wire [XLEN-1:0] boot_addr_i,

    // Forward-compat (currently tied off in CPU top)
    input  wire            stall_i,
    input  wire            branch_valid_i,
    input  wire [XLEN-1:0] branch_addr_i,

    // Native instruction-memory interface (consumed by the external bridge)
    output mem_req_t       imem_req_o,
    input  mem_rsp_t       imem_rsp_i,

    // The "next PC" this stage intends to use next cycle. Useful for
    // debug and for the bridge to detect in-flight flushes.
    output wire [XLEN-1:0] next_pc_o,

    // F/D pipeline register outputs (consumed by decode)
    output wire [XLEN-1:0] fd_instr_o,
    output wire [XLEN-1:0] fd_pc_o,
    output wire            fd_valid_o,
    output wire            fd_is_compressed_o
);

    // -----------------------------------------------------------------
    // PC register
    // -----------------------------------------------------------------
    logic [XLEN-1:0] pc_q, pc_d;
    logic [XLEN-1:0] next_pc_d;

    // next_pc_d is the PC we want to move to next cycle. Defaults to
    // pc_q + 4 (sequential). A redirect overrides it.
    always_comb begin
        next_pc_d = pc_q + 4;
        if (branch_valid_i) begin
            next_pc_d = branch_addr_i;
        end
    end

    assign pc_d = next_pc_d;

    always_ff @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i) begin
            pc_q <= boot_addr_i;
        end else if (!stall_i) begin
            pc_q <= pc_d;
        end
        // else: hold pc_q (stall)
		else begin
			pc_q <= pc_q;
		end
    end

    // -----------------------------------------------------------------
    // Instruction-memory request
    //
    // Continuous fetch: every non-stalled cycle we publish a read
    // request for pc_q. The external bridge accepts (ready=1) when
    // it can launch the transaction. On a stall we keep the request
    // asserted so the bridge can still latch the address when it
    // becomes ready (the address is stable because pc_q is held).
    // -----------------------------------------------------------------
    assign imem_req_o.valid = 1'b1;
    assign imem_req_o.we    = 1'b0;
    assign imem_req_o.addr  = pc_q;
    assign imem_req_o.wdata = '0;
    assign imem_req_o.wstrb = '0;

    assign next_pc_o = pc_d;

    // -----------------------------------------------------------------
    // F/D pipeline register
    //
    // When the response arrives (imem_rsp_i.valid=1), we latch it.
    // We also stamp it with fd_valid_o=1 for that cycle and the PC
    // that was being read (pc_q at the time of the request). Note:
    // pc_q may have advanced already by the time rvalid arrives, so
    // we use `pc_q - 4` to recover the request address... but since
    // the fetch is sequential and we always request pc_q exactly one
    // cycle after the previous pc_q+4, the address of the *current*
    // response is the pc_q that was sampled when this rvalid was
    // generated upstream. For now we expose the latched pc_q.
    // -----------------------------------------------------------------
    logic            fd_valid_q;
    logic [XLEN-1:0] fd_pc_q;
    logic [XLEN-1:0] fd_instr_q;
    logic            fd_is_compressed_q;

    always_ff @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i) begin
            fd_valid_q        <= 1'b0;
            fd_pc_q           <= '0;
            fd_instr_q        <= '0;
            fd_is_compressed_q <= 1'b0;
        end else begin
            fd_valid_q        <= imem_rsp_i.valid;
            fd_pc_q           <= imem_rsp_i.valid ? pc_q : fd_pc_q;
            fd_instr_q        <= imem_rsp_i.valid ? imem_rsp_i.rdata : fd_instr_q;
            fd_is_compressed_q <= imem_rsp_i.valid
                                  ? (imem_rsp_i.rdata[1:0] != 2'b11)
                                  : fd_is_compressed_q;
        end
    end

    assign fd_pc_o            = fd_pc_q;
    assign fd_instr_o         = fd_instr_q;
    assign fd_valid_o         = fd_valid_q;
    assign fd_is_compressed_o = fd_is_compressed_q;

endmodule
