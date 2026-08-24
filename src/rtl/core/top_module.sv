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
 *                                                        +-- axi4_lite_xbar_3
 *                                                        |     (peri 1->3,
 *                                                        |      base+size)
 *                                                        |
 *                            0x1000_0000..0FFF ----------+--> uart_i  (UART)
 *                            0x1000_1000..2FFF ----------+--> u_timer (CLINT)
 *                            0x1000_3000..3FFF ----------+--> u_msip  (MSIP)
 *
 *   Fetch and the LSU no longer contend: each has a dedicated native
 *   BSRAM port. AXI survives only for peripherals (the peri bridge is
 *   inside the CPU). The board top is pure point-to-point wires — the
 *   LSU steers addr[PERI_ADDR_BIT] internally, and the peri xbar here
 *   splits the peri bus into UART / CLINT timer / MSIP by base+size.
 *   The window bases come from rv32_pkg (UART_BASE / MTIMER_BASE /
 *   MSIP_PERI_ADDR) so the map is defined in exactly one place.
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
    // Board reset button S1 on PIN88. This board's button is ACTIVE-HIGH:
    // pressed = PIN88 HIGH = reset; released = LOW = run (the board pulls
    // the pin low when released). So the reset here is active-high — the
    // system runs with the button untouched and resets only while S1 is
    // held. (An earlier build treated this pin as active-low rstn_i, which
    // inverted the polarity and forced the button to be held to run.)
    input wire rst_i,

    // UART
    input  wire uart_rxd_i,
    output wire uart_txd_o,

    // Debug LEDs: led_o[0] = stall indicator, led_o[3:1] = alive counter.
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

    // clk_core frequency, in Hz. MUST track the clock source below: it is
    // what the UART divides down to hit BAUD_RATE, so editing the clock
    // source without editing this too leaves the UART running at the wrong
    // baud (garbage on the wire).
    //
    // *** 25 MHz PLL-BYPASS MODE (active). ***
    // clk_core = clk_i directly (the 25 MHz MS5351M reference on PIN10),
    // rPLL disabled. This is the documented fallback (+2.248 ns setup
    // slack vs the knife-edge 35 MHz rPLL path) AND a diagnostic: it
    // removes the rPLL from the picture, so if the design still does not
    // come alive on silicon the clock reference itself (clk_i / MS5351M)
    // is the culprit, not the rPLL. UART baud at 25 MHz: BAUDDIV resets to
    // CLK_FREQ_HZ/BAUD_RATE-1 = 216, so baud = 25e6/217 = 115 207 Hz
    // (115200, 0.006% off, well within RS-232 tolerance). To return to
    // 35 MHz: restore the rPLL instance below and set CLK_CORE_HZ =
    // 35_000_000.
    localparam int unsigned CLK_CORE_HZ = 25_000_000;

    wire clk_core = clk_i;  // PLL-bypass: core runs on the 25 MHz reference
    wire pll_lock = 1'b1;  // no rPLL -> always "locked"

    // rPLL instance (disabled in bypass mode). Restore this block (and
    // change CLK_CORE_HZ to 35_000_000, clk_core/pll_lock back to declared
    // wires) to retarget 35 MHz. Kept here so the bypass is a one-spot
    // toggle, not a delete-and-rewrite.
    // rPLL #(  // For GW2AR-LV18QN88C8/I7 (Tang Nano 20K)
    //     .FCLKIN   ("25"),
    //     .IDIV_SEL (4),     // -> PFD = 5 MHz (range: 3-400 MHz)
    //     .FBDIV_SEL(6),     // -> CLKOUT = 35 MHz (range: 3.125-600 MHz)
    //     .ODIV_SEL (16)     // -> VCO = 560 MHz (range: 500-1250 MHz; ODIV_SEL max 16)
    // ) pll (
    //     .CLKOUTP (),
    //     .CLKOUTD (),
    //     .CLKOUTD3(),
    //     .RESET   (1'b0),
    //     .RESET_P (1'b0),
    //     .CLKFB   (1'b0),
    //     .FBDSEL  (6'b0),
    //     .IDSEL   (6'b0),
    //     .ODSEL   (6'b0),
    //     .PSDA    (4'b0),
    //     .DUTYDA  (4'b0),
    //     .FDLY    (4'b0),
    //     .CLKIN   (clk_i),     // 25 MHz
    //     .CLKOUT  (clk_core),  // 35 MHz
    //     .LOCK    (pll_lock)
    // );

    // -----------------------------------------------------------------
    // Reset synchronization
    //
    // Reset is asserted while:
    //   - the external reset button S1 is pressed (rst_i HIGH — active-high
    //     on this board, see the port comment), OR
    //   - PLL has not locked yet.
    //
    // Deassertion is synchronized to clk_core.
    // -----------------------------------------------------------------

    logic [1:0] rst_sync;

    always_ff @(posedge clk_core) begin
        if (rst_i) begin
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
    //   axi_bus_peri  : CPU peri master -> peri xbar (1->3, base+size decode).
    //   axi_bus_uart  : xbar m0 -> UART  slave (UART_BASE      0x1000_0000).
    //   axi_bus_timer : xbar m1 -> timer slave (MTIMER_BASE    0x1000_1000).
    //   axi_bus_msip  : xbar m2 -> MSIP  slave (MSIP_PERI_ADDR 0x1000_3000).
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
        .ADDR_W    (16),                              // 64 KiB
        .DATA_WIDTH(32),
        .READ_ONLY (1),
        // A read-only I-mem with no init and no write port is a zero-ROM:
        // Gowin folds every read to constant 0, the fetch stream becomes
        // all-illegal, and the whole pipeline (regfile/csr/alu/execute)
        // gets swept as dead code -- only fetch+decode survive because
        // they feed dbg_stall_o. So the I-mem MUST carry firmware for any
        // meaningful (or even timing-representative) synthesis. The
        // default product firmware is YarvMon (sim/sw-yarvmon), a wozmon-
        // style serial monitor over the UART (115200 8N1 on uart_rxd_i/
        // uart_txd_o): type hex addresses to examine, ':' to deposit,
        // '.' for a block dump, 'R' to call an address. Its image is built
        // by `make` in sim/sw-yarvmon/ (imem.hex = .text/.text.init -> I-mem
        // 0x0, dmem.hex = .rodata/.data -> D-mem 0x2000). Path is relative
        // to the Gowin project dir (repo root).
        .INIT_FILE ("sim/sw-yarvmon/build/imem.hex")
    ) u_imem (
        .clk_i    (clk_core),
        .rstn_i   (rstn_core),
        .mem_req_i(imem_req),
        .mem_rsp_o(imem_rsp)
    );

    // -----------------------------------------------------------------
    // Data memory (byte-strobed read/write). Holds .rodata/.data/.bss
    // and the stack. LSU's dedicated port. Preloaded with the firmware's
    // .rodata/.data image (dmem.hex, @ word 0x800 = byte 0x2000, matching
    // the link VMA) so the monitor's strings/literals are present at
    // power-up; .bss and the stack are zeroed by start.S / runtime use.
    // -----------------------------------------------------------------
    native_ram #(
        .ADDR_W    (16),                              // 64 KiB
        .DATA_WIDTH(32),
        .READ_ONLY (0),
        .INIT_FILE ("sim/sw-yarvmon/build/dmem.hex")
    ) u_dmem (
        .clk_i    (clk_core),
        .rstn_i   (rstn_core),
        .mem_req_i(dmem_req),
        .mem_rsp_o(dmem_rsp)
    );

    // -----------------------------------------------------------------
    // Peripheral bus: 1->3 address-decode mux splitting the peri bus into
    // the UART, the CLINT timer and the MSIP slave by base+size.
    // Single-outstanding pass-through (the CPU bridge is single-outstanding
    // overall). An address in the peri region matching no window is completed
    // with a DECERR by the xbar's terminator, not left to hang.
    //   m0 UART_BASE      (0x1000_0000, 4 KiB)
    //   m1 MTIMER_BASE    (0x1000_1000, 8 KiB)
    //   m2 MSIP_PERI_ADDR (0x1000_3000, 4 KiB)
    // -----------------------------------------------------------------
    axi4_lite_xbar_3 #(
        .BASE0(UART_BASE),
        .SIZE0(UART_SIZE),
        .BASE1(MTIMER_BASE),
        .SIZE1(MTIMER_SIZE),
        .BASE2(MSIP_PERI_ADDR),
        .SIZE2(MSIP_PERI_SIZE)
    ) u_peri_xbar (
        .clk_i (clk_core),
        .rstn_i(rstn_core),
        .s_axi (axi_bus_peri.slave),
        .m0_axi(axi_bus_uart.master),
        .m1_axi(axi_bus_timer.master),
        .m2_axi(axi_bus_msip.master)
    );

    // -----------------------------------------------------------------
    // MSIP MMIO slave (machine software interrupt). A write of bit[0]
    // to MSIP_PERI_ADDR (0x1000_3000) sets/clears mip.MSIP; msip_o feeds
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
    // UART Controller.
    //
    // uart_rxd_i comes off a board pin driven by a far-end transmitter with
    // its own oscillator: asynchronous to clk_core no matter that the fabric
    // is single-domain. Double-flop it before it reaches the RX sampler --
    // axi4_lite_uart samples rxd_i straight into its shift register and has
    // no framing-error flag, so a metastable sample would silently corrupt a
    // received byte.
    // -----------------------------------------------------------------
    logic [1:0] uart_rxd_sync_q;

    always_ff @(posedge clk_core) begin
        if (!rstn_core) begin
            uart_rxd_sync_q <= 2'b11;  // idle line is high
        end else begin
            uart_rxd_sync_q <= {uart_rxd_sync_q[0], uart_rxd_i};
        end
    end

    axi4_lite_uart #(
        .CLK_FREQ_HZ(CLK_CORE_HZ),
        .BAUD_RATE  (115200)
    ) uart_i (
        .clk_i (clk_core),
        .rstn_i(rstn_core),
        .axi   (axi_bus_uart.slave),
        .txd_o (uart_txd_o),
        .rxd_i (uart_rxd_sync_q[1]),

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
