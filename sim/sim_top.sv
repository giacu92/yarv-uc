`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
 * Simulation top (Verilator). Replicates the board-top wiring of
 * `top_module` but:
 *   - instantiates the CPU and the AXI4-Lite RAM directly (so the RAM
 *     can be preloaded with a program hex via $readmemh), and
 *   - exposes the CPU's full F/D debug taps as output ports so the C++
 *     harness can log what the fetch stage actually delivers.
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

    // "LED" tap (low nibble of F/D PC), kept for parity with the board.
    output wire [3:0] led_o,

    // Full F/D debug taps (driven from the CPU).
    output wire [XLEN-1:0] fd_pc_full_dbg_o,
    output wire [XLEN-1:0] fd_instr_dbg_o,
    output wire            fd_valid_dbg_o,
    output wire            fd_is_compressed_dbg_o,
    output wire [XLEN-1:0] next_pc_dbg_o
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
    rv32imac_zicsr_zifencei u_cpu (
        .clk_i                 (clk_i),
        .rstn_i                (rstn_i),
        .boot_addr_i           (32'h0000_0000),
        .imem_axi              (axi_bus_imem.master),
        .peri_axi              (axi_bus_peri.master),
        .fd_pc_dbg_o           (led_o),
        .fd_pc_full_dbg_o      (fd_pc_full_dbg_o),
        .fd_instr_dbg_o        (fd_instr_dbg_o),
        .fd_valid_dbg_o        (fd_valid_dbg_o),
        .fd_is_compressed_dbg_o(fd_is_compressed_dbg_o),
        .next_pc_dbg_o         (next_pc_dbg_o)
    );

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
