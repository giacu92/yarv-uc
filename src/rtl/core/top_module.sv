`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
 * Board-level top for the Tang Nano 20k (Gowin GW2AR-18C).
 *
 * Instantiates the RV32IMAC + Zicsr + Zifencei CPU and wires its memory
 * ports to on-die BSRAM. Harvard topology:
 *
 *   rv32imac_zicsr_zifencei
 *      |  imem (native, RO)   dmem (native, byte-strobed)   axi_peri
 *      v                      v                              v
 *   native_ram (u_imem)   native_ram (u_dmem)         axi_bus_peri
 *   (instr)                (data + .rodata + stack)      |
 *                                                        +-- axi4_lite_xbar
 *                                                        |     (peri 1->2,
 *                                                        |      addr[12])
 *                                                        |
 *                                       addr[12]=0 -----+--> u_msip  (0x1000_0000)
 *                                       addr[12]=1 -----+--> u_timer (0x1000_1000+)
 *
 *   Fetch and the LSU no longer contend: each has a dedicated native
 *   BSRAM port. AXI survives only for peripherals (the peri bridge is
 *   inside the CPU). The board top is pure point-to-point wires — the
 *   LSU steers addr[PERI_ADDR_BIT] internally, and the peri xbar here
 *   splits the peri bus into MSIP vs CLINT timer by addr[12].
 *
 * Pin assignments are in impl/pnr/rv32imac_Zicsr_Zifencei.cst.
 *
 * Naming: ports use *_i/_o; internal signals (including interface
 * instances) have no prefix. Module instance names keep u_*.
 */

module top_module (
    // 25 MHz reference clock from the MS5351M clock generator (crystal-fed).
    // The MS5351M drives independent single-ended CMOS clocks; CLK0 is on
    // PIN10. Used as a plain LVCMOS33 input (no differential / LVDS).
    input wire clk_i,
    input wire rstn_i,

    // UART
    input  wire uart_rxd_i,
    output wire uart_txd_o,

    // Debug LEDs: low 4 bits of the fetch PC.
    output wire [3:0] led_o
);

    // -----------------------------------------------------------------
    // Clock generation
    //
    // Reference clock:
    //   clk_i = 25 MHz (MS5351M clock generator, crystal-fed; CLK0 on
    //   PIN10, single-ended LVCMOS33)
    //
    // Internal CPU clock (rPLL CLKOUT) — target 35 MHz:
    //   clk_core = FCLKIN * FBDIV / IDIV = 25 * 7 / 5 = 35 MHz
    //   (IDIV_SEL=4 -> IDIV=5, FBDIV_SEL=6 -> FBDIV=7; ODIV_SEL=16 sets
    //   the VCO = 25*7*16/5 = 560 MHz and does NOT divide CLKOUT).
    //   Period = 40 * 5 / 7 = 28.571 ns. Constrained in the SDC.
    //
    // PnR closes 35 MHz knife-edge: 35.004 MHz Actual Fmax, +0.004 ns
    // worst setup slack (verified 2026-08-22). The route-dominated
    // CSR-address fan-out critical path runs at ~37 MHz actual, so 35 MHz
    // is the boundary — essentially zero margin, may not repeat run-to-run.
    // Comfortable fallback if a re-run fails: drop the rPLL and tie
    //   assign clk_core = clk_i;   // 25 MHz PLL-bypass, +2.248 ns slack
    // (the rPLL cannot do a clean 25 MHz out: VCO = 25*ODIV_SEL <= 400
    // < the 500 MHz floor, so 25 MHz bypasses the PLL entirely).
    //
    // VCO must stay in 500-1250 MHz (GowinSynthesis EX0311 range), and
    // ODIV_SEL is a bounded rPLL parameter (max 16 on this primitive;
    // larger values get replaced by the default 8, dropping the VCO
    // below the floor and tripping EX0311). For 35 MHz out the VCO is
    // 35*ODIV_SEL, so ODIV_SEL=16 gives the max VCO = 560 MHz (above the
    // 500 floor, +60 margin).
    // -----------------------------------------------------------------

    wire clk_core;
    wire pll_lock;

    rPLL #(  // For GW2AR-LV18QN88C8/I7 (Tang Nano 20K)
        .FCLKIN   ("25"),
        .IDIV_SEL (4),     // -> PFD = 5 MHz (range: 3-400 MHz)
        .FBDIV_SEL(6),     // -> CLKOUT = 35 MHz (range: 3.125-600 MHz)
        .ODIV_SEL (16)     // -> VCO = 560 MHz (range: 500-1250 MHz; ODIV_SEL max 16)
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
        .CLKIN   (clk_i),     // 25 MHz
        .CLKOUT  (clk_core),  // 35 MHz
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

    always_ff @(posedge clk_core) begin
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
    // AXI4-Lite buses (trunk modport).
    //
    //   axi_bus_peri  : CPU peri master -> peri xbar (1->2, addr[12] decode).
    //   axi_bus_msip  : xbar mem master  -> MSIP slave  (0x1000_0000, [12]=0).
    //   axi_bus_timer : xbar peri master -> timer slave (0x1000_1000+, [12]=1).
    // -----------------------------------------------------------------
    axi4_lite_if axi_bus_peri ();
    axi4_lite_if axi_bus_msip ();
    axi4_lite_if axi_bus_timer ();
    axi4_lite_if axi_bus_uart ();

    // Single clock domain: the whole fabric (CPU bridge, memories, the
    // buses) runs on clk_core / rstn_core. There is NO clock-domain
    // crossing — clk_i (25 MHz) only feeds the rPLL, and rstn_i is the
    // async board reset that feeds the synchronizer.
    assign axi_bus_peri.aclk     = clk_core;
    assign axi_bus_peri.aresetn  = rstn_core;
    assign axi_bus_msip.aclk     = clk_core;
    assign axi_bus_msip.aresetn  = rstn_core;
    assign axi_bus_timer.aclk    = clk_core;
    assign axi_bus_timer.aresetn = rstn_core;
    assign axi_bus_uart.aclk     = clk_core;
    assign axi_bus_uart.aresetn  = rstn_core;

    // Debug tap: decode or execute stage stall.
    wire dbg_stall;

    // -----------------------------------------------------------------
    // Native memory ports. Fetch and the LSU each get a dedicated BSRAM;
    // the LSU steers RAM vs peri on addr[PERI_ADDR_BIT] itself, so the
    // board top needs no crossbar for memory.
    // -----------------------------------------------------------------
    mem_req_t imem_req;
    mem_rsp_t imem_rsp;
    mem_req_t dmem_req;
    mem_rsp_t dmem_rsp;

    // Interrupt pending bits from the peri MMIO slaves.
    wire msip;
    wire mtip;

    // Machine external interrupt: OR of the peripheral level IRQs. Only the
    // UART raises one today; add further peripherals to this term (or swap in
    // a PLIC) as they arrive.
    wire uart_irq;
    wire meip = uart_irq;

    // -----------------------------------------------------------------
    // CPU. Functional ports only — no debug crosses the CPU boundary
    // (the per-stage taps are internal; the simulation probes them via
    // the Verilator hierarchy).
    // -----------------------------------------------------------------
    rv32imac_zicsr_zifencei u_cpu (
        .clk_i      (clk_core),
        .rstn_i     (rstn_core),
        .boot_addr_i(32'h0000_0000),
        .dbg_stall_o(dbg_stall),
        .axi_peri   (axi_bus_peri.master),
        .imem_req_o (imem_req),
        .imem_rsp_i (imem_rsp),
        .dmem_req_o (dmem_req),
        .dmem_rsp_i (dmem_rsp),
        .msip_i     (msip),
        .mtip_i     (mtip),
        .meip_i     (meip)
    );

    // -----------------------------------------------------------------
    // Instruction memory (read-only). Fetch's dedicated port — no
    // contention with the LSU. Preloaded with firmware via INIT_FILE
    // (see the parameter comment below); simulation preloads via
    // $readmemh in sim_top.
    // -----------------------------------------------------------------
    native_ram #(
        .ADDR_W    (16),             // 64 KiB
        .DATA_WIDTH(32),
        .READ_ONLY (1),
        // A read-only I-mem with no init and no write port is a zero-ROM:
        // Gowin folds every read to constant 0, the fetch stream becomes
        // all-illegal, and the whole pipeline (regfile/csr/alu/execute)
        // gets swept as dead code -- only fetch+decode survive because
        // they feed dbg_stall_o. So the I-mem MUST carry firmware for any
        // meaningful (or even timing-representative) synthesis. This is
        // the timing-closure / bring-up firmware (the sim oracle, a
        // self-contained program that stores its own .data at runtime, so
        // no D-mem preload is needed). A real product bitstream re-points
        // this at the application firmware. Path is relative to the Gowin
        // project dir (repo root).
        .INIT_FILE ("sim/imem.hex")
    ) u_imem (
        .clk_i    (clk_core),
        .rstn_i   (rstn_core),
        .mem_req_i(imem_req),
        .mem_rsp_o(imem_rsp)
    );

    // -----------------------------------------------------------------
    // Data memory (byte-strobed read/write). Holds .rodata/.data/.bss
    // and the stack. LSU's dedicated port.
    // -----------------------------------------------------------------
    native_ram #(
        .ADDR_W    (16),  // 64 KiB
        .DATA_WIDTH(32),
        .READ_ONLY (0),
        .INIT_FILE ("")
    ) u_dmem (
        .clk_i    (clk_core),
        .rstn_i   (rstn_core),
        .mem_req_i(dmem_req),
        .mem_rsp_o(dmem_rsp)
    );

    // -----------------------------------------------------------------
    // Peripheral bus: 1->2 address-decode mux splitting the peri bus
    // into the MSIP slave and the CLINT timer slave by addr[12]
    // (roadmap item 2 — same xbar pattern as the mem/peri split, one
    // level down). Single-outstanding pass-through (the CPU bridge is
    // single-outstanding overall). A 3rd slave (UART/GPIO) later needs
    // a generalized 1->N mux.
    //   addr[12]=0 -> m_mem_axi  -> MSIP  (0x1000_0000)
    //   addr[12]=1 -> m_peri_axi -> timer (0x1000_1000+)
    // -----------------------------------------------------------------
    axi4_lite_xbar_3 #(
        .BASE0(32'h1000_0000),
        .SIZE0(32'h0000_1000),  // uart
        .BASE1(32'h1000_1000),
        .SIZE1(32'h0000_2000),  // timer
        .BASE2(32'h1000_3000),
        .SIZE2(32'h0000_1000)   // msip
    ) u_peri_xbar (
        .clk_i (clk_core),
        .rstn_i(rstn_core),
        .s_axi (axi_bus_peri.slave),
        .m0_axi(axi_bus_uart),
        .m1_axi(axi_bus_timer.master),
        .m2_axi(axi_bus_msip.master)
    );

    // -----------------------------------------------------------------
    // MSIP MMIO slave (machine software interrupt). A write of bit[0]
    // to MSIP_PERI_ADDR (0x1000_0000) sets/clears mip.MSIP; msip_o feeds
    // u_cpu.msip_i.
    // -----------------------------------------------------------------
    msip_peri u_msip (
        .clk_i (clk_core),
        .rstn_i(rstn_core),
        .axi   (axi_bus_msip.slave),
        .msip_o(msip)
    );

    // -----------------------------------------------------------------
    // CLINT timer MMIO slave (machine timer interrupt). mtip_o = (mtime
    // >= mtimecmp); feeds u_cpu.mtip_i (mip.MTIP). SW clears it by
    // writing mtimecmp > mtime.
    // -----------------------------------------------------------------
    clint_timer u_timer (
        .clk_i (clk_core),
        .rstn_i(rstn_core),
        .axi   (axi_bus_timer.slave),
        .mtip_o(mtip)
    );

    // -----------------------------------------------------------------
    // UART Controller
    // -----------------------------------------------------------------
    logic uart_irq;

    axi4_lite_uart #(
        .CLK_FREQ_HZ(35e6),
        .BAUD_RATE  (115200)
    ) uart_i (
        .clk_i (clk_core),
        .rstn_i(rstn_core),
        .axi   (axi_bus_uart),
        .txd_o (uart_txd_o),
        .rxd_i (uart_rxd_i),

        .uart_irq_o(uart_irq)
    );

    // -----------------------------------------------------------------
    // Debug LEDs:
    // led_o[0]: stall indicator (high when the CPU is stalled, low when it is running)
    // led_o[3:1]: free-running counter on clk_core (alive indicator).
    // -----------------------------------------------------------------
    logic [27:0] led_cnt_q;

    always_ff @(posedge clk_core) begin
        if (!rstn_core) begin
            led_cnt_q <= '0;
        end else begin
            led_cnt_q <= led_cnt_q + 1'b1;
        end
    end

    assign led_o[3:1] = led_cnt_q[27:25];
    assign led_o[0]   = dbg_stall;

endmodule

`resetall
