`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
 * Board-level top for the Tang Nano 20k (Gowin GW2AR-18C).
 *
 * Instantiates the RV32IMAC + Zicsr + Zifencei CPU and wires its memory
 * ports to on-die BSRAM. Two build topologies, selected by VON_NEUMANN:
 *
 * Harvard (default, VON_NEUMANN undefined):
 *
 *   rv32imac_zicsr_zifencei
 *      |  imem (native, read-only)   dmem (native, byte-strobed)   axi_peri
 *      v                             v                              v
 *   native_ram (u_imem, RO)      native_ram (u_dmem, RW)        axi_bus_peri
 *   (instr)                       (data + .rodata + stack)       (open, future UART/GPIO)
 *
 *   Fetch and the LSU no longer contend: each has a dedicated native
 *   BSRAM port. AXI survives only for peripherals (the peri bridge is
 *   inside the CPU). The board top is pure point-to-point wires — no
 *   crossbar, no mem/peri decode here (the LSU steers addr[PERI_ADDR_BIT]
 *   internally).
 *
 * Von-Neumann legacy (VON_NEUMANN defined):
 *
 *   rv32imac_zicsr_zifencei
 *      |  bus_axi (master: instr + data + MMIO, von Neumann)
 *      v
 *   axi4_lite_xbar (1 slave -> 2 masters, addr[PERI_ADDR_BIT] decode)
 *      |  m_mem_axi                       m_peri_axi
 *      v                                  v
 *   axi4_lite_ram (instr+data)          axi_bus_peri (open, future UART/GPIO)
 *
 *   Fetch + LSU share one AXI master through a mem_arbiter inside the
 *   CPU; the board top owns the mem/peri address-decode (the crossbar).
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
    // Internal CPU clock (rPLL CLKOUT):
    //   clk_core = FCLKIN * FBDIV / IDIV = 25 * 10 / 5 = 50 MHz
    //   (IDIV_SEL=4 -> IDIV=5, FBDIV_SEL=9 -> FBDIV=10; ODIV_SEL=16
    //   only sets the VCO = 25*10*16/5 = 800 MHz, it does NOT divide
    //   CLKOUT). Period = 20 ns. Constrained in the SDC.
    //
    // Target lowered 100 -> 50 MHz: the execute stage + regfile (BSRAM)
    // combinational depth does not meet 100 MHz, and Fmax is not the
    // current goal. 50 MHz gives margin below the ~54 MHz BSRAM cap.
    //
    // VCO must stay in 500-1250 MHz (GowinSynthesis EX0311 range for this
    // rPLL). CLKOUT=FCLKIN*FBDIV/IDIV is independent of ODIV, so to halve
    // CLKOUT 100->50 while keeping VCO at the proven 800 MHz, FBDIV halves
    // (20->10) AND ODIV doubles (8->16): VCO = 25*10*16/5 = 800 MHz.
    // -----------------------------------------------------------------

    wire clk_core;
    wire pll_lock;

    rPLL #(  // For GW2AR-LV18QN88C8/I7 (Tang Nano 20K)
        .FCLKIN   ("25"),
        .IDIV_SEL (4),     // -> PFD = 5 MHz (range: 3-400 MHz)
        .FBDIV_SEL(9),     // -> CLKOUT = 50 MHz (range: 3.125-600 MHz)
        .ODIV_SEL (16)     // -> VCO = 800 MHz (range: 500-1250 MHz)
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
        .CLKOUT  (clk_core),  // 50 MHz
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
    // AXI4-Lite buses (trunk modport)
    //
    //   Harvard     : axi_bus_peri only (CPU peri master -> open slave).
    //   Von-Neumann : axi_bus_cpu (CPU master -> crossbar), axi_bus_mem
    //                 (crossbar mem master -> RAM), axi_bus_peri (open).
    // -----------------------------------------------------------------
`ifdef VON_NEUMANN
    axi4_lite_if axi_bus_cpu ();
    axi4_lite_if axi_bus_mem ();
`endif
    axi4_lite_if axi_bus_peri ();

    // Single clock domain: the whole fabric (CPU bridge, memories, the
    // buses) runs on clk_core / rstn_core. There is NO clock-domain
    // crossing — clk_i (25 MHz) only feeds the rPLL, and rstn_i is the
    // async board reset that feeds the synchronizer.
`ifdef VON_NEUMANN
    assign axi_bus_cpu.aclk    = clk_core;
    assign axi_bus_cpu.aresetn = rstn_core;
    assign axi_bus_mem.aclk    = clk_core;
    assign axi_bus_mem.aresetn = rstn_core;
`endif
    assign axi_bus_peri.aclk    = clk_core;
    assign axi_bus_peri.aresetn = rstn_core;

    // Debug tap: decode or execute stage stall.
    wire dbg_stall;

    // -----------------------------------------------------------------
    // Native memory ports (Harvard). Fetch and the LSU each get a
    // dedicated BSRAM; the LSU steers RAM vs peri on addr[PERI_ADDR_BIT]
    // itself, so the board top needs no crossbar for memory.
    // -----------------------------------------------------------------
`ifndef VON_NEUMANN
    mem_req_t imem_req;
    mem_rsp_t imem_rsp;
    mem_req_t dmem_req;
    mem_rsp_t dmem_rsp;
`endif

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
`else
    // -----------------------------------------------------------------
    // 1->2 AXI4-Lite crossbar: splits the CPU bus into a memory region
    // and a peripheral region by address (addr[PERI_ADDR_BIT]=1 -> peri,
    // else mem). Single-outstanding pass-through (the CPU bridge is
    // single-outstanding overall). See axi4_lite_xbar for routing.
    // -----------------------------------------------------------------
    axi4_lite_xbar #(
        .SEL_BIT(PERI_ADDR_BIT)
    ) u_xbar (
        .clk_i     (clk_core),
        .rstn_i    (rstn_core),
        .s_axi     (axi_bus_cpu.slave),
        .m_mem_axi (axi_bus_mem.master),
        .m_peri_axi(axi_bus_peri.master)
    );

    // -----------------------------------------------------------------
    // Memory RAM on the mem master (von Neumann: instructions + data).
    // -----------------------------------------------------------------
    axi4_lite_ram #(
        .ADDR_W   (16),  // 64 KiB
        .INIT_FILE("")
    ) u_ram (
        .clk_i (clk_core),
        .rstn_i(rstn_core),
        .axi   (axi_bus_mem.slave)
    );
`endif

    // -----------------------------------------------------------------
    // Peripheral bus: reserved for memory-mapped peripherals (UART, GPIO,
    // ...). No slave instantiated yet — the trunk is left open on the
    // slave side (tied off) so a peripheral drops in without rewiring.
    // NOTE: with no slave, awready/arready are 0, so a peripheral
    // access would stall the LSU until a real slave is added. No code
    // should target the peri region until then.
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
