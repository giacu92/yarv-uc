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
    // consumed by the sim wrapper. The full D/E control (de_o) is consumed
    // by the execute stage below.
    output wire [XLEN-1:0] de_pc_dbg_o,     // D/E instruction PC
    output wire [XLEN-1:0] de_instr_dbg_o,  // 32-bit word decode treated
    output wire            de_valid_dbg_o,  // D/E valid

    // ex_* debug taps (execute stage / E/M register): pc / instr / valid
    // of the retired operation. Left unconnected at the board top (swept
    // by synthesis) and consumed by the sim wrapper.
    output wire [XLEN-1:0] ex_pc_dbg_o,     // E/M instruction PC
    output wire [XLEN-1:0] ex_instr_dbg_o,  // 32-bit word executed
    output wire            ex_valid_dbg_o   // E/M valid (retired)
);

    // -----------------------------------------------------------------
    // Fetch stage
    //
    // stall_i is driven by decode's back-pressure (propagated from the
    // execute stage's div stall). branch_* come from the execute stage's
    // branch-resolve path (redirect + in-flight flush).
    // -----------------------------------------------------------------
    mem_req_t            imem_req;
    mem_rsp_t            imem_rsp;

    // F/D pipeline-register taps, consumed by the decode stage below
    // (and mirrored to the debug ports above).
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

    // The peri bridge is driven by the execute stage's native memory port
    // (the future LSU). Today execute gates wvalid to 0 (no LSU yet), so
    // the bridge stays idle; when the LSU lands, execute will launch
    // loads/stores (including Zilx indexed loads) on this bus with no
    // board-top changes.
    axi4_lite_master_bridge u_peri_bridge (
        .clk_i (clk_i),
        .rstn_i(rstn_i),
        .req_i (peri_req),
        .rsp_o (peri_rsp),
        .axi   (peri_axi)
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

    de_t de_w;

    // Execute -> decode back-pressure / flush.
    wire ex_stall;
    wire ex_flush;

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
        .stall_i   (ex_stall),
        .flush_i   (ex_flush),
        .stall_o   (dec_stall),
        .de_o      (de_w)
    );

    // ex_* E/M taps, mirrored to the debug ports below.
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
        .mem_req_o     (peri_req),
        .mem_rsp_i     (peri_rsp),
        .ex_pc_dbg_o   (ex_pc_w),
        .ex_instr_dbg_o(ex_instr_w),
        .ex_valid_dbg_o(ex_valid_w)
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

    // ex_* (execute / E/M register).
    assign ex_pc_dbg_o    = ex_pc_w;
    assign ex_instr_dbg_o = ex_instr_w;
    assign ex_valid_dbg_o = ex_valid_w;

endmodule
