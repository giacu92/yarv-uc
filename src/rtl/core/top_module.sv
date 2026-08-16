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
    // Differential 25 MHz reference clock from an MS5351M clock generator
    // (25 MHz crystal reference). P/N on PIN10/PIN11, Bank 6.
    input wire clk_p_i,
    input wire clk_n_i,
    input wire rstn_i,

    // Debug LEDs: low 4 bits of the fetch PC.
    output wire [3:0] led_o
);

    // -----------------------------------------------------------------
    // Clock generation
    //
    // Reference clock:
    //   clk_p_i / clk_n_i = 25 MHz differential (MS5351M, crystal-fed)
    //
    // Internal CPU clock (rPLL CLKOUT):
    //   clk_core = FCLKIN * FBDIV / IDIV = 25 * 20 / 5 = 100 MHz
    //   (IDIV_SEL=4 -> IDIV=5, FBDIV_SEL=19 -> FBDIV=20; ODIV_SEL=8
    //   only sets the VCO = 25*20*8/5 = 800 MHz, it does NOT divide
    //   CLKOUT). Period = 10 ns. Constrained in the SDC.
    // -----------------------------------------------------------------

    // Differential clock input: P/N -> single-ended for the rPLL.
    // Bank 6 has no on-chip 100R differential termination (only Bank 0/1
    // do), so the board must provide an external 100R across P/N.
    wire clk_ibuf;

    TLVDS_IBUF u_clk_ibuf (
        .I (clk_p_i),
        .IB(clk_n_i),
        .O (clk_ibuf)
    );

    wire clk_core;
    wire pll_lock;

    rPLL #(  // For GW2AR-LV18QN88C8/I7 (Tang Nano 20K)
        .FCLKIN   ("25"),
        .IDIV_SEL (4),     // -> PFD = 5 MHz (range: 3-400 MHz)
        .FBDIV_SEL(19),    // -> CLKOUT = 100 MHz (range: 3.125-600 MHz)
        .ODIV_SEL (8)      // -> VCO = 800 MHz (range: 400-1200 MHz)
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
        .CLKIN   (clk_ibuf),  // 25 MHz (from the differential input buffer)
        .CLKOUT  (clk_core),  // 100 MHz
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

    // Single clock domain: the whole fabric (CPU, both AXI4-Lite bridges,
    // the buses, and the RAM slave) runs on clk_core / rstn_core. There
    // is NO clock-domain crossing — clk_p_i (25 MHz) only feeds the
    // TLVDS_IBUF + rPLL, and rstn_i is the async board reset that feeds
    // the synchronizer.
    assign axi_bus_imem.aclk    = clk_core;
    assign axi_bus_imem.aresetn = rstn_core;
    assign axi_bus_peri.aclk    = clk_core;
    assign axi_bus_peri.aresetn = rstn_core;

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
        .clk_i (clk_core),
        .rstn_i(rstn_core),
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
