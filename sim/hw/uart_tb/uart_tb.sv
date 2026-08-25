`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * Focused axi4_lite_uart testbench wrapper.
 *
 * Instantiates the UART as an AXI4-Lite slave and exposes the master-side
 * AXI signals, the serial pins and the IRQ line as flat ports so the C++
 * BFM (uart_tb.cpp) can drive/observe them directly. NOT part of
 * synthesis.
 *
 * What this test exists to cover (the bug it was written for): with a
 * single-byte RX buffer, a terminal that ships a whole typed line in one
 * burst loses every byte that arrives while software is busy echoing the
 * previous one. The FIFOs fix that, so the checks here are about FIFO
 * depth, ordering, overrun reporting and the level-sensitive IRQ -- not
 * just the AXI handshake.
 *
 * Baud is deliberately tiny (CLK_FREQ_HZ/BAUD_RATE = 10 clocks per bit)
 * so a frame costs 100 cycles instead of 2170: the divisor logic is
 * identical at any ratio, and the phase behaviour at the board's real
 * 217-clocks-per-bit divisor is covered by the sim_top harness.
 */

module uart_tb #(
    parameter int unsigned TX_FIFO_DEPTH = 16,
    parameter int unsigned RX_FIFO_DEPTH = 16
) (
    input wire clk_i,
    input wire rstn_i,

    // Master -> slave (driven by the C++ BFM)
    input wire [31:0] awaddr,
    input wire        awvalid,
    input wire [31:0] wdata,
    input wire [ 3:0] wstrb,
    input wire        wvalid,
    input wire        bready,
    input wire [31:0] araddr,
    input wire        arvalid,
    input wire        rready,

    // Slave -> master (sampled by the C++ BFM)
    output wire        awready,
    output wire        wready,
    output wire        bvalid,
    output wire [ 1:0] bresp,
    output wire        arready,
    output wire [31:0] rdata,
    output wire [ 1:0] rresp,
    output wire        rvalid,

    // Serial pins + level IRQ
    input  wire rxd_i,
    output wire txd_o,
    output wire uart_irq_o
);

    axi4_lite_if axi ();

    assign axi.aclk    = clk_i;
    assign axi.aresetn = rstn_i;

    // Master side, driven from the BFM inputs.
    assign axi.awaddr  = awaddr;
    assign axi.awvalid = awvalid;
    assign axi.wdata   = wdata;
    assign axi.wstrb   = wstrb;
    assign axi.wvalid  = wvalid;
    assign axi.bready  = bready;
    assign axi.araddr  = araddr;
    assign axi.arvalid = arvalid;
    assign axi.rready  = rready;

    // Slave side, exposed to the BFM.
    assign awready     = axi.awready;
    assign wready      = axi.wready;
    assign bvalid      = axi.bvalid;
    assign bresp       = axi.bresp;
    assign arready     = axi.arready;
    assign rdata       = axi.rdata;
    assign rresp       = axi.rresp;
    assign rvalid      = axi.rvalid;

    axi4_lite_uart #(
        .CLK_FREQ_HZ  (1000),           // 10 clocks per bit (see header)
        .BAUD_RATE    (100),
        .TX_FIFO_DEPTH(TX_FIFO_DEPTH),
        .RX_FIFO_DEPTH(RX_FIFO_DEPTH)
    ) u_uart (
        .clk_i     (clk_i),
        .rstn_i    (rstn_i),
        .axi       (axi.slave),
        .txd_o     (txd_o),
        .rxd_i     (rxd_i),
        .uart_irq_o(uart_irq_o)
    );

endmodule

`resetall
