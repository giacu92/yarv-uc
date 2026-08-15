`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * Focused AXI4-Lite RAM testbench wrapper.
 *
 * Instantiates axi4_lite_ram as a slave and exposes the master-side
 * AXI4-Lite signals as flat ports so the C++ BFM (ram_tb.cpp) can drive
 * them directly. This is NOT part of synthesis; it is a protocol
 * compliance test for the write (B) and read (R) channels, in
 * particular:
 *   - BVALID is registered and held until BREADY (with a master whose
 *     bready is deliberately delayed), and
 *   - AW and W may arrive in either order, and
 *   - byte-strobed writes are read back correctly.
 *
 * The RAM module does not import rv32_pkg; neither does this wrapper.
 */

module ram_tb (
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
    output wire        rvalid
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

    axi4_lite_ram #(
        .ADDR_W   (16),  // 64 KiB
        .INIT_FILE("")
    ) u_ram (
        .clk_i (clk_i),
        .rstn_i(rstn_i),
        .axi   (axi.slave)
    );

endmodule

`resetall
