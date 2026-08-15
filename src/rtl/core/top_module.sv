`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
 * Board-level top for the Tang Nano 20k (Gowin GW2AR-18C).
 *
 * Instantiates the RV32IMAC + Zicsr + Zifencei CPU (which already
 * exposes two AXI4-Lite masters on its boundary) and routes them to
 * one AXI4-Lite slave BRAM (imem) plus an open peripheral bus.
 *
 * Topology:
 *
 *   rv32imac_zicsr_zifencei
 *      |  imem_axi (master)            peri_axi (master, unused)
 *      v                               v
 *   axi_bus_imem (trunk)              axi_bus_peri (trunk, no slave yet)
 *      |
 *      v
 *   axi4_lite_ram
 *
 * The native->AXI conversion is owned by the CPU itself (per-port
 * axi4_lite_master_bridge instances inside rv32imac_zicsr_zifencei),
 * so the board top stays free of glue.
 *
 * Pin assignments are in impl/pnr/rv32imac_Zicsr_Zifencei.cst.
 *
 * Naming: ports use *_i/_o; internal signals (including interface
 * instances) have no prefix. Module instance names keep u_*.
 */

module top_module (
    input wire clk_i,
    input wire rstn_i,

    // Debug LEDs: low 4 bits of the F/D PC.
    output wire [3:0] led_o
);

    // -----------------------------------------------------------------
    // AXI4-Lite buses (trunk modport) — one per CPU master port
    // -----------------------------------------------------------------
    axi4_lite_if axi_bus_imem ();
    axi4_lite_if axi_bus_peri ();

    // Drive the bus clock/reset from the top-level ports so every
    // master/slave on a given bus sees the same edges.
    assign axi_bus_imem.aclk    = clk_i;
    assign axi_bus_imem.aresetn = rstn_i;
    assign axi_bus_peri.aclk    = clk_i;
    assign axi_bus_peri.aresetn = rstn_i;

    // -----------------------------------------------------------------
    // CPU
    // -----------------------------------------------------------------
    wire [3:0] cpu_pc_dbg;

    rv32imac_zicsr_zifencei u_cpu (
        .clk_i                 (clk_i),
        .rstn_i                (rstn_i),
        .boot_addr_i           (32'h0000_0000),
        .imem_axi              (axi_bus_imem.master),
        .peri_axi              (axi_bus_peri.master),
        .fd_pc_dbg_o           (cpu_pc_dbg),
        // Full F/D debug taps: unused on the board (swept by synthesis),
        // consumed by the simulation wrapper.
        .fd_pc_full_dbg_o      (),
        .fd_instr_dbg_o        (),
        .fd_valid_dbg_o        (),
        .fd_is_compressed_dbg_o(),
        .next_pc_dbg_o         ()
    );

    // -----------------------------------------------------------------
    // Instruction / data RAM on the imem bus
    // -----------------------------------------------------------------
    axi4_lite_ram #(
        .ADDR_W   (16),  // 64 KiB
        .INIT_FILE("")
    ) u_ram (
        .clk_i (clk_i),
        .rstn_i(rstn_i),
        .axi   (axi_bus_imem.slave)
    );

    // -----------------------------------------------------------------
    // Peripheral bus: no slave instantiated yet. The trunk is left
    // open on the slave side; the master side is the CPU's peri_axi.
    // We must tie off the slave outputs so the interface is well-formed
    // and a future slave can be dropped in without rewiring the top.
    // -----------------------------------------------------------------
    assign axi_bus_peri.awready = 1'b0;
    assign axi_bus_peri.wready  = 1'b0;
    assign axi_bus_peri.bvalid  = 1'b0;
    assign axi_bus_peri.bresp   = 2'b00;
    assign axi_bus_peri.arready = 1'b0;
    assign axi_bus_peri.rvalid  = 1'b0;
    assign axi_bus_peri.rdata   = '0;
    assign axi_bus_peri.rresp   = 2'b00;

    // -----------------------------------------------------------------
    // Debug LEDs: F/D PC low nibble. Keeps the design observable so
    // the synthesizer doesn't sweep the fetch stage away.
    // -----------------------------------------------------------------
    assign led_o                = cpu_pc_dbg;

endmodule
