`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
 * Integer register file — 32 x 32-bit registers (x0 hardwired to 0).
 *
 * Two asynchronous (combinational) read ports so the decode stage gets
 * rs1/rs2 operands in the same cycle, and one synchronous write port
 * (posedge, whole-word write) driven by the execute writeback.
 *
 * Storage is the unpacked array `logic [XLEN-1:0] regs[31:0]` (sync-write
 * + 2 async-read), which matches GowinSynthesis's BSRAM (async-read
 * block-RAM) template once the writeback port is live -> it infers BSRAM,
 * not flops. BSRAM's async read is slower than a flop mux (it capped the
 * regfile path around ~54 MHz), but Fmax is not the current goal: the
 * fabric is targeted at 50 MHz (see top_module.sv / the SDC), where BSRAM
 * is comfortably fast enough. BSRAM contents cannot be runtime-reset by
 * `if (!rstn_i)`, but the reset loop is kept in the RTL: Verilator honors
 * it (sim determinism — all regs read 0 until written), and hardware
 * relies on BSRAM power-up INIT + write-before-read (standard for a
 * regfile; architectural state is not cleared on warm reset anyway).
 * reads of x0 return 0 via an explicit mux.
 *
 * Naming: ports *_i/_o; internal signals have no prefix. The storage
 * array is `regs`; there is no _q/_d because it is an array, not a
 * single flop.
 */

module reg_file (
    input wire clk_i,
    input wire rstn_i,

    // Two async read ports (decode drives the addresses).
    input  wire [     4:0] rs1_addr_i,
    input  wire [     4:0] rs2_addr_i,
    output wire [XLEN-1:0] rs1_data_o,
    output wire [XLEN-1:0] rs2_data_o,

    // One sync write port (future writeback; tied off in the CPU top
    // until the writeback stage exists).
    input wire [     4:0] wr_addr_i,
    input wire [XLEN-1:0] wr_data_i,
    input wire            wr_en_i
);

    logic [XLEN-1:0] regs[31:0];

    // -----------------------------------------------------------------
    // Write (sync, whole word, x0 ignored)
    // -----------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            for (integer i = 0; i < 32; i++) begin
                regs[i] <= '0;
            end
        end else if (wr_en_i && wr_addr_i != 5'd0) begin
            regs[wr_addr_i] <= wr_data_i;
        end
    end

    // -----------------------------------------------------------------
    // Read (async, x0 reads as 0)
    // -----------------------------------------------------------------
    assign rs1_data_o = (rs1_addr_i == 5'd0) ? '0 : regs[rs1_addr_i];
    assign rs2_data_o = (rs2_addr_i == 5'd0) ? '0 : regs[rs2_addr_i];

endmodule

`resetall
