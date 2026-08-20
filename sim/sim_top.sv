`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
 * Simulation top (Verilator). Mirrors the board-top wiring of
 * `top_module` for the selected build:
 *
 * Harvard (default, VON_NEUMANN undefined):
 *   CPU.imem -> native_ram u_imem (read-only, preloaded via +IINIT)
 *   CPU.dmem -> native_ram u_dmem (byte-strobed RW, preloaded via +DINIT)
 *   CPU.axi_peri -> axi_bus_peri (tied off)
 * Fetch and the LSU no longer contend; each has a dedicated BSRAM.
 *
 * Von-Neumann legacy (VON_NEUMANN defined):
 *   CPU.bus_axi -> axi4_lite_xbar -> axi4_lite_ram u_ram (preloaded via
 *   +INIT). Fetch + LSU share one AXI master.
 *
 * No debug signals cross the CPU boundary (the CPU exports only its
 * functional ports). The C++ harness observes the per-stage taps
 * (fe_* / de_* / ex_* / writeback) by probing the Verilator hierarchy
 * directly — the sim is built with --public-flat, so the CPU-internal
 * nets (fe_pc_w, de_pc_w, ex_pc_w, wb_en, wb_addr, wb_data, ...) are
 * reachable as flat C++ members of the sim_top model. sim_top itself
 * therefore needs no debug output ports.
 *
 * The peripheral bus is tied off exactly like `top_module` (reserved
 * for future MMIO peripherals — UART, GPIO — not data RAM).
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
    // AXI4-Lite peripheral bus (trunk modport). Harvard keeps only this
    // (CPU peri master -> tied-off slave); von-Neumann also has the CPU
    // and mem trunks for the crossbar.
    // -----------------------------------------------------------------
`ifdef VON_NEUMANN
    axi4_lite_if axi_bus_cpu ();
    axi4_lite_if axi_bus_mem ();
`endif
    axi4_lite_if axi_bus_peri ();

`ifdef VON_NEUMANN
    assign axi_bus_cpu.aclk    = clk_i;
    assign axi_bus_cpu.aresetn = rstn_i;
    assign axi_bus_mem.aclk    = clk_i;
    assign axi_bus_mem.aresetn = rstn_i;
`endif
    assign axi_bus_peri.aclk    = clk_i;
    assign axi_bus_peri.aresetn = rstn_i;

    // -----------------------------------------------------------------
    // Native memory ports (Harvard). Fetch and the LSU each get a
    // dedicated native_ram.
    // -----------------------------------------------------------------
`ifndef VON_NEUMANN
    mem_req_t imem_req;
    mem_rsp_t imem_rsp;
    mem_req_t dmem_req;
    mem_rsp_t dmem_rsp;
`endif

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
        .dbg_stall_o(unused_dbg_stall),
`ifdef VON_NEUMANN
        .bus_axi    (axi_bus_cpu.master)
`else
        .axi_peri   (axi_bus_peri.master),
        .imem_req_o (imem_req),
        .imem_rsp_i (imem_rsp),
        .dmem_req_o (dmem_req),
        .dmem_rsp_i (dmem_rsp)
`endif
    );

`ifndef VON_NEUMANN
    // -----------------------------------------------------------------
    // Instruction memory (read-only). Fetch's dedicated port. Preloaded
    // via $readmemh with the +IINIT=<path> plusarg (default "imem.hex").
    // -----------------------------------------------------------------
    native_ram #(
        .ADDR_W    (16),  // 64 KiB
        .DATA_WIDTH(32),
        .READ_ONLY (1),
        .INIT_FILE ("")
    ) u_imem (
        .clk_i    (clk_i),
        .rstn_i   (rstn_i),
        .mem_req_i(imem_req),
        .mem_rsp_o(imem_rsp)
    );

    // -----------------------------------------------------------------
    // Data memory (byte-strobed read/write). Holds .rodata/.data/.bss
    // and the stack. Preloaded via $readmemh with the +DINIT=<path>
    // plusarg (default "dmem.hex").
    // -----------------------------------------------------------------
    native_ram #(
        .ADDR_W    (16),  // 64 KiB
        .DATA_WIDTH(32),
        .READ_ONLY (0),
        .INIT_FILE ("")
    ) u_dmem (
        .clk_i    (clk_i),
        .rstn_i   (rstn_i),
        .mem_req_i(dmem_req),
        .mem_rsp_o(dmem_rsp)
    );

    string iinit_file;
    string dinit_file;
    initial begin
        if (!$value$plusargs("IINIT=%s", iinit_file))
            iinit_file = "imem.hex";  // default: oracle code image
        if (!$value$plusargs("DINIT=%s", dinit_file))
            dinit_file = "dmem.hex";  // default: oracle data image
        $readmemh(iinit_file, u_imem.mem);
        $readmemh(dinit_file, u_dmem.mem);
    end
`else
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
    // preloaded via $readmemh with +INIT=<path> (default "program.hex").
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
`endif

    // -----------------------------------------------------------------
    // RAM probe: expose a window of the data RAM as scalar wires so they
    // land in the VCD and can be watched in GTKWave (Verilator does not
    // trace unpacked arrays past --trace-max-array, so the full mem[] is
    // not in the VCD). The window is pointed at the program's data array
    // so you can watch it change as the program runs — e.g. quicksort's
    // 16-int array before/after the sort.
    //
    // Harvard: data lives in u_dmem (D-mem, 0-based). Von-Neumann: data
    // shares u_ram. PROBE_BASE_WORD is the word index of the data array
    // in the data image — re-point it if the link layout changes.
    //   word index = byte_addr / 4.
    // Default points at the C quicksort .data array (link.ld places .data
    // at DMEM 0x2000 = word 0x800, N=32 ints). The hand-crafted oracle
    // writes its data at 0x100 (word 64) at runtime — re-point there
    // (PROBE_BASE_WORD=64) to watch the oracle.
    // In GTKWave the signals appear as:
    //   sim_top.g_mem_probe[<i>].mem_probe_w
    // -----------------------------------------------------------------
    localparam int unsigned PROBE_BASE_WORD = 64'h800;  // DMEM 0x2000 (quicksort .data)
    localparam int unsigned PROBE_LEN       = 64'd32;

    genvar gi;
    generate
        for (gi = 0; gi < PROBE_LEN; gi = gi + 1) begin : g_mem_probe
`ifdef VON_NEUMANN
            wire [31:0] mem_probe_w = u_ram.mem[PROBE_BASE_WORD+gi];
`else
            wire [31:0] mem_probe_w = u_dmem.mem[PROBE_BASE_WORD+gi];
`endif
        end
    endgenerate

    // -----------------------------------------------------------------
    // Peripheral bus: tie off the slave side (reserved for future MMIO
    // peripherals; data RAM is on the native dmem port / mem master, not
    // here).
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
