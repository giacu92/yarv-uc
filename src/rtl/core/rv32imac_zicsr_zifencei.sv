`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
 * CPU top: instantiates pipeline stages AND the on-die AXI4-Lite
 * bridge that turns the native mem_req_t / mem_rsp_t into AR/AW/W +
 * R/B at the single master port.
 *
 * External view of the CPU is bus-centric — ONE AXI4-Lite master:
 *
 *   - `bus_axi` : AXI4-Lite master carrying ALL memory traffic —
 *                 instructions AND data (von Neumann: fetch and the
 *                 LSU share this one port through a mem_arbiter, LSU
 *                 priority) AND memory-mapped peripheral accesses
 *                 (UART, GPIO, ...). The LSU targets peripherals by
 *                 address; a top-level 1->2 crossbar (in the board /
 *                 sim top) splits this port into a mem region and a
 *                 peri region by address (see rv32_pkg::PERI_ADDR_BIT).
 *
 * Internally:
 *
 *   fetch_stage --┐
 *                 ├─ mem_arbiter ─► axi4_lite_master_bridge ─► bus_axi
 *   LSU (execute)─┘   (LSU priority)      (single outstanding)
 *
 * The bridge is a single-outstanding FSM that turns a native
 * req.wvalid / rsp.wready (launch) + rsp.rvalid / req.rready (read)
 * handshake into an AXI4-Lite transaction, so the rest of the system
 * sees the CPU as a plain AXI4-Lite master. Address-decode / peripheral
 * routing is the board top's job (the crossbar), not the CPU's: the CPU
 * is agnostic to whether an address hits RAM or a peripheral.
 *
 * No debug signals cross the CPU boundary: the per-stage pc / instr /
 * valid / writeback taps live on the stage blocks and on internal nets
 * here (consumed by the next stage or left unconnected). The simulation
 * wrapper observes them by probing the Verilator hierarchy directly
 * (--public-flat), not through CPU output ports.
 *
 * Naming: ports use *_i/_o; internal signals have no prefix (they are
 * neither inputs nor outputs).
 */

module rv32imac_zicsr_zifencei (
    input wire clk_i,
    input wire rstn_i,

    input wire [XLEN-1:0] boot_addr_i,  // Reset vector boot address

    // AXI4-Lite master: unified memory + peripheral bus (von Neumann
    // fetch+data, plus MMIO). A top-level crossbar splits mem/peri.
    axi4_lite_if.master bus_axi,

    // Debug taps
    output wire dbg_stall_o  // decode or execute stage stall
);

    // -----------------------------------------------------------------
    // Fetch stage
    //
    // stall_i is driven by decode's back-pressure (propagated from the
    // execute stage's div stall). branch_* come from the execute stage's
    // branch-resolve path (redirect + in-flight flush).
    // -----------------------------------------------------------------
    // Von Neumann memory: fetch and the LSU share one imem port through
    // a mem_arbiter (LSU priority). fe_* = fetch native side, lsu_* =
    // LSU native side, imem_* = arbiter slave side -> the imem bridge.
    mem_req_t            fe_req;
    mem_rsp_t            fe_rsp;
    mem_req_t            lsu_req;
    mem_rsp_t            lsu_rsp;
    mem_req_t            imem_req;
    mem_rsp_t            imem_rsp;

    // F/D pipeline-register taps, consumed by the decode stage below.
    wire      [XLEN-1:0] fe_pc_w;
    wire      [XLEN-1:0] fe_instr_w;
    wire                 fe_valid_w;

    // Decode -> fetch back-pressure (propagates execute's stall).
    wire                 dec_stall;
    // Execute -> fetch redirect.
    wire                 ex_branch_valid;
    wire      [XLEN-1:0] ex_branch_addr;

    fetch_stage fetch_stage_i (
        .clk_i         (clk_i),
        .rstn_i        (rstn_i),
        .boot_addr_i   (boot_addr_i),
        .stall_i       (dec_stall),
        .branch_valid_i(ex_branch_valid),
        .branch_addr_i (ex_branch_addr),
        .imem_req_o    (fe_req),
        .imem_rsp_i    (fe_rsp),
        .fe_instr_o    (fe_instr_w),
        .fe_pc_o       (fe_pc_w),
        .fe_valid_o    (fe_valid_w)
    );

    // -----------------------------------------------------------------
    // Memory arbiter: fetch + LSU -> single imem bridge. LSU has fixed
    // priority (a data access stalls fetch ~2 cycles); fetch and the LSU
    // cannot both hold the bridge (single outstanding).
    // -----------------------------------------------------------------
    mem_arbiter u_mem_arb (
        .clk_i      (clk_i),
        .rstn_i     (rstn_i),
        .fetch_req_i(fe_req),
        .fetch_rsp_o(fe_rsp),
        .lsu_req_i  (lsu_req),
        .lsu_rsp_o  (lsu_rsp),
        .slv_req_o  (imem_req),
        .slv_rsp_i  (imem_rsp)
    );

    // -----------------------------------------------------------------
    // On-die AXI4-Lite bridge (single master port)
    //
    // Translates the native mem_req_t / mem_rsp_t into AXI4-Lite
    // AR/AW/W + R/B. The pipeline only ever deals with one-cycle
    // request/response; the bridge owns the bus protocol. Both memory
    // and peripheral addresses flow through this one bridge — the
    // board top's crossbar splits them by address downstream.
    // -----------------------------------------------------------------
    axi4_lite_master_bridge u_bus_bridge (
        .clk_i (clk_i),
        .rstn_i(rstn_i),
        .req_i (imem_req),
        .rsp_o (imem_rsp),
        .axi   (bus_axi)
    );

    // -----------------------------------------------------------------
    // Register file + decode stage + execute stage
    //
    // Decode reads rs1/rs2 from the reg file asynchronously (addresses
    // come from decode, data returns the same cycle and is latched into
    // the D/E register). The D/E control word (de_w) feeds execute, which
    // drives the reg-file write port (ALU / PC4 writeback), the fetch
    // redirect, and decode's stall (div) / flush (branch).
    // -----------------------------------------------------------------
    wire [     4:0] rs1_addr;
    wire [     4:0] rs2_addr;
    wire [XLEN-1:0] rs1_data;
    wire [XLEN-1:0] rs2_data;

    wire [     4:0] wb_addr;
    wire [XLEN-1:0] wb_data;
    wire            wb_en;

    reg_file u_regfile (
        .clk_i     (clk_i),
        .rstn_i    (rstn_i),
        .rs1_addr_i(rs1_addr),
        .rs2_addr_i(rs2_addr),
        .rs1_data_o(rs1_data),
        .rs2_data_o(rs2_data),
        .wr_addr_i (wb_addr),
        .wr_data_i (wb_data),
        .wr_en_i   (wb_en)
    );

    de_t            de_w;

    // de_* D/E taps (decode stage outputs). Debug only — left
    // unconnected here; the sim probes them via the Verilator hierarchy.
    wire [XLEN-1:0] de_pc_w;
    wire [XLEN-1:0] de_instr_w;
    wire            de_valid_w;

    // Execute -> decode back-pressure / flush.
    wire            ex_stall;
    wire            ex_flush;

    decode_stage u_decode (
        .clk_i       (clk_i),
        .rstn_i      (rstn_i),
        .fe_instr_i  (fe_instr_w),
        .fe_pc_i     (fe_pc_w),
        .fe_valid_i  (fe_valid_w),
        .rs1_addr_o  (rs1_addr),
        .rs2_addr_o  (rs2_addr),
        .rs1_data_i  (rs1_data),
        .rs2_data_i  (rs2_data),
        .stall_i     (ex_stall),
        .flush_i     (ex_flush),
        .ex_wb_en_i  (wb_en),
        .ex_wb_addr_i(wb_addr),
        .stall_o     (dec_stall),
        .de_o        (de_w),
        .de_pc_o     (de_pc_w),
        .de_instr_o  (de_instr_w),
        .de_valid_o  (de_valid_w)
    );

    // ex_* E/M taps (retired op pc / instr / valid). Debug only — left
    // unconnected here; the sim probes them via the Verilator hierarchy.
    wire [XLEN-1:0] ex_pc_w;
    wire [XLEN-1:0] ex_instr_w;
    wire            ex_valid_w;

    execute_stage u_execute (
        .clk_i         (clk_i),
        .rstn_i        (rstn_i),
        .de_i          (de_w),
        .stall_i       (1'b0),             // no downstream stage yet
        .stall_o       (ex_stall),
        .flush_o       (ex_flush),
        .wb_addr_o     (wb_addr),
        .wb_data_o     (wb_data),
        .wb_en_o       (wb_en),
        .branch_valid_o(ex_branch_valid),
        .branch_addr_o (ex_branch_addr),
        .mem_req_o     (lsu_req),
        .mem_rsp_i     (lsu_rsp),
        .ex_pc_o       (ex_pc_w),
        .ex_instr_o    (ex_instr_w),
        .ex_valid_o    (ex_valid_w)
    );

    // Aggregate stall tap for the board / sim (functional only).
    assign dbg_stall_o = dec_stall | ex_stall;

endmodule
