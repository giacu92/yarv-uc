`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
 * Simulation top (Verilator). Replicates the board-top wiring of
 * `top_module`: instantiates the CPU, a 1->2 AXI4-Lite crossbar, and
 * the AXI4-Lite RAM on the mem master (so the RAM can be preloaded
 * with a program hex via $readmemh).
 *
 * No debug signals cross the CPU boundary (the CPU exports only its
 * functional ports). The C++ harness observes the per-stage taps
 * (fe_* / de_* / ex_* / writeback) by probing the Verilator hierarchy
 * directly — the sim is built with --public-flat, so the CPU-internal
 * nets (fe_pc_w, de_pc_w, ex_pc_w, wb_en, wb_addr, wb_data, ...) are
 * reachable as flat C++ members of the sim_top model. sim_top itself
 * therefore needs no debug output ports.
 *
 * The peripheral crossbar master is tied off exactly like `top_module`
 * (reserved for future MMIO peripherals — UART, GPIO — not data RAM,
 * which shares the mem master).
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
    // AXI4-Lite buses (trunk modport)
    //   axi_bus_cpu  : CPU master -> crossbar slave
    //   axi_bus_mem  : crossbar mem master -> RAM slave
    //   axi_bus_peri : crossbar peri master -> tied off (no slave yet)
    // -----------------------------------------------------------------
    axi4_lite_if axi_bus_cpu ();
    axi4_lite_if axi_bus_mem ();
    axi4_lite_if axi_bus_peri ();

    assign axi_bus_cpu.aclk     = clk_i;
    assign axi_bus_cpu.aresetn  = rstn_i;
    assign axi_bus_mem.aclk     = clk_i;
    assign axi_bus_mem.aresetn  = rstn_i;
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
        .bus_axi    (axi_bus_cpu.master),
        .dbg_stall_o(unused_dbg_stall)
    );

    // -----------------------------------------------------------------
    // 1->2 AXI4-Lite crossbar: mem vs peri by addr[PERI_ADDR_BIT].
    // -----------------------------------------------------------------
    axi4_lite_xbar #(
        .SEL_BIT(PERI_ADDR_BIT)
    ) u_xbar (
        .clk_i     (clk_i),
        .rstn_i    (rstn_i),
        .s_axi     (axi_bus_cpu.slave),
        .m_mem_axi (axi_bus_mem.master),
        .m_peri_axi(axi_bus_peri.master)
    );

    // -----------------------------------------------------------------
    // Memory RAM on the mem master (von Neumann: instructions + data),
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
        .INIT_FILE("")
    ) u_ram (
        .clk_i (clk_i),
        .rstn_i(rstn_i),
        .axi   (axi_bus_mem.slave)
    );

    string init_file;
    initial begin
        if (!$value$plusargs("INIT=%s", init_file))
            init_file = "program.hex";  // default: hand-crafted oracle
        $readmemh(init_file, u_ram.mem);
    end

    // -----------------------------------------------------------------
    // RAM probe: expose a window of u_ram.mem as scalar wires so they
    // land in the VCD and can be watched in GTKWave (Verilator does not
    // trace unpacked arrays past --trace-max-array, so the full mem[] is
    // not in the VCD). The window is pointed at the program's data array
    // so you can watch it change as the program runs — e.g. quicksort's
    // 16-int .data array at 0xfc (word index 63) before/after the sort.
    //
    // Edit PROBE_BASE_WORD / PROBE_LEN to point at the data of interest:
    //   word index = byte_addr / 4. (0xfc / 4 = 63.)
    // In GTKWave the signals appear as:
    //   sim_top.g_mem_probe[<i>].mem_probe_w
    // -----------------------------------------------------------------
    localparam int unsigned PROBE_BASE_WORD = 64'd63;  // 0xfc >> 2
    localparam int unsigned PROBE_LEN       = 64'd16;

    genvar gi;
    generate
        for (gi = 0; gi < PROBE_LEN; gi = gi + 1) begin : g_mem_probe
            wire [31:0] mem_probe_w = u_ram.mem[PROBE_BASE_WORD+gi];
        end
    endgenerate

    // -----------------------------------------------------------------
    // Peripheral bus: tie off the slave side (reserved for future MMIO
    // peripherals; data RAM shares the mem master, not this port).
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
