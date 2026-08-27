`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
 * Branch predictor — gshare 2-bit PHT + 6-bit GHR + 8-entry RAS.
 *
 * Phase 1 of the branch-prediction add: direction prediction for conditional
 * branches (gshare PHT) + return-address prediction for JALR returns (RAS).
 * Unconditional JAL/c.j/c.jal and conditional-branch *targets* are computed
 * directly in decode (pc+imm, off the regfile path), so there is no BTB here;
 * a BTB/indirect-target cache for non-return JALR is a deferred Phase 2.
 *
 * Prediction happens at DECODE (the buffer head), one stage earlier than
 * execute's resolve, so a correct prediction lets execute skip its redirect
 * entirely. Execute remains the golden resolver: it compares the carried
 * prediction against the resolved outcome and redirects only on mispredict.
 *
 * Timing rule: the lookup depends ONLY on the PC and the GHR — never on
 * register data — so it sits off the `regfile -> forward mux -> branch
 * compare -> PC redirect` critical path. The PHT (64x2b), GHR (6b) and RAS
 * (8x32b) live in FF/LUTRAM with a combinational lookup; for 64 entries that
 * avoids adding a cycle to the frontend (note §11).
 *
 * Training happens ONLY at resolve (the execute training port), never on
 * speculative outcomes. In-order single-issue means a squashed instruction
 * never resolves, so there is no wrong-path contamination of the PHT/GHR/RAS.
 * The PHT update is indexed by the gshare snapshot carried in de_t
 * (pred_pht_index = pc[7:2]^ghr at decode time), not the live GHR — an older
 * branch may have shifted the GHR between this branch's decode and its
 * resolve, and the update must use the history the branch was predicted with.
 *
 * GHR (global history register): 6 bits, shifted left on each resolved
 * conditional branch (newest outcome in bit 0). Used to xor the PHT index
 * (gshare) so correlated branches share state usefully. Updated only for
 * conditional branches (note Appendix A).
 *
 * RAS (return address stack): 8 entries, circular with a saturating count.
 * Pushed at the resolve of a CALL (JAL/JALR with rd in {x1,x5}), popped at the
 * resolve of a RETURN (JALR with rs1 in {x1,x5}, rd=x0). The top is read at
 * decode to predict a return's target. Trained at resolve, not at predict, so
 * a wrong-path call never pushes — the RAS is not corrupted by speculation.
 * RAS read (decode, this cycle) and write (execute, an older instr resolving)
 * hit different entries, so the 8-flop array supports both in one cycle.
 *
 * Naming: ports *_i/_o; internals no prefix; flops _q/_d.
 */
module branch_predictor (
    input wire clk_i,
    input wire rstn_i,

    // -------------------------------------------------------------------
    // Lookup port (decode, combinational). Decode presents the PC of the
    // control-flow instruction at the buffer head plus its kind; the
    // predictor returns the PHT direction bit (conditional), the RAS top
    // (return), and the gshare index snapshot to carry in de_t.
    // -------------------------------------------------------------------
    input  wire bp_lookup_req_t lookup_req_i,
    output wire bp_lookup_rsp_t lookup_rsp_o,

    // -------------------------------------------------------------------
    // Training port (execute, at resolve). One resolved control-flow
    // instruction per cycle (in-order single-issue). Mutually exclusive
    // kind bits; exactly the PHT/GHR/RAS state for that kind updates.
    // -------------------------------------------------------------------
    input  wire bp_train_t train_i
);

    // Field aliases — keep the body reading the same names as the old per-
    // wire port list, so the lookup/train logic below is unchanged.
    wire [XLEN-1:0] lookup_pc_i    = lookup_req_i.pc;
    wire            lookup_cond_i  = lookup_req_i.cond;
    wire            lookup_return_i = lookup_req_i.ret;
    wire            train_valid_i    = train_i.valid;
    wire            train_cond_i     = train_i.cond;
    wire            train_call_i     = train_i.call;
    wire            train_return_i   = train_i.ret;
    wire            train_indirect_i = train_i.indirect;
    wire            train_taken_i    = train_i.taken;
    wire [5:0]      train_pht_index_i = train_i.pht_index;
    wire [XLEN-1:0] train_push_pc_i  = train_i.push_pc;

    // -------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------
    localparam int unsigned PHT_DEPTH = 64;
    localparam int unsigned GHR_W     = 6;
    localparam int unsigned RAS_DEPTH = 8;

    logic [1:0]       pht_q [PHT_DEPTH];
    logic [GHR_W-1:0] ghr_q;
    logic [XLEN-1:0]  ras_q [RAS_DEPTH];
    logic [2:0]       ras_ptr_q;   // next push slot (wraps mod 8)
    logic [3:0]       ras_cnt_q;   // 0..8, saturating

    // -------------------------------------------------------------------
    // Lookup (combinational, PC + GHR only)
    // -------------------------------------------------------------------
    wire [5:0] lookup_index = lookup_pc_i[7:2] ^ ghr_q;
    // Top = most-recently-pushed entry = slot (ptr - 1). When empty the top is
    // a don't-care (ras_valid=0 gates its use in decode).
    wire [2:0] ras_top_idx = ras_ptr_q - 3'd1;
    wire ras_valid = (ras_cnt_q != 4'd0);

    assign lookup_rsp_o.pht_index = lookup_index;
    assign lookup_rsp_o.pht_taken = pht_q[lookup_index][1];
    assign lookup_rsp_o.ras_valid = ras_valid;
    assign lookup_rsp_o.ras_top   = ras_q[ras_top_idx];

    // -------------------------------------------------------------------
    // 2-bit saturating counter update
    // -------------------------------------------------------------------
    function automatic logic [1:0] sat_update(input logic [1:0] c, input logic t);
        logic [1:0] r;
        if (t) r = (c == 2'b11) ? 2'b11 : (c + 2'b01);
        else   r = (c == 2'b00) ? 2'b00 : (c - 2'b01);
        return r;
    endfunction

    // -------------------------------------------------------------------
    // Next-state
    // -------------------------------------------------------------------
    logic [1:0]       pht_d     [PHT_DEPTH];
    logic [GHR_W-1:0] ghr_d;
    logic [XLEN-1:0]  ras_d     [RAS_DEPTH];
    logic [2:0]       ras_ptr_d;
    logic [3:0]       ras_cnt_d;

    always_comb begin
        // Default: hold.
        for (int i = 0; i < PHT_DEPTH; i++) pht_d[i] = pht_q[i];
        for (int i = 0; i < RAS_DEPTH; i++) ras_d[i] = ras_q[i];
        ghr_d     = ghr_q;
        ras_ptr_d = ras_ptr_q;
        ras_cnt_d = ras_cnt_q;

        if (train_valid_i) begin
            // PHT + GHR: conditional only. Index from the de_t snapshot so the
            // update uses the history the branch was predicted with, not the
            // (possibly since-shifted) live GHR.
            if (train_cond_i) begin
                pht_d[train_pht_index_i] = sat_update(pht_q[train_pht_index_i], train_taken_i);
                ghr_d = {ghr_q[GHR_W-2:0], train_taken_i};
            end
            // RAS push (call). Circular: write at ptr, advance ptr (mod 8),
            // saturate count at RAS_DEPTH (a push when full overwrites the
            // oldest entry — standard circular-RAS behaviour).
            if (train_call_i) begin
                ras_d[ras_ptr_q]   = train_push_pc_i;
                ras_ptr_d          = ras_ptr_q + 3'd1;
                ras_cnt_d          = (ras_cnt_q == RAS_DEPTH) ? ras_cnt_q : (ras_cnt_q + 4'd1);
            end
            // RAS pop (return). Decrement ptr (mod 8); count floors at 0 (a
            // pop when empty just walks the pointer, harmless: ras_valid_o=0).
            if (train_return_i) begin
                ras_ptr_d          = ras_ptr_q - 3'd1;
                ras_cnt_d          = (ras_cnt_q == 4'd0) ? 4'd0 : (ras_cnt_q - 4'd1);
            end
        end
    end

    // -------------------------------------------------------------------
    // Sequential
    // -------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            for (int i = 0; i < PHT_DEPTH; i++) pht_q[i] <= 2'b01;  // weak not-taken
            ghr_q     <= '0;
            ras_ptr_q <= 3'd0;
            ras_cnt_q <= 4'd0;
            // ras_q unset on reset (top is gated by ras_valid_o); the sim
            // zero-inits unsynthesised flops, and silicon never reads a slot
            // before a push writes it (count floors the valid window).
        end else begin
            for (int i = 0; i < PHT_DEPTH; i++) pht_q[i] <= pht_d[i];
            for (int i = 0; i < RAS_DEPTH; i++) ras_q[i] <= ras_d[i];
            ghr_q     <= ghr_d;
            ras_ptr_q <= ras_ptr_d;
            ras_cnt_q <= ras_cnt_d;
        end
    end

    // -------------------------------------------------------------------
    // Debug counters (sim only). Fed by decode/execute event inputs so all
    // bp_* stats are tapped from one hierarchy in sim_main. No architectural
    // effect; the inputs are don't-cares when the predictor is disabled.
    // -------------------------------------------------------------------
`ifdef VERILATOR
    // Event inputs declared as ports would clutter the architectural list, so
    // they are probed directly by sim_main off the decode/execute hierarchy
    // instead. Keep only RAS-internal stats here.
    longint unsigned ras_hit_q;
    longint unsigned ras_miss_q;
    always_ff @(posedge clk_i) begin
        if (rstn_i) begin
            if (lookup_return_i) begin
                if (ras_valid) ras_hit_q  <= ras_hit_q  + 64'd1;
                else           ras_miss_q <= ras_miss_q + 64'd1;
            end
        end
    end
`endif

endmodule

`resetall