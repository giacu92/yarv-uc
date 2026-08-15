`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
 * Simulation top (Verilator). Replicates the board-top wiring of
 * `top_module` but:
 *   - instantiates the CPU and the AXI4-Lite RAM directly (so the RAM
 *     can be preloaded with a program hex via $readmemh), and
 *   - exposes the CPU's full fe_* (fetch / F/D) AND de_* (decode / D/E)
 *     debug taps as output ports so the C++ harness can log what fetch
 *     delivers and what decode produces (control + operands + immediates).
 *
 * The peripheral master port is tied off exactly like `top_module`
 * (no slave yet) so a future peripheral drops in without rewiring.
 *
 * This module is simulation-only; it is not part of the synthesis
 * file list.
 *
 * Naming follows the project convention: ports *_i/_o, internal
 * signals (incl. interface instances) have no prefix.
 */
module sim_top (
    input wire clk_i,
    input wire rstn_i,

    // "LED" tap (low nibble of the fetch PC), kept for parity with the board.
    output wire [3:0] led_o,

    // fe_* debug taps (fetch stage / F/D register), driven from the CPU.
    output wire [XLEN-1:0] fe_pc_dbg_o,
    output wire [XLEN-1:0] fe_instr_dbg_o,
    output wire            fe_valid_dbg_o,
    output wire            fe_is_compressed_dbg_o,
    output wire [XLEN-1:0] fe_next_pc_dbg_o,

    // de_* debug taps (decode stage / D/E register). Flat scalars; see
    // the CPU top for the field encodings (alu_op / src selectors /
    // branch_type ...).
    output wire            de_valid_dbg_o,
    output wire [XLEN-1:0] de_pc_dbg_o,
    output wire [XLEN-1:0] de_instr_dbg_o,
    output wire            de_is_compressed_dbg_o,
    output wire [     4:0] de_rs1_addr_dbg_o,
    output wire [     4:0] de_rs2_addr_dbg_o,
    output wire [XLEN-1:0] de_rs1_data_dbg_o,
    output wire [XLEN-1:0] de_rs2_data_dbg_o,
    output wire [XLEN-1:0] de_imm_dbg_o,
    output wire [     4:0] de_rd_dbg_o,
    output wire            de_reg_write_dbg_o,
    output wire [     4:0] de_alu_op_dbg_o,
    output wire            de_alu_src_a_dbg_o,
    output wire [     1:0] de_alu_src_b_dbg_o,
    output wire            de_mem_read_dbg_o,
    output wire            de_mem_write_dbg_o,
    output wire [     1:0] de_mem_size_dbg_o,
    output wire            de_mem_unsigned_dbg_o,
    output wire [     1:0] de_wb_src_dbg_o,
    output wire [     3:0] de_branch_type_dbg_o,
    output wire            de_illegal_dbg_o
);

    // -----------------------------------------------------------------
    // AXI4-Lite buses (trunk modport) — one per CPU master port
    // -----------------------------------------------------------------
    axi4_lite_if axi_bus_imem ();
    axi4_lite_if axi_bus_peri ();

    assign axi_bus_imem.aclk    = clk_i;
    assign axi_bus_imem.aresetn = rstn_i;
    assign axi_bus_peri.aclk    = clk_i;
    assign axi_bus_peri.aresetn = rstn_i;

    // -----------------------------------------------------------------
    // CPU
    // -----------------------------------------------------------------
    // Full fetch PC; led_o is its low nibble, fe_pc_dbg_o is the full
    // width (exposed for the harness).
    wire [XLEN-1:0] cpu_pc_dbg;

    rv32imac_zicsr_zifencei u_cpu (
        .clk_i                 (clk_i),
        .rstn_i                (rstn_i),
        .boot_addr_i           (32'h0000_0000),
        .imem_axi              (axi_bus_imem.master),
        .peri_axi              (axi_bus_peri.master),
        .fe_pc_dbg_o           (cpu_pc_dbg),
        .fe_instr_dbg_o        (fe_instr_dbg_o),
        .fe_valid_dbg_o        (fe_valid_dbg_o),
        .fe_is_compressed_dbg_o(fe_is_compressed_dbg_o),
        .fe_next_pc_dbg_o      (fe_next_pc_dbg_o),
        .de_valid_dbg_o        (de_valid_dbg_o),
        .de_pc_dbg_o           (de_pc_dbg_o),
        .de_instr_dbg_o        (de_instr_dbg_o),
        .de_is_compressed_dbg_o(de_is_compressed_dbg_o),
        .de_rs1_addr_dbg_o     (de_rs1_addr_dbg_o),
        .de_rs2_addr_dbg_o     (de_rs2_addr_dbg_o),
        .de_rs1_data_dbg_o     (de_rs1_data_dbg_o),
        .de_rs2_data_dbg_o     (de_rs2_data_dbg_o),
        .de_imm_dbg_o          (de_imm_dbg_o),
        .de_rd_dbg_o           (de_rd_dbg_o),
        .de_reg_write_dbg_o    (de_reg_write_dbg_o),
        .de_alu_op_dbg_o       (de_alu_op_dbg_o),
        .de_alu_src_a_dbg_o    (de_alu_src_a_dbg_o),
        .de_alu_src_b_dbg_o    (de_alu_src_b_dbg_o),
        .de_mem_read_dbg_o     (de_mem_read_dbg_o),
        .de_mem_write_dbg_o    (de_mem_write_dbg_o),
        .de_mem_size_dbg_o     (de_mem_size_dbg_o),
        .de_mem_unsigned_dbg_o (de_mem_unsigned_dbg_o),
        .de_wb_src_dbg_o       (de_wb_src_dbg_o),
        .de_branch_type_dbg_o  (de_branch_type_dbg_o),
        .de_illegal_dbg_o      (de_illegal_dbg_o)
    );

    assign led_o       = cpu_pc_dbg[3:0];
    assign fe_pc_dbg_o = cpu_pc_dbg;

    // -----------------------------------------------------------------
    // Instruction RAM on the imem bus (preloaded with program.hex)
    // -----------------------------------------------------------------
    axi4_lite_ram #(
        .ADDR_W   (16),            // 64 KiB
        .INIT_FILE("program.hex")  // relative to the run cwd (sim/)
    ) u_ram (
        .clk_i (clk_i),
        .rstn_i(rstn_i),
        .axi   (axi_bus_imem.slave)
    );

    // -----------------------------------------------------------------
    // Peripheral bus: tie off the slave side (no peripheral yet).
    // -----------------------------------------------------------------
    assign axi_bus_peri.awready = 1'b0;
    assign axi_bus_peri.wready  = 1'b0;
    assign axi_bus_peri.bvalid  = 1'b0;
    assign axi_bus_peri.bresp   = 2'b00;
    assign axi_bus_peri.arready = 1'b0;
    assign axi_bus_peri.rvalid  = 1'b0;
    assign axi_bus_peri.rdata   = '0;
    assign axi_bus_peri.rresp   = 2'b00;

endmodule

`resetall
