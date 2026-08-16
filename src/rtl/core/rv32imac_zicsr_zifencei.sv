`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
 * CPU top: instantiates pipeline stages AND the on-die AXI4-Lite
 * bridges that turn the native mem_req_t / mem_rsp_t into AR/AW/W +
 * R/B at each master port.
 *
 * External view of the CPU is bus-centric — two AXI4-Lite masters:
 *
 *   - `imem_axi` : AXI4-Lite master toward instruction memory
 *   - `peri_axi` : AXI4-Lite master toward peripherals (UART, GPIO, ...).
 *                  UNUSED today: the LSU is not implemented yet, so no
 *                  transaction is ever launched on this port. It is
 *                  exposed at the boundary so the board top can route
 *                  it to the peripheral bus without re-touching the
 *                  CPU when the LSU lands.
 *
 * Internally:
 *
 *   fetch_stage --[imem native]--> axi4_lite_master_bridge --[AXI4-Lite]--> imem_axi
 *   (LSU TODO)  --[peri native]--> axi4_lite_master_bridge --[AXI4-Lite]--> peri_axi
 *
 * Each bridge is a single-outstanding FSM that turns a native
 * req.wvalid / rsp.wready (launch) + rsp.rvalid / req.rready (read)
 * handshake into an AXI4-Lite transaction, so the rest of the system
 * sees the CPU as a plain AXI4-Lite master.
 *
 * Each pipeline stage exposes the PC it is treating, the instruction
 * word, and a valid as outputs (prefixed by its stage sigil: fe = fetch,
 * de = decode, ex = execute, ...). Further debug signals are added on
 * demand. The board top takes fe_pc_dbg_o[3:0] to the LEDs; the other
 * taps are left unconnected there (swept by synthesis) and consumed by
 * the simulation wrapper.
 *
 * Naming: ports use *_i/_o; internal signals have no prefix (they are
 * neither inputs nor outputs).
 */

module rv32imac_zicsr_zifencei (
    input wire clk_i,
    input wire rstn_i,

    input wire [XLEN-1:0] boot_addr_i,  // Reset vector boot address

    // AXI4-Lite master #0: instruction memory
    axi4_lite_if.master imem_axi,

    // AXI4-Lite master #1: peripherals (UART, GPIO, ...). Unused for now.
    axi4_lite_if.master peri_axi,

    // fe_* debug taps (fetch stage / F/D pipeline register): the PC it
    // is treating, the instruction word, and a valid. The low 4 bits of
    // fe_pc_dbg_o go to the board LEDs; the rest are left unconnected at
    // the board top (swept by synthesis) and used by the sim wrapper.
    output wire [XLEN-1:0] fe_pc_dbg_o,     // F/D instruction PC (exact)
    output wire [XLEN-1:0] fe_instr_dbg_o,  // F/D instruction word
    output wire            fe_valid_dbg_o,  // F/D valid (held level)

    // de_* debug taps (decode stage / D/E pipeline register): pc / instr
    // / valid. Left unconnected at the board top (swept by synthesis) and
    // consumed by the sim wrapper. There is no execute stage yet, so the
    // full D/E control (de_o) rides to observation only inside the CPU.
    output wire [XLEN-1:0] de_pc_dbg_o,     // D/E instruction PC
    output wire [XLEN-1:0] de_instr_dbg_o,  // 32-bit word decode treated
    output wire            de_valid_dbg_o   // D/E valid
);

    // -----------------------------------------------------------------
    // Fetch stage
    //
    // stall_i is driven by decode's back-pressure (currently INERT —
    // see decode_stage header). branch_* stay tied off until execute /
    // a hazard unit exists.
    // -----------------------------------------------------------------
    mem_req_t            imem_req;
    mem_rsp_t            imem_rsp;

    // F/D pipeline-register taps, consumed by the decode stage below
    // (and mirrored to the debug ports above).
    wire      [XLEN-1:0] fe_pc_w;
    wire      [XLEN-1:0] fe_instr_w;
    wire                 fe_valid_w;

    // Decode -> fetch back-pressure.
    wire                 dec_stall;

    fetch_stage fetch_stage_i (
        .clk_i         (clk_i),
        .rstn_i        (rstn_i),
        .boot_addr_i   (boot_addr_i),
        .stall_i       (dec_stall),
        .branch_valid_i(1'b0),
        .branch_addr_i (32'h0000_0000),
        .imem_req_o    (imem_req),
        .imem_rsp_i    (imem_rsp),
        .fe_instr_o    (fe_instr_w),
        .fe_pc_o       (fe_pc_w),
        .fe_valid_o    (fe_valid_w)
    );

    // -----------------------------------------------------------------
    // On-die AXI4-Lite bridges (one per master port)
    //
    // Translate the native mem_req_t / mem_rsp_t into AXI4-Lite
    // AR/AW/W + R/B. The pipeline only ever deals with one-cycle
    // request/response; the bridge owns the bus protocol.
    // -----------------------------------------------------------------
    axi4_lite_master_bridge u_imem_bridge (
        .clk_i (clk_i),
        .rstn_i(rstn_i),
        .req_i (imem_req),
        .rsp_o (imem_rsp),
        .axi   (imem_axi)
    );

    mem_req_t peri_req;
    mem_rsp_t peri_rsp;

    // LSU not implemented yet — tie the request side inert (wvalid=0)
    // so the bridge never launches a transaction. peri_rsp is read
    // into a dummy net so the synthesiser doesn't warn about a
    // dangling input.
    assign peri_req.wvalid = 1'b0;
    assign peri_req.we     = 1'b0;
    assign peri_req.addr   = '0;
    assign peri_req.wdata  = '0;
    assign peri_req.wstrb  = '0;
    assign peri_req.rready = 1'b1;  // never launched, but drive it (no X)
    wire unused_peri_rsp = peri_rsp.wready | peri_rsp.rvalid | peri_rsp.rdata[0];

    axi4_lite_master_bridge u_peri_bridge (
        .clk_i (clk_i),
        .rstn_i(rstn_i),
        .req_i (peri_req),
        .rsp_o (peri_rsp),
        .axi   (peri_axi)
    );

    // -----------------------------------------------------------------
    // Register file + decode stage
    //
    // Decode reads rs1/rs2 from the reg file asynchronously (addresses
    // come from decode, data returns the same cycle and is latched into
    // the D/E register). The write port has no producer (no writeback
    // stage) so it is tied off; reads therefore return 0 until a
    // writeback stage exists.
    // -----------------------------------------------------------------
    wire [     4:0] rs1_addr;
    wire [     4:0] rs2_addr;
    wire [XLEN-1:0] rs1_data;
    wire [XLEN-1:0] rs2_data;

    reg_file u_regfile (
        .clk_i     (clk_i),
        .rstn_i    (rstn_i),
        .rs1_addr_i(rs1_addr),
        .rs2_addr_i(rs2_addr),
        .rs1_data_o(rs1_data),
        .rs2_data_o(rs2_data),
        .wr_addr_i (5'd0),      // no writeback yet
        .wr_data_i ('0),
        .wr_en_i   (1'b0)
    );

    de_t de_w;

    decode_stage u_decode (
        .clk_i     (clk_i),
        .rstn_i    (rstn_i),
        .fe_instr_i(fe_instr_w),
        .fe_pc_i   (fe_pc_w),
        .fe_valid_i(fe_valid_w),
        .rs1_addr_o(rs1_addr),
        .rs2_addr_o(rs2_addr),
        .rs1_data_i(rs1_data),
        .rs2_data_i(rs2_data),
        .stall_i   (1'b0),        // no hazard unit yet
        .flush_i   (1'b0),
        .stall_o   (dec_stall),
        .de_o      (de_w)
    );

    // -----------------------------------------------------------------
    // Debug taps (per-stage pc / instr / valid only; add more on demand)
    // -----------------------------------------------------------------
    // fe_* (fetch / F/D register).
    assign fe_pc_dbg_o    = fe_pc_w;  // full PC; board takes [3:0]
    assign fe_instr_dbg_o = fe_instr_w;
    assign fe_valid_dbg_o = fe_valid_w;

    // de_* (decode / D/E register).
    assign de_pc_dbg_o    = de_w.pc;
    assign de_instr_dbg_o = de_w.instr;
    assign de_valid_dbg_o = de_w.valid;

endmodule
