`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
 * CPU top: instantiates pipeline stages AND the on-die AXI4-Lite
 * bridge that turns the native mem_req_t / mem_rsp_t into AR/AW/W +
 * R/B at the single master port.
 *
 * External view of the CPU (Harvard build, default — VON_NEUMANN
 * undefined):
 *
 *   - `axi_peri` : AXI4-Lite master carrying PERIPHERAL traffic only
 *                 (UART, GPIO, ...). The LSU steers addr[PERI_ADDR_BIT]=1
 *                 accesses here through an internal peri bridge.
 *   - `imem_req_o`/`imem_rsp_i` : native fetch port (read-only I-mem).
 *   - `dmem_req_o`/`dmem_rsp_i` : native LSU data port (byte-strobed D-mem).
 *
 * Internally (Harvard):
 *
 *   fetch_stage  ──► imem_req_o/imem_rsp_i        (dedicated I-mem, no
 *                                                   contention with the LSU)
 *   LSU (execute)──► addr[PERI_ADDR_BIT] steer:
 *                     0 → dmem_req_o/dmem_rsp_i          (native D-mem)
 *                     1 → axi4_lite_master_bridge → axi_peri (peri, AXI)
 *
 * The LSU does the mem/peri decode itself (it knows PERI_ADDR_BIT), so the
 * board top is pure point-to-point wires — no crossbar. The bridge is a
 * single-outstanding FSM that turns a native req.wvalid/rsp.wready (launch)
 * + rsp.rvalid/req.rready (read) handshake into an AXI4-Lite transaction.
 *
 * The `VON_NEUMANN` build is the legacy von-Neumann fallback: one
 * unified `bus_axi` master, fetch+LSU share a mem_arbiter (LSU priority) →
 * the bridge, and a top-level crossbar splits mem/peri. The CPU is agnostic
 * to mem/peri only in that build.
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

    input  wire [XLEN-1:0] boot_addr_i,  // Reset vector boot address
    output wire            dbg_stall_o,  // decode or execute stage stall

`ifdef VON_NEUMANN
    // AXI4-Lite master: unified memory + peripheral bus (von Neumann
    // fetch+data, plus MMIO). A top-level crossbar splits mem/peri.
    axi4_lite_if.master bus_axi

`else
    // Harvard: AXI4-Lite master for peripherals only. Fetch and LSU data
    // RAM use the native imem_/dmem_ ports below (no AXI for memory).
    axi4_lite_if.master axi_peri,

    // Native I-mem (fetch, read-only).
    output mem_req_t imem_req_o,
    input  mem_rsp_t imem_rsp_i,

    // Native D-mem (LSU data RAM, byte-strobed).
    output mem_req_t dmem_req_o,
    input  mem_rsp_t dmem_rsp_i
`endif
    ,

    // Machine software-interrupt pending bit from the MSIP MMIO slave
    // (on axi_peri at the board top). Drives mip.MSIP. Common to both
    // builds; the von-Neumann board top ties it low (no MSIP slave there).
    input wire msip_i
);

    // ===================================================================
    // Signal declarations
    // ===================================================================

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
    // -------------------------------------------------------------
    mem_req_t fe_req;
    mem_rsp_t fe_rsp;
`ifdef VON_NEUMANN
    mem_req_t lsu_req;
    mem_rsp_t lsu_rsp;
    mem_req_t imem_req;
    mem_rsp_t imem_rsp;
`else
    mem_req_t peri_req;
    mem_rsp_t peri_rsp;
`endif

    // F/D pipeline-register taps, consumed by the decode stage below.
    wire [XLEN-1:0] fe_pc;
    wire [XLEN-1:0] fe_instr;
    wire            fe_valid;

    // Decode -> fetch back-pressure (propagates execute's stall).
    wire            dec_stall;
    // Execute -> fetch redirect.
    wire            ex_branch_valid;
    wire [XLEN-1:0] ex_branch_addr;

    // -------------------------------------------------------------
    // Register file + decode/execute
    //
    // Decode reads rs1/rs2 from the reg file asynchronously (addresses
    // come from decode, data returns the same cycle and is latched into
    // the D/E register). The D/E control word (de_bus) feeds execute, which
    // drives the reg-file write port (ALU / PC4 writeback), the fetch
    // redirect, and decode's stall (div) / flush (branch).
    // -------------------------------------------------------------
    wire [     4:0] rs1_addr;
    wire [     4:0] rs2_addr;
    wire [XLEN-1:0] rs1_data;
    wire [XLEN-1:0] rs2_data;

    wire [     4:0] wb_addr;
    wire [XLEN-1:0] wb_data;
    wire            wb_en;

    de_t            de_bus;

    // de_* D/E taps (decode stage outputs). Debug only — left
    // unconnected here; the sim probes them via the Verilator hierarchy.
    wire [XLEN-1:0] de_pc;
    wire [XLEN-1:0] de_instr;
    wire            de_valid;

    // Execute -> decode back-pressure / flush.
    wire            ex_stall;
    wire            ex_flush;

    // CSR
    wire [XLEN-1:0] csr_wdata;
    wire            csr_we;
    wire [XLEN-1:0] csr_rdata;

    // CSR taps (trap unit reads mtvec / mepc / mstatus / mip / mie).
    wire [XLEN-1:0] csr_mtvec, csr_mepc, csr_mstatus, csr_mip, csr_mie;

    // Trap-write bundle (trap unit -> CSR file) + triggers/payload
    // (execute "exception logic" -> trap unit) + the pending interrupt and
    // resolved redirect fed back to execute.
    wire we_mepc, we_mcause, we_mtval, we_mstatus;
    wire [XLEN-1:0] d_mepc, d_mcause, d_mtval, d_mstatus;
    wire sync_trap_req, mret_req, take_interrupt;
    wire [XLEN-1:0] trap_cause, trap_tval, trap_pc;
    wire            int_pending;
    wire [XLEN-1:0] trap_redirect_addr;

    // ex_* E/M taps (retired op pc / instr / valid). Debug only — left
    // unconnected here; the sim probes them via the Verilator hierarchy.
    wire [XLEN-1:0] ex_pc;
    wire [XLEN-1:0] ex_instr;
    wire            ex_valid;

    // ===================================================================
    // Module instantiations
    // ===================================================================

    // -------------------------------------------------------------
    // Fetch stage
    //
    // stall_i is driven by decode's back-pressure (propagated from the
    // execute stage's div stall). branch_* come from the execute stage's
    // branch-resolve path (redirect + in-flight flush).
    // -------------------------------------------------------------
    fetch_stage fetch_stage_i (
        .clk_i         (clk_i),
        .rstn_i        (rstn_i),
        .boot_addr_i   (boot_addr_i),
        .stall_i       (dec_stall),
        .branch_valid_i(ex_branch_valid),
        .branch_addr_i (ex_branch_addr),
        .imem_req_o    (fe_req),
        .imem_rsp_i    (fe_rsp),
        .fe_instr_o    (fe_instr),
        .fe_pc_o       (fe_pc),
        .fe_valid_o    (fe_valid)
    );

`ifdef VON_NEUMANN
    // -------------------------------------------------------------
    // Memory arbiter: fetch + LSU -> single imem bridge. LSU has fixed
    // priority (a data access stalls fetch ~2 cycles); fetch and the LSU
    // cannot both hold the bridge (single outstanding).
    // -------------------------------------------------------------
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
`endif

    // -------------------------------------------------------------
    // On-die AXI4-Lite bridge (single master port)
    //
    // Translates the native mem_req_t / mem_rsp_t into AXI4-Lite
    // AR/AW/W + R/B. The pipeline only ever deals with one-cycle
    // request/response; the bridge owns the bus protocol. Both memory
    // and peripheral addresses flow through this one bridge — the
    // board top's crossbar splits them by address downstream.
    // -------------------------------------------------------------
    axi4_lite_master_bridge u_bus_bridge (
        .clk_i (clk_i),
        .rstn_i(rstn_i),
`ifdef VON_NEUMANN
        .req_i (imem_req),
        .rsp_o (imem_rsp),
`else
        .req_i (peri_req),
        .rsp_o (peri_rsp),
`endif
`ifdef VON_NEUMANN
        .axi   (bus_axi)
`else
        .axi   (axi_peri)
`endif
    );

    // GPR Regfile
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

    // CSR file: decode drives the address (de_bus.csr_addr = the op in
    // execute); the async read returns the OLD value to execute, the sync
    // write commits the RMW result from execute (csr_wdata / csr_we).
    // Both ports address the op currently in execute (single CSR op at a
    // time).
    csr_regfile u_csr_regfile (
        .clk_i         (clk_i),
        .rstn_i        (rstn_i),
        .csr_addr_i    (de_bus.csr_addr),
        .csr_data_o    (csr_rdata),
        .csr_wren_i    (csr_we),
        .csr_data_i    (csr_wdata),
        .we_mepc_i     (we_mepc),
        .d_mepc_i      (d_mepc),
        .we_mcause_i   (we_mcause),
        .d_mcause_i    (d_mcause),
        .we_mtval_i    (we_mtval),
        .d_mtval_i     (d_mtval),
        .we_mstatus_i  (we_mstatus),
        .d_mstatus_i   (d_mstatus),
        .msip_i        (msip_i),
        .mtvec_o       (csr_mtvec),
        .mepc_o        (csr_mepc),
        .mstatus_o     (csr_mstatus),
        .mip_o         (csr_mip),
        .mie_o         (csr_mie),
        .instr_retire_i(ex_valid)
    );

    // Trap unit (combinational peer of the execute stage): consumes the
    // triggers + cause/tval/pc the execute "exception logic" produces,
    // drives the CSR trap-write bundle (mepc / mcause / mtval / mstatus) and
    // the fetch redirect, and reports the pending+enabled MS interrupt back
    // to execute. int_pending depends only on the CSR taps (no loop through
    // the triggers).
    trap_unit u_trap (
        .mtvec_i         (csr_mtvec),
        .mepc_i          (csr_mepc),
        .mstatus_i       (csr_mstatus),
        .mip_i           (csr_mip),
        .mie_i           (csr_mie),
        .take_trap_i     (sync_trap_req),
        .take_interrupt_i(take_interrupt),
        .mret_i          (mret_req),
        .cause_i         (trap_cause),
        .tval_i          (trap_tval),
        .pc_i            (trap_pc),
        .redirect_valid_o(),
        .redirect_addr_o (trap_redirect_addr),
        .csr_we_mepc_o   (we_mepc),
        .csr_d_mepc_o    (d_mepc),
        .csr_we_mcause_o (we_mcause),
        .csr_d_mcause_o  (d_mcause),
        .csr_we_mtval_o  (we_mtval),
        .csr_d_mtval_o   (d_mtval),
        .csr_we_mstatus_o(we_mstatus),
        .csr_d_mstatus_o (d_mstatus),
        .int_pending_o   (int_pending)
    );

    decode_stage u_decode (
        .clk_i       (clk_i),
        .rstn_i      (rstn_i),
        .fe_instr_i  (fe_instr),
        .fe_pc_i     (fe_pc),
        .fe_valid_i  (fe_valid),
        .rs1_addr_o  (rs1_addr),
        .rs2_addr_o  (rs2_addr),
        .rs1_data_i  (rs1_data),
        .rs2_data_i  (rs2_data),
        .stall_i     (ex_stall),
        .flush_i     (ex_flush),
        .ex_wb_en_i  (wb_en),
        .ex_wb_addr_i(wb_addr),
        .ex_wb_data_i(wb_data),
        .stall_o     (dec_stall),
        .de_o        (de_bus),
        .de_pc_o     (de_pc),
        .de_instr_o  (de_instr),
        .de_valid_o  (de_valid)
    );

    execute_stage u_execute (
        .clk_i               (clk_i),
        .rstn_i              (rstn_i),
        .de_i                (de_bus),
        .csr_rdata_i         (csr_rdata),           // CSR read value
        .csr_wdata_o         (csr_wdata),           // CSR write value (RMW result)
        .csr_wren_o          (csr_we),              // CSR write enable (execute-qualified)
        .stall_i             (1'b0),                // no downstream stage yet
        .stall_o             (ex_stall),
        .flush_o             (ex_flush),
        .wb_addr_o           (wb_addr),
        .wb_data_o           (wb_data),
        .wb_en_o             (wb_en),
        .branch_valid_o      (ex_branch_valid),
        .branch_addr_o       (ex_branch_addr),
`ifdef VON_NEUMANN
        .mem_req_o           (lsu_req),
        .mem_rsp_i           (lsu_rsp),
`else
        .mem_req_o           (dmem_req_o),
        .mem_rsp_i           (dmem_rsp_i),
        .peri_req_o          (peri_req),
        .peri_rsp_i          (peri_rsp),
`endif
        // Trap machinery: execute "exception logic" emits the triggers +
        // cause/tval/pc, imports the pending interrupt + resolved redirect
        // (from the trap unit). int_pending is combinational off the CSR
        // taps (no loop through the triggers); redirect_addr selects trap /
        // mret / interrupt target over the normal branch.
        .int_pending_i       (int_pending),
        .trap_redirect_addr_i(trap_redirect_addr),
        .sync_trap_req_o     (sync_trap_req),
        .mret_req_o          (mret_req),
        .take_interrupt_o    (take_interrupt),
        .trap_cause_o        (trap_cause),
        .trap_tval_o         (trap_tval),
        .trap_pc_o           (trap_pc),
        .ex_pc_o             (ex_pc),
        .ex_instr_o          (ex_instr),
        .ex_valid_o          (ex_valid)
    );

    // ===================================================================
    // Assignments
    // ===================================================================

    // Aggregate stall tap for the board / sim (functional only).
    assign dbg_stall_o = dec_stall | ex_stall;

`ifndef VON_NEUMANN
    assign imem_req_o = fe_req;
    assign fe_rsp     = imem_rsp_i;
`endif

endmodule

`resetall
