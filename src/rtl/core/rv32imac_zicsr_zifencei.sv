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
 * Debug-tap convention: every pipeline stage exposes the PC it is
 * treating, the instruction word, a valid, and other useful debug as
 * outputs prefixed by a stage sigil (fe = fetch, de = decode, ex =
 * execute, ...). The F/D register is fetch's output (fe_* taps); the
 * D/E register is decode's output (de_* taps, including de_instr). The
 * board top takes fe_pc_dbg_o[3:0] to the LEDs; the full-width taps
 * are left unconnected there (swept by synthesis) and are consumed by
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

    // fe_* debug taps (fetch stage / F/D pipeline register). Each stage
    // exposes pc / instr / valid + debug prefixed by its sigil. The low
    // 4 bits of fe_pc_dbg_o go to the board LEDs; the full-width taps
    // are left unconnected at the board top (swept by synthesis) and
    // used by the simulation wrapper to observe what fetch delivers.
    output wire [XLEN-1:0] fe_pc_dbg_o,             // F/D instruction PC (exact)
    output wire [XLEN-1:0] fe_instr_dbg_o,          // F/D instruction word
    output wire            fe_valid_dbg_o,          // F/D valid (held level)
    output wire            fe_is_compressed_dbg_o,  // rdata[1:0] != 2'b11
    output wire [XLEN-1:0] fe_next_pc_dbg_o,        // next fetch address

    // de_* debug taps (decode stage / D/E pipeline register). Exposed as
    // plain logic (not enum-typed) so the Verilator C++ harness can read
    // them as flat scalars and Gowin synthesis has no enum-in-port edge
    // cases. All left unconnected at the board top (swept by synthesis);
    // the sim wrapper consumes them. There is no execute stage yet, so
    // these ride to observation only.
    //   alu_op      : 18-value enum (see rv32_pkg::alu_op_t), 5 bits
    //   alu_src_a   : 0=RS1, 1=PC
    //   alu_src_b   : 0=IMM, 1=RS2, 2=PC4, 3=ZERO
    //   mem_size    : 0=B, 1=H, 2=W
    //   wb_src      : 0=ALU, 1=MEM, 2=PC4
    //   branch_type : see rv32_pkg::branch_t, 4 bits (0=NONE)
    output wire            de_valid_dbg_o,
    output wire [XLEN-1:0] de_pc_dbg_o,
    output wire [XLEN-1:0] de_instr_dbg_o,          // 32-bit word decode treated
    output wire            de_is_compressed_dbg_o,
    output wire [     4:0] de_rs1_addr_dbg_o,
    output wire [     4:0] de_rs2_addr_dbg_o,
    output wire [XLEN-1:0] de_rs1_data_dbg_o,
    output wire [XLEN-1:0] de_rs2_data_dbg_o,
    output wire [XLEN-1:0] de_imm_dbg_o,
    output wire [     4:0] de_rd_dbg_o,
    output wire            de_reg_write_dbg_o,
    output wire [     4:0] de_alu_op_dbg_o,
    output wire            de_alu_src_a_dbg_o,
    output wire [     1:0] de_alu_src_b_dbg_o,
    output wire            de_mem_read_dbg_o,
    output wire            de_mem_write_dbg_o,
    output wire [     1:0] de_mem_size_dbg_o,
    output wire            de_mem_unsigned_dbg_o,
    output wire [     1:0] de_wb_src_dbg_o,
    output wire [     3:0] de_branch_type_dbg_o,
    output wire            de_illegal_dbg_o
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
    wire      [XLEN-1:0] cpu_next_pc;

    // F/D pipeline-register taps, consumed by the decode stage below
    // (and mirrored to the debug ports above).
    wire      [XLEN-1:0] fe_pc_w;
    wire      [XLEN-1:0] fe_instr_w;
    wire                 fe_valid_w;
    wire                 fe_is_compressed_w;

    // Decode -> fetch back-pressure.
    wire                 dec_stall;

    fetch_stage fetch_stage_i (
        .clk_i             (clk_i),
        .rstn_i            (rstn_i),
        .boot_addr_i       (boot_addr_i),
        .stall_i           (dec_stall),
        .branch_valid_i    (1'b0),
        .branch_addr_i     (32'h0000_0000),
        .imem_req_o        (imem_req),
        .imem_rsp_i        (imem_rsp),
        .fe_next_pc_o      (cpu_next_pc),
        .fe_instr_o        (fe_instr_w),
        .fe_pc_o           (fe_pc_w),
        .fe_valid_o        (fe_valid_w),
        .fe_is_compressed_o(fe_is_compressed_w)
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
        .clk_i             (clk_i),
        .rstn_i            (rstn_i),
        .fe_instr_i        (fe_instr_w),
        .fe_pc_i           (fe_pc_w),
        .fe_valid_i        (fe_valid_w),
        .fe_is_compressed_i(fe_is_compressed_w),
        .rs1_addr_o        (rs1_addr),
        .rs2_addr_o        (rs2_addr),
        .rs1_data_i        (rs1_data),
        .rs2_data_i        (rs2_data),
        .stall_i           (1'b0),                // no hazard unit yet
        .flush_i           (1'b0),
        .stall_o           (dec_stall),
        .de_o              (de_w)
    );

    // -----------------------------------------------------------------
    // Debug taps
    // -----------------------------------------------------------------
    // fe_* taps (fetch / F/D register).
    assign fe_pc_dbg_o            = fe_pc_w;  // full PC; board takes [3:0]
    assign fe_instr_dbg_o         = fe_instr_w;
    assign fe_valid_dbg_o         = fe_valid_w;
    assign fe_is_compressed_dbg_o = fe_is_compressed_w;
    assign fe_next_pc_dbg_o       = cpu_next_pc;

    // de_* taps (decode / D/E register) — flat scalars for the harness.
    assign de_valid_dbg_o         = de_w.valid;
    assign de_pc_dbg_o            = de_w.pc;
    assign de_instr_dbg_o         = de_w.instr;
    assign de_is_compressed_dbg_o = de_w.is_compressed;
    assign de_rs1_addr_dbg_o      = de_w.rs1_addr;
    assign de_rs2_addr_dbg_o      = de_w.rs2_addr;
    assign de_rs1_data_dbg_o      = de_w.rs1_data;
    assign de_rs2_data_dbg_o      = de_w.rs2_data;
    assign de_imm_dbg_o           = de_w.imm;
    assign de_rd_dbg_o            = de_w.rd;
    assign de_reg_write_dbg_o     = de_w.reg_write;
    assign de_alu_op_dbg_o        = de_w.alu_op;
    assign de_alu_src_a_dbg_o     = de_w.alu_src_a;
    assign de_alu_src_b_dbg_o     = de_w.alu_src_b;
    assign de_mem_read_dbg_o      = de_w.mem_read;
    assign de_mem_write_dbg_o     = de_w.mem_write;
    assign de_mem_size_dbg_o      = de_w.mem_size;
    assign de_mem_unsigned_dbg_o  = de_w.mem_unsigned;
    assign de_wb_src_dbg_o        = de_w.wb_src;
    assign de_branch_type_dbg_o   = de_w.branch_type;
    assign de_illegal_dbg_o       = de_w.illegal;

endmodule
