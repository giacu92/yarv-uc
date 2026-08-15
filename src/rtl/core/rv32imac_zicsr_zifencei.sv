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
 * The fd_pc_o low nibble is brought out as a debug tap.
 */

module rv32imac_zicsr_zifencei (
    input  wire clk_i,
    input  wire rstn_i,

    input  wire [XLEN-1:0] boot_addr_i,    // Reset vector boot address

    // AXI4-Lite master #0: instruction memory
    axi4_lite_if.master imem_axi,

    // AXI4-Lite master #1: peripherals (UART, GPIO, ...). Unused for now.
    axi4_lite_if.master peri_axi,

    // Debug: low 4 bits of the current F/D PC, for LEDs / sim hooks.
    output wire [3:0]      fd_pc_dbg_o
);

    // -----------------------------------------------------------------
    // Fetch stage
    //
    // Forward-compat inputs (stall_i / branch_*) are tied off; the
    // hazard unit / execute stage will drive them once they exist.
    // -----------------------------------------------------------------
    mem_req_t imem_req;
    mem_rsp_t imem_rsp;
    wire [XLEN-1:0] cpu_next_pc;

    fetch_stage fetch_stage_i (
        .clk_i              (clk_i),
        .rstn_i             (rstn_i),
        .boot_addr_i        (boot_addr_i),
        .stall_i            (1'b0),
        .branch_valid_i     (1'b0),
        .branch_addr_i      (32'h0000_0000),
        .imem_req_o         (imem_req),
        .imem_rsp_i         (imem_rsp),
        .next_pc_o          (cpu_next_pc),
        .fd_instr_o         (),
        .fd_pc_o            (),
        .fd_valid_o         (),
        .fd_is_compressed_o ()
    );

    // -----------------------------------------------------------------
    // On-die AXI4-Lite bridges (one per master port)
    //
    // Translate the native mem_req_t / mem_rsp_t into AXI4-Lite
    // AR/AW/W + R/B. The pipeline only ever deals with one-cycle
    // request/response; the bridge owns the bus protocol.
    // -----------------------------------------------------------------
    axi4_lite_master_bridge u_imem_bridge (
        .clk_i  (clk_i),
        .rstn_i (rstn_i),
        .req_i  (imem_req),
        .rsp_o  (imem_rsp),
        .axi    (imem_axi)
    );

    mem_req_t peri_req;
    mem_rsp_t peri_rsp;

    // LSU not implemented yet — tie the request side inert (wvalid=0)
    // so the bridge never launches a transaction. peri_rsp is read
    // into a dummy net so the synthesiser doesn't warn about a
    // dangling input.
    assign peri_req.wvalid = 1'b0;
    assign peri_req.we    = 1'b0;
    assign peri_req.addr  = '0;
    assign peri_req.wdata = '0;
    assign peri_req.wstrb = '0;
    assign peri_req.rready = 1'b1;   // never launched, but drive it (no X)
    wire _unused_peri_rsp = peri_rsp.wready | peri_rsp.rvalid | peri_rsp.rdata[0];

    axi4_lite_master_bridge u_peri_bridge (
        .clk_i  (clk_i),
        .rstn_i (rstn_i),
        .req_i  (peri_req),
        .rsp_o  (peri_rsp),
        .axi    (peri_axi)
    );

    // -----------------------------------------------------------------
    // Debug tap
    // -----------------------------------------------------------------
    assign fd_pc_dbg_o = fetch_stage_i.fd_pc_o[3:0];

endmodule
