`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
 * Simulation top (Verilator). Replicates the board-top wiring of
 * `top_module` but:
 *   - instantiates the CPU and the AXI4-Lite RAM directly (so the RAM
 *     can be preloaded with a program hex via $readmemh), and
 *   - exposes the CPU's fe_* (fetch / F/D) AND de_* (decode / D/E) debug
 *     taps — pc / instr / valid per stage — as output ports so the C++
 *     harness can log what fetch delivers and what decode produces.
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

    // fe_* debug taps (fetch / F/D register): pc / instr / valid.
    output wire [XLEN-1:0] fe_pc_dbg_o,
    output wire [XLEN-1:0] fe_instr_dbg_o,
    output wire            fe_valid_dbg_o,

    // de_* debug taps (decode / D/E register): pc / instr / valid.
    output wire [XLEN-1:0] de_pc_dbg_o,
    output wire [XLEN-1:0] de_instr_dbg_o,
    output wire            de_valid_dbg_o,

    // ex_* debug taps (execute / E/M register): pc / instr / valid.
    output wire [XLEN-1:0] ex_pc_dbg_o,
    output wire [XLEN-1:0] ex_instr_dbg_o,
    output wire            ex_valid_dbg_o
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
        .clk_i         (clk_i),
        .rstn_i        (rstn_i),
        .boot_addr_i   (32'h0000_0000),
        .imem_axi      (axi_bus_imem.master),
        .peri_axi      (axi_bus_peri.master),
        .fe_pc_dbg_o   (cpu_pc_dbg),
        .fe_instr_dbg_o(fe_instr_dbg_o),
        .fe_valid_dbg_o(fe_valid_dbg_o),
        .de_pc_dbg_o   (de_pc_dbg_o),
        .de_instr_dbg_o(de_instr_dbg_o),
        .de_valid_dbg_o(de_valid_dbg_o),
        .ex_pc_dbg_o   (ex_pc_dbg_o),
        .ex_instr_dbg_o(ex_instr_dbg_o),
        .ex_valid_dbg_o(ex_valid_dbg_o)
    );

    assign led_o       = cpu_pc_dbg[3:0];
    assign fe_pc_dbg_o = cpu_pc_dbg;

    // -----------------------------------------------------------------
    // Instruction RAM on the imem bus, preloaded via $readmemh.
    //
    // The load is done here (not via the RAM's INIT_FILE parameter) so the
    // image can be selected at run time with the +INIT=<path> Verilator
    // plusarg -- e.g. to run a C-compiled program (sim/sw/build/program.hex)
    // without clobbering the hand-crafted oracle (sim/program.hex). With no
    // +INIT, the default "program.hex" is loaded (same behavior as before).
    // Keeping this here (sim-only) leaves axi4_lite_ram synthesis-clean.
    // -----------------------------------------------------------------
    axi4_lite_ram #(
        .ADDR_W   (16),  // 64 KiB
        .INIT_FILE("")   // loaded from sim_top below (plusarg-selected)
    ) u_ram (
        .clk_i (clk_i),
        .rstn_i(rstn_i),
        .axi   (axi_bus_imem.slave)
    );

    string init_file;
    initial begin
        if (!$value$plusargs("INIT=%s", init_file))
            init_file = "program.hex";  // default: hand-crafted oracle
        $readmemh(init_file, u_ram.mem);
    end

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
