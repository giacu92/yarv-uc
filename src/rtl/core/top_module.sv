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

    // Debug LEDs: low 4 bits of the fetch PC.
    output wire [3:0] led_o
);

    // -----------------------------------------------------------------
    // Clock generation
    //
    // Board oscillator:
    //   clk_i = 27 MHz
    //
    // Internal CPU clock:
    //   clk_core = 50 MHz
    // -----------------------------------------------------------------

    wire clk_core;
    wire pll_lock;

    rPLL #(  // For GW1NR-9C C6/I5 (Tang Nano 9K proto dev board)
        .FCLKIN   ("27"),
        .IDIV_SEL (5),     // -> PFD = 4.5 MHz (range: 3-400 MHz)
        .FBDIV_SEL(21),    // -> CLKOUT = 99 MHz (range: 3.125-600 MHz)
        .ODIV_SEL (8)      // -> VCO = 792 MHz (range: 400-1200 MHz)
    ) pll (
        .CLKOUTP (),
        .CLKOUTD (),
        .CLKOUTD3(),
        .RESET   (1'b0),
        .RESET_P (1'b0),
        .CLKFB   (1'b0),
        .FBDSEL  (6'b0),
        .IDSEL   (6'b0),
        .ODSEL   (6'b0),
        .PSDA    (4'b0),
        .DUTYDA  (4'b0),
        .FDLY    (4'b0),
        .CLKIN   (clk_i),     // 27 MHz
        .CLKOUT  (clk_core),  // 99 MHz
        .LOCK    (pll_lock)
    );

    // -----------------------------------------------------------------
    // Reset synchronization
    //
    // Reset is asserted while:
    //   - external reset is asserted, OR
    //   - PLL has not locked yet.
    //
    // Deassertion is synchronized to clk_core.
    // -----------------------------------------------------------------

    logic [1:0] rst_sync;

    always_ff @(posedge clk_core or negedge rstn_i) begin
        if (!rstn_i) begin
            rst_sync <= 2'b00;
        end else if (!pll_lock) begin
            rst_sync <= 2'b00;
        end else begin
            rst_sync <= {rst_sync[0], 1'b1};
        end
    end

    wire rstn_core = rst_sync[1];

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
    // Full fetch PC; the LED nibble is its low 4 bits (keeps the fetch
    // stage observable so synthesis doesn't sweep it away).
    wire [XLEN-1:0] cpu_pc_dbg;

    rv32imac_zicsr_zifencei u_cpu (
        .clk_i         (clk_core),
        .rstn_i        (rstn_core),
        .boot_addr_i   (32'h0000_0000),
        .imem_axi      (axi_bus_imem.master),
        .peri_axi      (axi_bus_peri.master),
        // fe_* / de_* debug taps: only fe_pc_dbg_o[3:0] is used here
        // (LEDs); the rest are unused on the board (swept by synthesis),
        // consumed by the simulation wrapper.
        .fe_pc_dbg_o   (cpu_pc_dbg),
        .fe_instr_dbg_o(),
        .fe_valid_dbg_o(),
        .de_pc_dbg_o   (),
        .de_instr_dbg_o(),
        .de_valid_dbg_o()
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
    // Debug LEDs: fetch PC low nibble. Keeps the design observable so
    // the synthesizer doesn't sweep the fetch stage away.
    // -----------------------------------------------------------------
    assign led_o                = cpu_pc_dbg[3:0];

endmodule
