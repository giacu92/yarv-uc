`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
 * Fetch stage of the pipeline — 64-bit, 2-outstanding, with a 32-bit
 * instruction buffer.
 *
 * Owns the PC and drives a 64-bit read-only native I-mem interface
 * (ifetch_req_t / ifetch_rsp_t). One 8-byte access delivers two 32-bit
 * words (3-4 with RVC); two reads may be outstanding, so the BSRAM keeps
 * issuing through the decode stalls (DIV/REM, mem-wait) that would idle a
 * single-outstanding port. A depth-8 32-bit-word instruction buffer decouples
 * the 64-bit fetch rate from the 32-bit decode rate: each 64-bit response is
 * split into one or two 32-bit entries (PC-stamped) and pushed at the tail;
 * decode pops the head one word per cycle.
 *
 * Native interface (valid/ready on both sides, see rv32_pkg):
 *   - Request launch : imem_req_o.valid && imem_rsp_i.ready
 *   - Read response  : imem_rsp_i.rvalid && imem_req_o.rready
 *
 * Decode contract: the buffer head is exported as fe_instr /
 * fe_pc / fe_valid / fe_fault, 32-bit / 32-bit / 1-bit / 1-bit, exactly as
 * the old 2-deep F/D+skid FIFO exported them. Decode is a pure consumer of
 * the head register and cannot tell a 32-bit RAM from a split 64-bit RAM.
 * A second read port exports head+1 (fe_next_instr / fe_next_pc /
 * fe_next_valid = count>=2 / fe_next_fault) so decode can same-cycle stitch
 * a 32-bit instr at a 2-byte-aligned branch target (offset 2/6) without a
 * bubble; fe_pop2_i tells fetch to drop both entries on that stitch. The
 * sequential RVC spanning stitch (span_wait, a 32-bit instr at offset 2
 * reached by fall-through) still lives in decode and costs 1 bubble --
 * removing it is dual-issue, a separate change.
 *
 * PC + split:
 *   - pc_q advances by 8 in steady state; pc_d = (pc_q & ~7) + 8 after a
 *     launch/fault. On a redirect pc_q = branch_addr_i (possibly 2-aligned
 *     for an RVC odd-half target, exactly as before).
 *   - req_pc_q holds the real (possibly unaligned) PC of the in-flight
 *     read. The I-mem aligns the address down to 8; fetch splits the
 *     64-bit word back into 32-bit halves at the right PCs:
 *       base = req_pc_q & ~7; low word @base, high word @base+4.
 *       req_pc_q[2]==0 -> push low (pc=req_pc_q, carries unaligned [1:0])
 *                         then high (pc=base+4).           [2 words]
 *       req_pc_q[2]==1 -> skip low (before target), push high
 *                         (pc=req_pc_q, carries unaligned [1]). [1 word]
 *     This reproduces the old "RAM aligns down, fe_pc carries the unaligned
 *     req_pc, decode uses fe_pc[1]" contract — traced for redirect->0x2 and
 *     redirect->0x6.
 *
 * 2-outstanding + redirect drain:
 *   - inflight_q (0..2): outstanding reads (inc on launch, dec on rsp_cap).
 *   - draining_q: a redirect invalidated all in-flight reads; their stale
 *     responses are accepted (rready=1) and discarded until inflight reaches
 *     0, then fetching resumes at branch_addr_i. No buffer push while
 *     draining. The I-mem's depth-2 response skid backs this up (at most 2
 *     stale responses to drain).
 *
 * Buffer-room gating (overflow-safe): each outstanding read can push up to
 * 2 words, so issue reserves 2 slots per in-flight read.
 *   reserved     = count + 2*inflight  (always <= 8 by invariant)
 *   available    = 8 - reserved
 *   bus_issue    = inflight<2 && available>=2 && !redirect && !drain && !fault
 *   fault_push   = pc_fault && available>=1 && !redirect && !drain && !rsp_cap
 * A fault pushes exactly 1 word and launches no read -> its own >=1 gate,
 * and it is deferred a cycle when a response is landing the same cycle so
 * the buffer never pushes more than 2 words in one cycle.
 *
 * Registers:
 *   - pc_q / req_pc_q : next fetch address / in-flight read address.
 *   - inflight_q      : outstanding reads (0..2).
 *   - draining_q      : draining stale in-flight reads after a redirect.
 *   - buf_*_q[8]      : depth-8 32-bit-word instruction buffer.
 *   - head_q/tail_q/count_q : buffer FIFO pointers + occupancy.
 *
 * Redirect (branch_valid_i, highest priority): kills the buffer (count=0,
 * head=tail=0), points pc_q at the target, arms draining for any in-flight
 * reads. rready is forced so a stale response landing the same cycle is
 * discarded. No launch, no push, no pop on the redirect cycle.
 *
 * stall_i: decode back-pressure. While high the head is held (no pop); fetch
 * keeps running ahead into the buffer (up to 8 words), then stops issuing
 * once full. Redirects discard the buffered words.
 *
 * Naming: ports *_i/_o; internals no prefix; flops _q, next-state _d.
 */
module fetch_stage #(
    // Implemented I-mem size, in address bits (2**IMEM_ADDR_W bytes). A PC
    // outside that range cannot be fetched: the memory decodes only these
    // bits, so the access would alias back into real instructions and
    // execute them. Fetch raises an instruction access fault instead. Must
    // match the I-mem actually instantiated at the top level.
    parameter int IMEM_ADDR_W = 14
) (
    input wire clk_i,
    input wire rstn_i,

    // Reset vector boot address
    input wire [XLEN-1:0] boot_addr_i,

    // Downstream back-pressure and the execute-resolved redirect
    // (branch / jump / trap entry / mret), both wired at the CPU top.
    input wire            stall_i,
    input wire            branch_valid_i,
    input wire [XLEN-1:0] branch_addr_i,

    // Decode-time predicted redirect (branch predictor). Lower priority than
    // the execute redirect: a mispredict / trap / mret / interrupt resolved in
    // execute overrides whatever decode speculated. Routed through the same
    // kill path as branch_valid_i — kills the buffer, points pc_q at the
    // predicted target, arms draining for any in-flight reads. The predicted
    // branch itself sits at the buffer head this cycle and is consumed into
    // decode's de_q combinationally, so killing the buffer only discards the
    // younger wrong-path entries behind it (same net effect as an execute
    // redirect, one cycle earlier).
    input wire            pred_valid_i,
    input wire [XLEN-1:0] pred_addr_i,

    // Native 64-bit instruction-memory interface (read-only).
    output ifetch_req_t imem_req_o,
    input  ifetch_rsp_t imem_rsp_i,

    // F/D pipeline register outputs (buffer head): each pipeline stage
    // exposes the PC it is treating, the instruction word, and a valid
    // (stage sigil `fe_`).
    output wire [XLEN-1:0] fe_instr_o,  // F/D instruction word (32-bit)
    output wire [XLEN-1:0] fe_pc_o,     // F/D instruction PC (exact)
    output wire            fe_valid_o,  // F/D valid (held level)
    output wire            fe_fault_o,  // F/D entry is an access fault, not an instruction

    // Buffer head+1 read port (same-cycle RVC spanning stitch). Exposes the
    // word right behind the head so decode can stitch a 32-bit instr sitting
    // at a 2-byte-aligned branch target (offset 2 / 6) without a bubble: the
    // stitch consumes head[31:16] + head+1[15:0] in the cycle the target word
    // is seen. Gated by fe_next_valid_o (count>=2); decode drives fe_pop2_i
    // only then, so pop-2 <= count (no underflow).
    output wire [XLEN-1:0] fe_next_instr_o,  // buffer[head+1] word
    output wire [XLEN-1:0] fe_next_pc_o,     // buffer[head+1] PC
    output wire            fe_next_valid_o,  // count >= 2
    output wire            fe_next_fault_o,  // buffer[head+1] fault flag
    input  wire            fe_pop2_i         // decode: pop 2 this cycle (target stitch)
);

    // -----------------------------------------------------------------
    // State
    // -----------------------------------------------------------------
    localparam int BUF_DEPTH = 8;

    logic [XLEN-1:0] pc_q, pc_d;  // next fetch address
    logic [XLEN-1:0] req_pc_q, req_pc_d;  // address of the in-flight read
    logic [1:0] inflight_q, inflight_d;  // outstanding reads (0..2)
    logic draining_q, draining_d;  // discarding stale in-flight reads

    // Depth-8 32-bit-word instruction buffer (FIFO).
    logic [XLEN-1:0] buf_instr_q[BUF_DEPTH];
    logic [XLEN-1:0] buf_pc_q   [BUF_DEPTH];
    logic            buf_fault_q[BUF_DEPTH];
    logic [2:0] head_q, head_d;
    logic [2:0] tail_q, tail_d;
    logic [3:0] count_q, count_d;  // 0..BUF_DEPTH

    // -----------------------------------------------------------------
    // Native interface + control wires
    // -----------------------------------------------------------------
    // PC outside the implemented I-mem: no bus request, synthesise a fault
    // FIFO entry instead (the memory would alias an out-of-range read back
    // into the image and execute it).
    wire pc_fault = |pc_q[XLEN-1:IMEM_ADDR_W];

    // Read response accepted this cycle.
    wire rsp_cap = imem_rsp_i.rvalid && imem_req_o.rready;

    // Redirect priority: execute (trap/mret/mispredict, branch_valid_i) is
    // highest; the decode prediction is subordinate and suppressed when an
    // execute redirect fires the same cycle. Both share one kill path.
    wire pred_redirect = pred_valid_i & ~branch_valid_i;
    wire redirect = branch_valid_i | pred_redirect;
    wire [XLEN-1:0] redirect_addr = branch_valid_i ? branch_addr_i : pred_addr_i;

    // Buffer-room accounting. reserved = count + 2*inflight <= 8 (invariant
    // maintained by the issue gate), so available is non-negative.
    wire [2:0] twice_inflight = {inflight_q, 1'b0};  // inflight * 2
    wire [4:0] reserved = {1'b0, count_q} + {2'b0, twice_inflight};
    wire [4:0] available = 5'd8 - reserved;  // >= 0 by invariant

    // Issue a fetch when idle (inflight<2), not redirecting/draining, the PC
    // is in range, and the buffer has room for the response (2 words reserved
    // per in-flight read).
    wire bus_issue = (inflight_q < 2'd2) && (available >= 5'd2) && !redirect && !draining_q &&
        !pc_fault;
    // A fault pushes 1 word and launches no read -> its own >=1 gate. Hold it
    // off a cycle when a response is landing the same cycle so the buffer
    // never pushes more than 2 words in one cycle.
    wire fault_push = pc_fault && (available >= 5'd1) && !redirect && !draining_q && !rsp_cap;

    // Read launch accepted this cycle.
    wire launch = bus_issue && imem_rsp_i.ready;

    always_comb begin
        // Accept read data when draining stale responses (discard), on a
        // redirect (discard the one landing now), or whenever the buffer
        // has room for the two words a response can push. Depends only on
        // registers (draining_q, count_q) + nothing from the slave's rvalid
        // -> no combinational loop through the I-mem.
        imem_req_o.rready = redirect || draining_q || (count_q <= 4'd6);

        // Issue a fetch when idle (inflight<2), not redirecting/draining, the
        // PC is in range, and the buffer has room for the response (2 words
        // reserved per in-flight read).
        imem_req_o.valid  = bus_issue;
        imem_req_o.addr   = pc_q;
    end

    // -----------------------------------------------------------------
    // 64-bit response split -> 32-bit buffer pushes (0, 1, or 2 words/cycle)
    // -----------------------------------------------------------------
    wire do_rsp = rsp_cap && !draining_q && !redirect;
    wire rsp_two = ~req_pc_q[2];  // target in low half -> push both words

    wire [XLEN-1:0] rsp_low_pc = req_pc_q;
    wire [XLEN-1:0] rsp_high_pc = (req_pc_q & ~32'h7) + 32'd4;
    wire [31:0] rsp_low_word = imem_rsp_i.rdata[31:0];
    wire [31:0] rsp_high_word = imem_rsp_i.rdata[63:32];

    // First push: the half containing the fetch PC (low if [2]==0, high if
    // [2]==1). The PC stamp is ALWAYS req_pc_q (rsp_low_pc): it carries the
    // unaligned target bits ([1:0] for the low half, [1] for the high half)
    // so decode's fe_pc[1] selects the right halfword. Using rsp_high_pc
    // (= base+4) for the [2]==1 case would clear bit[1] and make decode pick
    // the wrong halfword on a 2-aligned redirect into the high half
    // (e.g. jalr to 0xee stamped 0xec). A fault push fills this slot
    // (pc=pc_q, fault=1).
    wire [XLEN-1:0] push0_pc = do_rsp ? rsp_low_pc : pc_q;
    wire [31:0] push0_word = do_rsp ? (rsp_two ? rsp_low_word : rsp_high_word) : 32'd0;
    wire push0_fault = !do_rsp;  // fault_push case (do_rsp==0)

    // Second push: the high half, only when pushing both words.
    wire [XLEN-1:0] push1_pc = rsp_high_pc;
    wire [31:0] push1_word = rsp_high_word;
    wire push1_fault = 1'b0;

    wire [1:0] push_cnt = do_rsp ? (rsp_two ? 2'd2 : 2'd1) : fault_push ? 2'd1 : 2'd0;

    // -----------------------------------------------------------------
    // Buffer pop: decode consumes the head when it is not back-pressuring
    // and not the redirect cycle. A same-cycle target-span stitch pops 2
    // (head + head+1, the stitch word + its consumed low half); fe_pop2_i
    // is only asserted when fe_next_valid_o (count>=2), so pop-2 <= count
    // — no underflow. stall_i / branch_valid_i zero the count, matching
    // the old 1-pop behaviour for every non-stitch case.
    // -----------------------------------------------------------------
    wire [1:0]
        buf_pop_cnt = (count_q != 4'd0 && !stall_i && !redirect) ? (fe_pop2_i ? 2'd2 : 2'd1) : 2'd0;

    // -----------------------------------------------------------------
    // Next-state
    // -----------------------------------------------------------------
    always_comb begin
        // Defaults: hold.
        pc_d       = pc_q;
        req_pc_d   = req_pc_q;
        inflight_d = inflight_q;
        draining_d = draining_q;
        head_d     = head_q;
        tail_d     = tail_q;
        count_d    = count_q;

        if (redirect) begin
            // ---- Redirect (highest priority) ----
            // Execute (trap/mret/mispredict) wins over a decode prediction;
            // redirect_addr selects accordingly. Kills the buffer, points pc_q
            // at the target, arms draining for any in-flight reads. The
            // predicted branch at the head is consumed into decode's de_q this
            // cycle (combinational read), so zeroing the buffer only discards
            // the younger wrong-path entries behind it.
            pc_d    = redirect_addr;
            head_d  = 3'd0;  // kill the buffer
            tail_d  = 3'd0;
            count_d = 4'd0;
            // No launch/push/pop this cycle; a landing response is stale and
            // discarded (rready is high). inflight is updated below.
        end else if (draining_q) begin
            // ---- Drain stale in-flight responses (discard) ----
            // No push, no pop, no launch. rready is high so the I-mem skid
            // drains at max rate. Buffer stays empty (killed on redirect).
        end else begin
            // ---- Normal: issue + split-push + buffer drain ----
            if (launch) begin
                req_pc_d = pc_q;  // remember the in-flight read address
                pc_d     = (pc_q & ~32'h7) + 32'd8;  // next 8-byte boundary
            end
            if (fault_push) begin
                // A fault PC advances past the unfetchable 8-byte word.
                pc_d = (pc_q & ~32'h7) + 32'd8;
            end
            // Buffer FIFO advance. buf_pop_cnt is 0/1/2 (3-bit wrap on head).
            head_d  = head_q + buf_pop_cnt;
            tail_d  = tail_q + push_cnt;  // 0/1/2, 3-bit wrap
            count_d = count_q + push_cnt - buf_pop_cnt;
        end

        // inflight tracks outstanding reads: +1 on launch, -1 on rsp_cap.
        // Both may happen the same cycle (a response retires while a new
        // read issues) -> net unchanged, so apply incrementally.
        if (launch) inflight_d = inflight_d + 2'd1;
        if (rsp_cap) inflight_d = inflight_d - 2'd1;

        // Draining arms on a redirect and persists while any stale read is
        // still outstanding; it clears the cycle inflight reaches 0 (so a
        // redirect with nothing in flight costs no drain bubble, matching
        // the old flushed_q behaviour).
        draining_d = (redirect || draining_q) && (inflight_d != 2'd0);
    end

    // -----------------------------------------------------------------
    // Sequential
    // -----------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            pc_q       <= boot_addr_i;
            req_pc_q   <= '0;
            inflight_q <= 2'd0;
            draining_q <= 1'b0;
            head_q     <= 3'd0;
            tail_q     <= 3'd0;
            count_q    <= 4'd0;
        end else begin
            pc_q       <= pc_d;
            req_pc_q   <= req_pc_d;
            inflight_q <= inflight_d;
            draining_q <= draining_d;
            head_q     <= head_d;
            tail_q     <= tail_d;
            count_q    <= count_d;
            // Buffer writes: push0 at tail, push1 at tail+1 (3-bit wrap).
            if (push_cnt >= 2'd1) begin
                buf_instr_q[tail_q] <= push0_word;
                buf_pc_q[tail_q]    <= push0_pc;
                buf_fault_q[tail_q] <= push0_fault;
            end
            if (push_cnt >= 2'd2) begin
                buf_instr_q[tail_q+3'd1] <= push1_word;
                buf_pc_q[tail_q+3'd1]    <= push1_pc;
                buf_fault_q[tail_q+3'd1] <= push1_fault;
            end
        end
    end

    // -----------------------------------------------------------------
    // F/D outputs (buffer head). fe_valid is a held level (head stays until
    // decode consumes it via !stall_i, or a redirect kills the buffer).
    // -----------------------------------------------------------------
    assign fe_instr_o = buf_instr_q[head_q];
    assign fe_pc_o    = buf_pc_q[head_q];
    assign fe_valid_o = (count_q != 4'd0);
    assign fe_fault_o = buf_fault_q[head_q];

    // Buffer head+1 read port (same-cycle target-span stitch). head_next is a
    // 3-bit wrap, always a valid 0..7 index even when count<2; decode gates on
    // fe_next_valid_o. A redirect zeros count -> both fe_valid_o and
    // fe_next_valid_o drop, so no extra kill logic.
    wire [2:0] head_next = head_q + 3'd1;
    assign fe_next_instr_o = buf_instr_q[head_next];
    assign fe_next_pc_o    = buf_pc_q[head_next];
    assign fe_next_fault_o = buf_fault_q[head_next];
    assign fe_next_valid_o = (count_q >= 4'd2);

`ifdef VERILATOR
    // The split assumes the I-mem aligns the read address down to 8 bytes
    // (it decodes addr[ADDR_W-1:3]); req_pc_q[2] then selects which 32-bit
    // half the fetch PC falls in. The buffer invariant count + 2*inflight
    // <= 8 is what makes the issue gate overflow-safe.
    initial
        assert (BUF_DEPTH == 8)
        else $fatal(1, "BUF_DEPTH width assumptions broken");
`endif

endmodule

`resetall
