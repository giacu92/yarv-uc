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
    // Internal CPU clock:
    //   clk_core = clk_i = 25 MHz (direct, no rPLL).
    //
    // The core was previously clocked at 40 MHz via an rPLL (25 * 8 / 5).
    // Adding the machine timer (CLINT 64-bit mtime/mtimecmp) + the trap
    // redirect path exposed the route-dominated CSR-address fan-out
    // (async CSR read mux + write-decode -> fetch pc_q / regfile DI) at
    // ~37 MHz actual Fmax, so 40 MHz no longer closes. Rather than pipeline
    // the async CSR read (an invasive change to Zicsr read latency), the
    // target is backed off to 25 MHz. Since clk_i is already a clean
    // 25 MHz crystal clock, regenerating it through a 1:1 rPLL would only
    // add jitter (and VCO-range risk) for no gain — so the PLL is dropped
    // and clk_core is clk_i directly. Period = 40 ns. Constrained in the
    // SDC as the single clk25 clock (no generated clock). A future higher-
    // frequency target re-adds the rPLL (FBDIV/IDIV > 1, VCO 500-1250 MHz).
    // -----------------------------------------------------------------

    wire clk_core = clk_i;

    // -----------------------------------------------------------------
    // Reset synchronization
    //
    // Reset is asserted while the external reset is asserted;
    // deassertion is synchronized to clk_core (clk_i). With no PLL there
    // is no lock signal to wait on.
    // -----------------------------------------------------------------

    logic [1:0] rst_sync;

    always_ff @(posedge clk_core) begin
        if (!rstn_i) begin
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

    // Single clock domain: the whole fabric (CPU bridge, memories, the
    // buses) runs on clk_core (= clk_i, 25 MHz) / rstn_core. There is NO
    // clock-domain crossing — clk_i drives the fabric directly (no rPLL),
    // and rstn_i is the async board reset that feeds the synchronizer.
    assign axi_bus_peri.aclk     = clk_core;
    assign axi_bus_peri.aresetn  = rstn_core;
    assign axi_bus_msip.aclk     = clk_core;
    assign axi_bus_msip.aresetn  = rstn_core;
    assign axi_bus_timer.aclk    = clk_core;
    assign axi_bus_timer.aresetn = rstn_core;

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
        .mtip_i     (mtip)
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
    axi4_lite_xbar #(
        .SEL_BIT(12)
    ) u_peri_xbar (
        .clk_i     (clk_core),
        .rstn_i    (rstn_core),
        .s_axi     (axi_bus_peri.slave),
        .m_mem_axi (axi_bus_msip.master),
        .m_peri_axi(axi_bus_timer.master)
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
