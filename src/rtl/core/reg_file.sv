`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
 * Integer register file — 32 x 32-bit registers (x0 hardwired to 0).
 *
 * Two asynchronous (combinational) read ports so the decode stage gets
 * rs1/rs2 operands in the same cycle, and one synchronous write port
 * (posedge, byte-less whole-word write) for a future writeback stage.
 *
 * Storage is inferred as FLOPS (1024 FF + two 32:1 muxes), not BRAM
 * (block RAM has no async read) and not distributed RAM (dual-async-read
 * inference is finicky on Gowin). The whole file is reset to 0 so the
 * Verilator sim is deterministic before any writeback exists; reads of
 * x0 return 0 via an explicit mux (do not rely on the x0 flop staying 0
 * after a stray write).
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
