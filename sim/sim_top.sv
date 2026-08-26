`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
 * Simulation top (Verilator). Mirrors top_module's peri bus wiring:
 *
 *   CPU.axi_peri -> axi_bus_peri -> axi4_lite_xbar_3 (1->3, base+size)
 *                    |-> u_uart  (0x1000_0000)
 *                    |-> u_timer (0x1000_1000+)
 *                    |-> u_msip  (0x1000_3000)
 * Fetch and the LSU each have a dedicated BSRAM (Harvard). The peri bus
 * carries the MSIP + CLINT timer MMIO slaves behind the peri xbar.
 *
 * No debug signals cross the CPU boundary (the CPU exports only its
 * functional ports). The C++ harness observes the per-stage taps
 * (fe_* / de_* / ex_* / writeback) by probing the Verilator hierarchy
 * directly — the sim is built with --public-flat, so the CPU-internal
 * nets (fe_pc_w, de_pc_w, ex_pc_w, wb_en, wb_addr, wb_data, ...) are
 * reachable as flat C++ members of the sim_top model. sim_top itself
 * therefore needs no debug output ports.
 *
 * This module is simulation-only; it is not part of the synthesis
 * file list.
 *
 * Naming follows the project convention: ports *_i/_o, internal
 * signals (incl. interface instances) have no prefix.
 */
module sim_top #(
    // UART clock/baud, overridable from the Verilator command line
    // (-GUART_CLK_HZ=... -GUART_BAUD=...). The defaults keep the sim fast
    // (5 clocks per bit); pass the board's real numbers
    // (25_000_000 / 115_200 -> 217 clocks per bit) to check the RX
    // sampling phase at the divisor the hardware actually uses.
    parameter int unsigned UART_CLK_HZ = 50_000_000,
    parameter int unsigned UART_BAUD   = 10_000_000
) (
    input  wire       clk_i,
    input  wire       rstn_i,
    // UART RX serial line, driven by the C++ harness (idle high). Lets a
    // serial-console program (YarvMon) be fed real bit-level input; the
    // harness paces one frame at a time off u_uart's rx_ready_q so it
    // cannot overrun the single-byte RX buffer. Tie high for no input.
    input  wire       uart_rxd_i,
    output wire [3:0] led_o
);

    // -----------------------------------------------------------------
    // AXI4-Lite peripheral bus (trunk modport) + peri 1->3 split. Window
    // bases/sizes come from rv32_pkg, same as the board top.
    // -----------------------------------------------------------------
    axi4_lite_if axi_bus_peri ();
    axi4_lite_if axi_bus_msip ();
    axi4_lite_if axi_bus_timer ();
    axi4_lite_if axi_bus_uart ();

    assign axi_bus_peri.aclk     = clk_i;
    assign axi_bus_peri.aresetn  = rstn_i;
    assign axi_bus_msip.aclk     = clk_i;
    assign axi_bus_msip.aresetn  = rstn_i;
    assign axi_bus_timer.aclk    = clk_i;
    assign axi_bus_timer.aresetn = rstn_i;
    assign axi_bus_uart.aclk     = clk_i;
    assign axi_bus_uart.aresetn  = rstn_i;

    // -----------------------------------------------------------------
    // Native memory ports. Fetch and the LSU each get a dedicated
    // native_ram.
    // -----------------------------------------------------------------
    // Fetch I-mem port is 64-bit read-only (ifetch); the LSU D-mem port stays
    // on the 32-bit byte-strobed mem_req_t / mem_rsp_t.
    ifetch_req_t imem_req;
    ifetch_rsp_t imem_rsp;
    mem_req_t    dmem_req;
    mem_rsp_t    dmem_rsp;
    // The read-only I-mem holds BVALID low (no write-ack); sink it so the
    // port is connected (a native_ram write-ack only exists for the D-mem).
    wire         imem_bvalid_unused;

    // Interrupt pending bits (mip.MSIP / mip.MTIP sources).
    wire         msip;
    wire         mtip;
    // Machine external interrupt: OR of the peripheral level IRQs (UART only
    // today), same term as the board top.
    wire         uart_irq;
    wire         meip = uart_irq;

    // -----------------------------------------------------------------
    // CPU. Functional ports only; debug is observed via the Verilator
    // hierarchy (--public-flat) from sim_main, not through ports here.
    // The aggregate stall tap (dbg_stall_o) is sunk to an unused wire —
    // it carries no per-stage debug, just a "pipe stalled" status bit.
    // -----------------------------------------------------------------
    wire         unused_dbg_stall;
    // IMEM_ADDR_W must match u_imem below: fetch uses it to tell a PC inside
    // the implemented I-mem from one outside it, which is the difference
    // between fetching an instruction and taking an access fault.
    rv32imac_zicsr_zifencei #(
        .IMEM_ADDR_W(14)
    ) u_cpu (
        .clk_i      (clk_i),
        .rstn_i     (rstn_i),
        .boot_addr_i(32'h0000_0000),
        .dbg_stall_o(unused_dbg_stall),
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
    // Instruction memory (read-only). Fetch's dedicated port. Preloaded
    // via $readmemh with the +IINIT=<path> plusarg (default "imem.hex").
    // -----------------------------------------------------------------
    native_ram #(
        // 16 KiB, same depth as top_module: the GW2AR-18C has 46 BSRAM
        // blocks (828 Kb), so two 64 KiB memories cannot both exist -- and a
        // simulation with different memories stops modelling the board
        // exactly where it matters. 64-bit wide: one access delivers two
        // 32-bit words; 2 outstanding keeps the BSRAM issuing through
        // decode stalls.
        .ADDR_W     (14),
        .DATA_WIDTH (64),
        .READ_ONLY  (1),
        .OUTSTANDING(2),
        .INIT_FILE  ("")
    ) u_imem (
        .clk_i       (clk_i),
        .rstn_i      (rstn_i),
        .req_valid_i (imem_req.valid),
        .req_we_i    (1'b0),               // read-only
        .req_addr_i  (imem_req.addr),
        .req_wdata_i ({64{1'b0}}),
        .req_wstrb_i ({8{1'b0}}),
        .req_rready_i(imem_req.rready),
        .rsp_wready_o(imem_rsp.ready),
        .rsp_rvalid_o(imem_rsp.rvalid),
        .rsp_rdata_o (imem_rsp.rdata),
        .rsp_bvalid_o(imem_bvalid_unused)
    );

    // -----------------------------------------------------------------
    // Data memory (byte-strobed read/write). Holds .rodata/.data/.bss
    // and the stack. Preloaded via $readmemh with the +DINIT=<path>
    // plusarg (default "dmem.hex").
    // -----------------------------------------------------------------
    native_ram #(
        // 16 KiB, same depth as top_module: the GW2AR-18C has 46 BSRAM
        // blocks (828 Kb), so two 64 KiB memories cannot both exist -- and a
        // simulation with different memories stops modelling the board
        // exactly where it matters.
        .ADDR_W     (14),
        .DATA_WIDTH (32),
        .READ_ONLY  (0),
        .OUTSTANDING(1),   // LSU single-outstanding
        .INIT_FILE  ("")
    ) u_dmem (
        .clk_i       (clk_i),
        .rstn_i      (rstn_i),
        .req_valid_i (dmem_req.wvalid),
        .req_we_i    (dmem_req.we),
        .req_addr_i  (dmem_req.addr),
        .req_wdata_i (dmem_req.wdata),
        .req_wstrb_i (dmem_req.wstrb),
        .req_rready_i(dmem_req.rready),
        .rsp_wready_o(dmem_rsp.wready),
        .rsp_rvalid_o(dmem_rsp.rvalid),
        .rsp_rdata_o (dmem_rsp.rdata),
        .rsp_bvalid_o(dmem_rsp.bvalid)
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

    // -----------------------------------------------------------------
    // RAM probe: expose a window of the data RAM as scalar wires so they
    // land in the VCD and can be watched in GTKWave (Verilator does not
    // trace unpacked arrays past --trace-max-array, so the full mem[] is
    // not in the VCD). The window is pointed at the program's data array
    // so you can watch it change as the program runs.
    //
    // Data lives in u_dmem (D-mem, 0-based). PROBE_BASE_WORD is the word
    // index of the data array in the data image — re-point it if the
    // link layout changes. word index = byte_addr / 4.
    // Default points at the C quicksort .data array (link.ld places .data
    // at DMEM 0x2000 = word 0x800, N=32 ints). The hand-crafted oracle
    // writes its data at 0x100 (word 64) at runtime — re-point there
    // (PROBE_BASE_WORD=64) to watch the oracle. The trap/timer tests
    // write their pass marker at 0x2000 (word 0x800) too.
    // In GTKWave the signals appear as:
    //   sim_top.g_mem_probe[<i>].mem_probe_w
    // -----------------------------------------------------------------
    localparam int unsigned PROBE_BASE_WORD = 64'h800;  // DMEM 0x2000 (.data / pass marker)
    localparam int unsigned PROBE_LEN = 64'd32;

    genvar gi;
    generate
        for (gi = 0; gi < PROBE_LEN; gi = gi + 1) begin : g_mem_probe
            wire [31:0] mem_probe_w = u_dmem.mem[PROBE_BASE_WORD+gi];
        end
    endgenerate

    // -----------------------------------------------------------------
    // Peripheral bus: peri 1->2 xbar (addr[12] decode) feeding the MSIP
    // and CLINT timer MMIO slaves, mirroring the board top.
    //   addr[12]=0 -> m_mem_axi  -> u_msip  (0x1000_0000)
    //   addr[12]=1 -> m_peri_axi -> u_timer (0x1000_1000+)
    // -----------------------------------------------------------------
    axi4_lite_xbar_3 #(
        .BASE0(UART_BASE),
        .SIZE0(UART_SIZE),
        .BASE1(MTIMER_BASE),
        .SIZE1(MTIMER_SIZE),
        .BASE2(MSIP_PERI_ADDR),
        .SIZE2(MSIP_PERI_SIZE)
    ) u_peri_xbar (
        .clk_i (clk_i),
        .rstn_i(rstn_i),
        .s_axi (axi_bus_peri.slave),
        .m0_axi(axi_bus_uart.master),
        .m1_axi(axi_bus_timer.master),
        .m2_axi(axi_bus_msip.master)
    );

    msip_peri u_msip (
        .clk_i (clk_i),
        .rstn_i(rstn_i),
        .axi   (axi_bus_msip.slave),
        .msip_o(msip)
    );

    clint_timer u_timer (
        .clk_i (clk_i),
        .rstn_i(rstn_i),
        .axi   (axi_bus_timer.slave),
        .mtip_o(mtip)
    );

    // Double-flop the harness RX line before the UART, exactly as
    // top_module does for the board pin. Parity matters: without it the
    // synchronizer that only exists in the board top is never exercised
    // in simulation, so a bug in it could not be reproduced here.
    logic [1:0] uart_rxd_sync_q;

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            uart_rxd_sync_q <= 2'b11;  // idle line is high
        end else begin
            uart_rxd_sync_q <= {uart_rxd_sync_q[0], uart_rxd_i};
        end
    end

    wire uart_txd;

    axi4_lite_uart #(
        .CLK_FREQ_HZ(UART_CLK_HZ),  // sim clock is a free-running C++ tick, not board-accurate
        .BAUD_RATE  (UART_BAUD)
    ) u_uart (
        .clk_i     (clk_i),
        .rstn_i    (rstn_i),
        .axi       (axi_bus_uart.slave),
        .txd_o     (uart_txd),
        .rxd_i     (uart_rxd_sync_q[1]),  // harness line, double-flopped (board parity)
        .uart_irq_o(uart_irq)
    );

    // -----------------------------------------------------------------
    // UART TX character monitor (sim only). Logs every byte the CPU
    // actually pushes into the TX shift buffer (u_uart.tx_push), so a
    // serial-console program such as YarvMon is observable without
    // decoding txd_o at the bit level. Dropped pushes (write while TX
    // busy) do not appear here -- by construction, since tx_push is
    // already gated on TX_READY, which is exactly the byte stream the
    // pin will carry.
    // -----------------------------------------------------------------
`ifdef VERILATOR
    int uart_log_fd;

    initial begin
        uart_log_fd = $fopen("sim_uart_tx.txt", "w");
    end

    always_ff @(posedge clk_i) begin
        if (rstn_i && u_uart.tx_push) begin
            $fwrite(uart_log_fd, "%c", u_uart.wdata_eff[7:0]);
            $fflush(uart_log_fd);
        end
    end
`endif

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
