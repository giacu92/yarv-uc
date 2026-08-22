`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
 * Focused native mem_req_t / mem_rsp_t RAM compliance testbench wrapper.
 *
 * Instantiates two native_ram slaves and exposes the master-side native
 * signals as flat ports so the C++ BFM (native_mem_tb.cpp) can drive them
 * directly:
 *   - u_dmem : READ_ONLY=0 (the LSU's byte-strobed D-mem).
 *   - u_imem : READ_ONLY=1 (the fetch read-only I-mem).
 *
 * This is NOT part of synthesis; it is a protocol-compliance gate for the
 * native interface, analogous to ram_tb for AXI4-Lite. It checks:
 *   - RVALID is registered and held until RREADY (the key fix vs a naive
 *     one-cycle pulse): the master deliberately keeps RREADY low for
 *     several cycles after RVALID rises; RVALID must not drop.
 *   - byte-strobed writes read back correctly.
 *   - back-to-back writes to distinct addresses.
 *   - single-outstanding: WREADY is low while an unread read response is
 *     held (RVALID=1, RREADY=0).
 *   - posted store: a store (we=1) commits at the launch handshake
 *     (wvalid && wready) and is immediately readable.
 *   - read-only: a write to u_imem (READ_ONLY=1) is ignored.
 */

module native_mem_tb (
    input wire clk_i,
    input wire rstn_i,

    // --- D-mem (RW) master -> slave, driven by the BFM ---
    input  wire        d_wvalid,
    input  wire        d_we,
    input  wire [31:0] d_addr,
    input  wire [31:0] d_wdata,
    input  wire [ 3:0] d_wstrb,
    input  wire        d_rready,
    // D-mem slave -> master, sampled by the BFM
    output wire        d_wready,
    output wire        d_rvalid,
    output wire [31:0] d_rdata,
    output wire        d_bvalid,

    // --- I-mem (RO) master -> slave, driven by the BFM ---
    input  wire        i_wvalid,
    input  wire        i_we,
    input  wire [31:0] i_addr,
    input  wire [31:0] i_wdata,
    input  wire [ 3:0] i_wstrb,
    input  wire        i_rready,
    // I-mem slave -> master, sampled by the BFM
    output wire        i_wready,
    output wire        i_rvalid,
    output wire [31:0] i_rdata,
    output wire        i_bvalid
);

    // -----------------------------------------------------------------
    // D-mem (read/write, byte-strobed)
    // -----------------------------------------------------------------
    mem_req_t d_req;
    mem_rsp_t d_rsp;

    assign d_req.wvalid = d_wvalid;
    assign d_req.we     = d_we;
    assign d_req.addr   = d_addr;
    assign d_req.wdata  = d_wdata;
    assign d_req.wstrb  = d_wstrb;
    assign d_req.rready = d_rready;

    assign d_wready     = d_rsp.wready;
    assign d_rvalid     = d_rsp.rvalid;
    assign d_rdata      = d_rsp.rdata;
    assign d_bvalid     = d_rsp.bvalid;

    native_ram #(
        .ADDR_W    (16),
        .DATA_WIDTH(32),
        .READ_ONLY (0),
        .INIT_FILE ("")
    ) u_dmem (
        .clk_i    (clk_i),
        .rstn_i   (rstn_i),
        .mem_req_i(d_req),
        .mem_rsp_o(d_rsp)
    );

    // -----------------------------------------------------------------
    // I-mem (read-only). Preload two known words so reads can be checked.
    // -----------------------------------------------------------------
    mem_req_t i_req;
    mem_rsp_t i_rsp;

    assign i_req.wvalid = i_wvalid;
    assign i_req.we     = i_we;
    assign i_req.addr   = i_addr;
    assign i_req.wdata  = i_wdata;
    assign i_req.wstrb  = i_wstrb;
    assign i_req.rready = i_rready;

    assign i_wready     = i_rsp.wready;
    assign i_rvalid     = i_rsp.rvalid;
    assign i_rdata      = i_rsp.rdata;
    assign i_bvalid     = i_rsp.bvalid;

    native_ram #(
        .ADDR_W    (16),
        .DATA_WIDTH(32),
        .READ_ONLY (1),
        .INIT_FILE ("")
    ) u_imem (
        .clk_i    (clk_i),
        .rstn_i   (rstn_i),
        .mem_req_i(i_req),
        .mem_rsp_o(i_rsp)
    );

    // Preload two words for read checks (sim only).
    initial begin
        u_imem.mem[0] = 32'hCAFE_BABE;
        u_imem.mem[1] = 32'hDEAD_BEEF;
    end

endmodule

`resetall
