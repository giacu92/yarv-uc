`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
 * Simulation top (Verilator). Replicates the board-top wiring of
 * `top_module`: instantiates the CPU and the AXI4-Lite RAM (so the RAM
 * can be preloaded with a program hex via $readmemh).
 *
 * No debug signals cross the CPU boundary (the CPU exports only its
 * functional ports). The C++ harness observes the per-stage taps
 * (fe_* / de_* / ex_* / writeback) by probing the Verilator hierarchy
 * directly — the sim is built with --public-flat, so the CPU-internal
 * nets (fe_pc_w, de_pc_w, ex_pc_w, wb_en, wb_addr, wb_data, ...) are
 * reachable as flat C++ members of the sim_top model. sim_top itself
 * therefore needs no debug output ports.
 *
 * The peripheral master port is tied off exactly like `top_module`
 * (reserved for future MMIO peripherals — UART, GPIO — not data RAM,
 * which shares the imem bus).
 *
 * This module is simulation-only; it is not part of the synthesis
 * file list.
 *
 * Naming follows the project convention: ports *_i/_o, internal
 * signals (incl. interface instances) have no prefix.
 */
module sim_top (
    input  wire       clk_i,
    input  wire       rstn_i,
    output wire [3:0] led_o
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
    // CPU. Functional ports only; debug is observed via the Verilator
    // hierarchy (--public-flat) from sim_main, not through ports here.
    // The aggregate stall tap (dbg_stall_o) is sunk to an unused wire —
    // it carries no per-stage debug, just a "pipe stalled" status bit.
    // -----------------------------------------------------------------
    wire unused_dbg_stall;
    rv32imac_zicsr_zifencei u_cpu (
        .clk_i      (clk_i),
        .rstn_i     (rstn_i),
        .boot_addr_i(32'h0000_0000),
        .imem_axi   (axi_bus_imem.master),
        .peri_axi   (axi_bus_peri.master),
        .dbg_stall_o(unused_dbg_stall)
    );

    // -----------------------------------------------------------------
    // Memory RAM on the imem bus (von Neumann: instructions + data),
    // preloaded via $readmemh.
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
    // Peripheral bus: tie off the slave side (reserved for future MMIO
    // peripherals; data RAM shares the imem bus, not this port).
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
    // LED: free-running counter, parity with the board top.
    // -----------------------------------------------------------------
    logic [27:0] led_cnt_q;

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            led_cnt_q <= '0;
        end else begin
            led_cnt_q <= led_cnt_q + 1'b1;
        end
    end

    assign led_o = led_cnt_q[27:24];

endmodule

`resetall
