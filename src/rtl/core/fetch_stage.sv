`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
 * Fetch stage of the pipeline.
 *
 * Owns the PC and exposes a small native interface for instruction
 * memory access. The stage does NOT drive any bus protocol — it just
 * publishes a request when it needs an instruction; the on-die
 * axi4_lite_master_bridge turns it into AXI4-Lite.
 *
 * Native interface (valid/ready su entrambi i lati, vedi rv32_pkg):
 *   - Request launch:  imem_req_o.wvalid && imem_rsp_i.wready.
 *   - Read response:   imem_rsp_i.rvalid && imem_req_o.rready.
 *
 * Single-outstanding overlap-prefetch:
 *   - At most one fetch in flight (busy_q). The bridge is single
 *     outstanding, so this matches it 1:1.
 *   - As soon as a fetch response is captured into the F/D register,
 *     the next fetch is launched while decode consumes the current
 *     instruction from the F/D register — fetch runs ahead of decode.
 *   - If decode is slower than memory and the next response arrives
 *     while the F/D register is still full, rready is held low: the
 *     bridge (and the AXI slave) hold rvalid/rdata until decode frees
 *     the F/D register. No skid buffer is needed (single outstanding
 *     => nothing queues behind the waiting response).
 *   - Steady-state throughput ~2 cycles/instruction (the bridge
 *     round-trip floor: 1 issue + 1 response cycle).
 *
 * Each pipeline stage exposes the PC it is treating, the instruction
 * word, and a valid as outputs (prefixed by a stage sigil: fe = fetch,
 * de = decode, ex = execute, ...). Further debug signals are added on
 * demand. This stage's outputs are the F/D pipeline register, so they
 * carry the `fe_` sigil: fe_pc_o / fe_instr_o / fe_valid_o.
 *
 * Registers:
 *   - pc_q     : next fetch address (runs ahead; redirect overwrites
 *                it with the branch target).
 *   - req_pc_q : address of the in-flight fetch; stamped on the F/D
 *                register at capture so fe_pc_o is EXACT.
 *   - busy_q   : a fetch is in flight.
 *   - flushed_q: a redirect killed the in-flight fetch; the next
 *                response must be drained and discarded.
 *   - fe_*     : F/D pipeline register; fe_valid_o is a HELD level
 *                (high from a fresh capture until decode consumes it
 *                via !stall_i, or a redirect kills it).
 *
 * Redirect (branch_valid_i, highest priority): kills the in-flight
 * fetch (flushed_q) AND any stale F/D content, and points pc_q at the
 * branch target. wvalid is gated by !branch_valid_i so no fetch of the
 * old pc_q issues during the redirect cycle.
 *
 * stall_i: downstream hazard back-pressure. While high the F/D
 * register is not consumed (held); prefetch still issues up to 1 ahead
 * (bounded by single outstanding) and is discarded on redirect.
 *
 * Compressed (C) extension is NOT handled here: the stage always
 * fetches 32-bit words and advances to the next word boundary. A
 * compressed instruction in the low half of a word means the next
 * instruction is the upper half of the SAME word (handled by decode),
 * so the next fetch is always the next word. Decode derives
 * is-compressed from fe_instr_o[1:0] itself, so it is not exported
 * here; it also uses fe_pc_o[1] to pick the upper half when a redirect
 * landed on an odd-half target (see decode).
 *
 * Redirect to an odd-half target (RVC: a 16-bit instr at bit[1]=1, e.g.
 * a branch landing at +2) leaves pc_q unaligned for one cycle. The
 * advance aligns down to the next word boundary ((pc_q & ~3) + 4),
 * realigning the stream; req_pc_q still holds the real (possibly
 * unaligned) PC so fe_pc_o is exact and decode can select the half
 * from fe_pc[1].
 *
 * Naming: ports use *_i/_o; internal signals have no prefix (they are
 * neither inputs nor outputs). Flop registers end in _q, their
 * next-state combinational counterparts in _d. The F/D register flops
 * carry the `fe_` sigil to identify them as the fetch stage's output
 * register (and to disambiguate fe_pc_q from pc_q, the next-fetch
 * address).
 */
module fetch_stage (
    input wire clk_i,
    input wire rstn_i,

    // Reset vector boot address
    input wire [XLEN-1:0] boot_addr_i,

    // Forward-compat (currently tied off in CPU top)
    input wire            stall_i,
    input wire            branch_valid_i,
    input wire [XLEN-1:0] branch_addr_i,

    // Native instruction-memory interface (consumed by the on-die bridge)
    output mem_req_t imem_req_o,
    input  mem_rsp_t imem_rsp_i,

    // F/D pipeline register outputs: each pipeline stage exposes the PC
    // it is treating, the instruction word, and a valid (stage sigil
    // `fe_`). Any further debug is added on demand.
    output wire [XLEN-1:0] fe_instr_o,  // F/D instruction word
    output wire [XLEN-1:0] fe_pc_o,     // F/D instruction PC (exact)
    output wire            fe_valid_o   // F/D valid (held level)
);

    // -----------------------------------------------------------------
    // State
    // -----------------------------------------------------------------
    logic [XLEN-1:0] pc_q, pc_d;  // next fetch address
    logic [XLEN-1:0] req_pc_q, req_pc_d;  // address of the in-flight fetch
    logic busy_q, busy_d;  // fetch in flight
    logic flushed_q, flushed_d;  // in-flight fetch is to be dropped

    logic fe_valid_q, fe_valid_d;
    logic [XLEN-1:0] fe_pc_q, fe_pc_d;
    logic [XLEN-1:0] fe_instr_q, fe_instr_d;

    // -----------------------------------------------------------------
    // Native interface outputs
    //
    // rready depends ONLY on registers (never on rvalid) => no
    // combinational loop through the bridge's axi.rready forwarding.
    // -----------------------------------------------------------------
    always_comb begin
        // Accept read data when the F/D register has room, or drain a
        // flushed (redirected) response to free the bridge.
        imem_req_o.rready = !fe_valid_q || flushed_q;

        // Issue a fetch when idle and not redirecting this cycle.
        imem_req_o.wvalid = !busy_q && !branch_valid_i;
        imem_req_o.we     = 1'b0;
        imem_req_o.addr   = pc_q;
        imem_req_o.wdata  = '0;
        imem_req_o.wstrb  = '0;
    end

    wire launch = imem_req_o.wvalid && imem_rsp_i.wready;  // req accepted
    wire rsp_cap = imem_rsp_i.rvalid && imem_req_o.rready;  // read data consumed

    // -----------------------------------------------------------------
    // Next-state / datapath (combinational)
    // -----------------------------------------------------------------
    always_comb begin
        // Defaults: hold
        busy_d     = busy_q;
        flushed_d  = flushed_q;
        pc_d       = pc_q;
        req_pc_d   = req_pc_q;
        fe_valid_d = fe_valid_q;
        fe_pc_d    = fe_pc_q;
        fe_instr_d = fe_instr_q;

        if (branch_valid_i) begin
            // ---- Redirect (highest priority) ----
            fe_valid_d = 1'b0;  // kill stale F/D
            pc_d       = branch_addr_i;  // next fetch -> target
            if (busy_q) begin
                if (rsp_cap) begin
                    // Flushed response lands this cycle: drain & discard.
                    flushed_d = 1'b0;
                    busy_d    = 1'b0;
                end else begin
                    // Mark the in-flight fetch to be drained when it lands.
                    flushed_d = 1'b1;
                end
            end else begin
                flushed_d = 1'b0;  // nothing in flight to drain
            end
        end else begin
            // ---- Normal ----
            // Launch the next fetch (single outstanding: only when idle).
            if (launch) begin
                busy_d   = 1'b1;
                req_pc_d = pc_q;  // remember the in-flight address (real PC)
                // Advance to the next WORD boundary: pc_q may be unaligned
                // for one cycle after a redirect to an odd-half target, so
                // align down before +4 to realign the stream (identical to
                // +4 when pc_q is already aligned).
                pc_d     = (pc_q & ~32'h3) + 32'd4;  // pc runs ahead (word-aligned)
            end

            // Capture / drain the in-flight response. Mutually exclusive
            // with launch: rsp_cap requires busy_q, launch requires !busy_q.
            if (rsp_cap) begin
                if (flushed_q) begin
                    // Dropped response from a redirected fetch.
                    flushed_d = 1'b0;
                    busy_d    = 1'b0;
                end else begin
                    // Capture with the *in-flight* pc (req_pc_q) => fe_pc exact.
                    fe_valid_d = 1'b1;
                    fe_pc_d    = req_pc_q;
                    fe_instr_d = imem_rsp_i.rdata;
                    busy_d     = 1'b0;
                end
            end

            // Consume the F/D register (decode accepts). Mutually
            // exclusive with capture: capture needs rready = !fe_valid_q
            // (F/D empty); consume needs fe_valid_q (F/D full).
            if (fe_valid_q && !stall_i) begin
                fe_valid_d = 1'b0;
            end
        end
    end

    // -----------------------------------------------------------------
    // Sequential
    // -----------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            pc_q       <= boot_addr_i;
            req_pc_q   <= '0;
            busy_q     <= 1'b0;
            flushed_q  <= 1'b0;
            fe_valid_q <= 1'b0;
            fe_pc_q    <= '0;
            fe_instr_q <= '0;
        end else begin
            pc_q       <= pc_d;
            req_pc_q   <= req_pc_d;
            busy_q     <= busy_d;
            flushed_q  <= flushed_d;
            fe_valid_q <= fe_valid_d;
            fe_pc_q    <= fe_pc_d;
            fe_instr_q <= fe_instr_d;
        end
    end

    assign fe_pc_o    = fe_pc_q;
    assign fe_instr_o = fe_instr_q;
    assign fe_valid_o = fe_valid_q;

endmodule
