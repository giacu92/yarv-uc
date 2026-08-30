`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

// ---------------------------------------------------------------
// Combinational ALU (RV32I) + M extension + Zilx EA.
//
// Base RV32I: result ready in the same cycle (result_valid=1 always for
// these ops). MUL is single-cycle (GowinSynthesis infers a DSP from the
// '*' operator). DIV/REM are multi-cycle (restoring division, 32
// iterations) behind a start/done handshake, in the same style as
// mem_req_t/mem_rsp_t: the master launches with start_i, the unit answers
// with result_valid_o.
//
// Zilx: the ALU only computes the indexed load's effective address:
//   EA = base + (index << shamt)   (ALU_LX)
// operand_a = rs2_data (base), operand_b = rs1_data (index); shamt comes
// from shamt_i (de_t.mem_shamt: 0 unscaled, log2(size) scaled).
// La load vera (mem_read + sign/zero-extend) è lavoro del LSU, non
// dell'ALU; wb_src=WB_MEM seleziona il dato caricato a writeback.
// ---------------------------------------------------------------


module alu (
    input wire clk_i,
    input wire rst_ni,

    input wire [XLEN-1:0] operand_a_i,
    input wire [XLEN-1:0] operand_b_i,
    input wire alu_op_t alu_op_i,  // enum port: needs explicit net type under `default_nettype none` (EX3094); struct ports (de_t/mem_req_t) auto-resolve to var, enum does not
    input wire [1:0] shamt_i,  // Zilx index scale (log2 size, 0 unscaled)

    // result_valid_o / result_o are driven procedurally in the final
    // always_comb below, so they are variables (logic) — a wire/net cannot
    // take a procedural assignment (GowinSynthesis EX3900). Inputs and the
    // assign-driven helpers stay wire (EX3094: under `default_nettype none`
    // every net needs an explicit net type, and `logic` is a variable kind,
    // not a net — so ports must be `wire`, matching the rest of the project).
    input  wire             start_i,         // pulse: launch the op (DIV/REM only)
    output logic            result_valid_o,
    output logic [XLEN-1:0] result_o
);

    // -----------------------------------------------------------
    // Base RV32I — combinational
    // -----------------------------------------------------------
    // Organised by ARRIVAL TIME, not by opcode. The ALU sits in the middle
    // of the machine's critical path
    //   regfile -> forward mux -> operand mux -> ALU -> wb mux -> forward mux
    // and the adder is the last thing on it to settle, so the adder's output
    // gets its own final 2:1 mux and everything that settles earlier is
    // folded into the other input of that mux.
    //
    // The previous form -- an 11-way `unique case` building base_result, with
    // a second if/else selecting div/mul on top -- put the adder deep inside
    // the first mux and cost 5.50 ns of mux depth after the carry chain,
    // MORE than the 4.76 ns adder feeding it (measured on the 2026-08-30
    // 49.359 MHz PnR run). Selecting on alu_op_i is free by comparison:
    // alu_op_i is a flopped de_q field, stable long before the operands
    // finish forwarding, so every select below is ready early.
    //
    // Ordering of the two late candidates is measured, not assumed. On the
    // 2026-08-31 PnR run the DSP's output (`mul_ss`) arrives 3.76 ns after
    // its operands and is the LATEST signal in the block -- later than the
    // adder's carry chain. An earlier version of this file folded MUL in
    // with the early candidates on the assumption it had slack; it did not,
    // and MUL immediately became the critical path at -1.041 ns with five
    // mux levels behind the DSP. So: MUL takes the final mux (1 level), the
    // adder the one behind it (2 levels), and genuinely early candidates
    // (div / compare / shift / logic) sit deepest (3 levels).

    logic [4:0] shamt_rb;  // shift amount from operand_b (SLL/SRL/SRA)
    assign shamt_rb = operand_b_i[4:0];

    // ---- the one adder ----------------------------------------
    // ADD/LX add; SUB/SLT/SLTU subtract as a + ~b + 1. One carry chain
    // serves all five, so SLT/SLTU no longer instantiate comparators of
    // their own -- that removes two more wide candidates from the mux and
    // one more 32-bit carry chain from the fabric.
    logic            op_is_sub;  // SUB / SLT / SLTU: a + ~b + 1
    logic            op_is_lx;  // Zilx EA: a + (b << shamt)
    logic [XLEN-1:0] addend_b;
    logic [  XLEN:0] adder_sum;  // MSB = carry-out, used by SLTU

    assign op_is_sub = (alu_op_i == ALU_SUB) || (alu_op_i == ALU_SLT) || (alu_op_i == ALU_SLTU);
    assign op_is_lx  = (alu_op_i == ALU_LX);

    always_comb begin
        if (op_is_sub) addend_b = ~operand_b_i;
        else if (op_is_lx) addend_b = operand_b_i << shamt_i;
        else addend_b = operand_b_i;
    end

    assign adder_sum = {1'b0, operand_a_i} + {1'b0, addend_b} + {{XLEN{1'b0}}, op_is_sub};

    // ---- compares, read off that same adder --------------------
    // Unsigned: a + ~b + 1 carries out exactly when a >= b, so a < b is the
    // inverted carry-out. Signed: differing sign bits decide on their own
    // (the negative operand is the smaller), otherwise the difference's sign
    // bit decides. Both are one LUT on top of the adder.
    logic cmp_lt;
    assign cmp_lt = (alu_op_i == ALU_SLTU) ? ~adder_sum[XLEN] :
        ((operand_a_i[XLEN-1] ^ operand_b_i[XLEN-1]) ? operand_a_i[XLEN-1] : adder_sum[XLEN-1]);

    // ---- everything that settles early -------------------------
    // Shifts and bitwise logic: no carry chain, so these can afford to sit
    // behind the deeper half of the mux tree.
    logic [XLEN-1:0] logic_shift_result;
    always_comb begin
        unique case (alu_op_i)
            ALU_SLL: logic_shift_result = operand_a_i << shamt_rb;
            ALU_SRL: logic_shift_result = operand_a_i >> shamt_rb;
            ALU_SRA: logic_shift_result = $signed(operand_a_i) >>> shamt_rb;
            ALU_XOR: logic_shift_result = operand_a_i ^ operand_b_i;
            ALU_OR:  logic_shift_result = operand_a_i | operand_b_i;
            ALU_AND: logic_shift_result = operand_a_i & operand_b_i;
            default: logic_shift_result = '0;
        endcase
    end

    // Selects for the final mux. sel_adder is the only one the adder's own
    // output has to wait on, and it depends on alu_op_i alone.
    logic sel_adder, sel_cmp;
    assign sel_adder = (alu_op_i == ALU_ADD) || (alu_op_i == ALU_SUB) || op_is_lx;
    assign sel_cmp   = (alu_op_i == ALU_SLT) || (alu_op_i == ALU_SLTU);

    // -----------------------------------------------------------
    // MUL — single-cycle (DSP inference)
    // -----------------------------------------------------------
    logic signed [2*XLEN-1:0] mul_ss;
    logic        [2*XLEN-1:0] mul_uu;
    logic signed [2*XLEN-1:0] mul_su;

    assign mul_ss = $signed(operand_a_i) * $signed(operand_b_i);
    assign mul_uu = operand_a_i * operand_b_i;
    assign mul_su = $signed(operand_a_i) * $signed({1'b0, operand_b_i});

    logic [XLEN-1:0] mul_result;
    always_comb begin
        unique case (alu_op_i)
            ALU_MUL:    mul_result = mul_ss[XLEN-1:0];
            ALU_MULH:   mul_result = mul_ss[2*XLEN-1:XLEN];
            ALU_MULHSU: mul_result = mul_su[2*XLEN-1:XLEN];
            ALU_MULHU:  mul_result = mul_uu[2*XLEN-1:XLEN];
            default:    mul_result = '0;
        endcase
    end

    logic is_mul_op;
    assign is_mul_op = (alu_op_i == ALU_MUL) || (alu_op_i == ALU_MULH) ||
        (alu_op_i == ALU_MULHSU) || (alu_op_i == ALU_MULHU);

    // -----------------------------------------------------------
    // DIV/REM — multi-cycle, restoring division, 32 iterations.
    // Div-by-zero is detected on the stored divisor (div_divisor_q); the
    // RISC-V results (all-ones for DIV/DIVU, the dividend for REM/REMU) are
    // encoded in the div_result mux below.
    //
    // Signed overflow (INT_MIN / -1) needs no special case: abs(INT_MIN)
    // is INT_MIN again in two's complement, so the unsigned core computes
    // 2^31 / 1 = 0x8000_0000 and 2^31 % 1 = 0, and the sign re-application
    // is a no-op for DIV (sign_a ^ sign_b = 0) and negates 0 for REM. That
    // is exactly the spec's required DIV = INT_MIN, REM = 0.
    // -----------------------------------------------------------
    logic is_div_op;
    assign is_div_op = (alu_op_i == ALU_DIV) || (alu_op_i == ALU_DIVU) || (alu_op_i == ALU_REM) ||
        (alu_op_i == ALU_REMU);

    typedef enum logic [1:0] {
        DIV_IDLE,
        DIV_RUN,
        DIV_DONE
    } div_state_e;
    div_state_e div_state_q, div_state_d;

    logic [4:0] div_cnt_q, div_cnt_d;
    logic [XLEN-1:0] div_a_q;
    logic div_a_neg_q, div_b_neg_q;
    logic [2*XLEN-1:0] div_rem_q, div_rem_d;  // {remainder, quotient} shift register
    logic [XLEN-1:0] div_divisor_q;

    // Unsigned operands for the division core; the sign is re-applied on
    // the output for DIV/REM (not for DIVU/REMU).
    logic [XLEN-1:0] div_a_abs, div_b_abs;
    assign div_a_abs = (alu_op_i inside {ALU_DIV, ALU_REM}) && operand_a_i[XLEN-1] ? -operand_a_i :
        operand_a_i;
    assign div_b_abs = (alu_op_i inside {ALU_DIV, ALU_REM}) && operand_b_i[XLEN-1] ? -operand_b_i :
        operand_b_i;

    // Shift-subtract helper nets. SUG949E §3 follows Verilog-2001 style:
    // no variable declarations nested inside an always block, so these
    // cannot be `automatic` locals declared in the DIV_RUN branch
    // (GowinSynthesis rejects that, the module is ignored, and the
    // u_alu instantiation cascades to EX3990). Declare them at module
    // scope and drive them with continuous assigns instead.
    logic [2*XLEN-1:0] shifted;
    logic [  XLEN-1:0] rem_part;
    assign shifted  = div_rem_q << 1;
    assign rem_part = shifted[2*XLEN-1:XLEN];

    // Un solo clock, reset sincrono (coerente col resto della pipeline;
    // SUG949E §3.2 rule 1: ogni registro deve avere un valore iniziale/di
    // reset -- prima div_a_q / div_divisor_q / div_a_neg_q / div_b_neg_q /
    // div_rem_q non ne avevano).
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            div_state_q   <= DIV_IDLE;
            div_cnt_q     <= '0;
            div_a_q       <= '0;
            div_divisor_q <= '0;
            div_a_neg_q   <= 1'b0;
            div_b_neg_q   <= 1'b0;
            div_rem_q     <= '0;
        end else begin
            div_state_q <= div_state_d;
            div_cnt_q   <= div_cnt_d;
            if (div_state_q == DIV_IDLE && start_i && is_div_op) begin
                div_a_q <= div_a_abs;
                div_divisor_q <= div_b_abs;
                div_a_neg_q <= (alu_op_i == ALU_DIV) && (operand_a_i[XLEN-1] ^ operand_b_i[XLEN-1]);
                div_b_neg_q <= (alu_op_i == ALU_REM) && operand_a_i[XLEN-1];
                div_rem_q <= {{XLEN{1'b0}}, div_a_abs};
            end else if (div_state_q == DIV_RUN) begin
                // uno shift-subtract per ciclo
                if (rem_part >= div_divisor_q) begin
                    // Quotient bit 1 into the LSB; keep shifted[31] (the next
                    // dividend bit now at the top of the quotient half) — the
                    // no-subtract branch keeps it via `shifted`, so the
                    // subtract branch must too (shifted[31:1], not [30:0],
                    // else every subtract drops one dividend bit).
                    div_rem_q <= {rem_part - div_divisor_q, shifted[XLEN-1:1], 1'b1};
                end else begin
                    div_rem_q <= shifted;
                end
            end
        end
    end

    always_comb begin
        div_state_d = div_state_q;
        div_cnt_d   = div_cnt_q;
        unique case (div_state_q)
            DIV_IDLE:
            if (start_i && is_div_op) begin
                div_state_d = DIV_RUN;
                div_cnt_d   = '0;
            end
            DIV_RUN: begin
                if (div_cnt_q == XLEN - 1) div_state_d = DIV_DONE;
                else div_cnt_d = div_cnt_q + 5'd1;  // sized: avoid 6->5 truncation (EX3791)
            end
            DIV_DONE: div_state_d = DIV_IDLE;
            default:  div_state_d = DIV_IDLE;
        endcase
    end

    logic [XLEN-1:0] div_quot_raw, div_rem_raw;
    assign div_quot_raw = div_rem_q[XLEN-1:0];
    assign div_rem_raw  = div_rem_q[2*XLEN-1:XLEN];

    logic [XLEN-1:0] div_result;
    always_comb begin
        // Div-by-zero: detect on the stored divisor (div_divisor_q holds
        // abs(operand_b) for DIV/REM, operand_b for DIVU/REMU -- both are
        // 0 iff operand_b==0). Previously this used div_b_q, a register
        // that was never written, so the check was stuck at true and every
        // DIV/REM wrongly took the div-by-zero path.
        // Signed overflow (INT_MIN / -1) falls out correctly without a
        // special case -- see the note on the DIV/REM block above.
        unique case (alu_op_i)
            ALU_DIV:
            div_result = (div_divisor_q == 0) ?
                {XLEN{1'b1}} : (div_a_neg_q ? -div_quot_raw : div_quot_raw);
            ALU_DIVU: div_result = (div_divisor_q == 0) ? {XLEN{1'b1}} : div_quot_raw;
            ALU_REM:
            div_result = (div_divisor_q == 0) ?
                div_a_q : (div_b_neg_q ? -div_rem_raw : div_rem_raw);
            ALU_REMU: div_result = (div_divisor_q == 0) ? div_a_q : div_rem_raw;
            default: div_result = '0;
        endcase
    end

    // -----------------------------------------------------------
    // Mux finale + valid
    // -----------------------------------------------------------
    // Ordered by measured arrival: MUL (DSP, latest) gets the final mux,
    // the adder the one behind it, everything genuinely early sits deepest.
    // See the arrival-time note at the top of the base-RV32I block.
    logic [XLEN-1:0] early_result;

    always_comb begin
        if (is_div_op) early_result = div_result;
        else if (sel_cmp) early_result = {{(XLEN - 1) {1'b0}}, cmp_lt};
        else early_result = logic_shift_result;
    end

    always_comb begin
        if (is_mul_op) result_o = mul_result;
        else if (sel_adder) result_o = adder_sum[XLEN-1:0];
        else result_o = early_result;
    end

    // Only DIV/REM can be un-ready; everything else answers in-cycle.
    always_comb begin
        if (is_div_op) result_valid_o = (div_state_q == DIV_DONE);
        else result_valid_o = 1'b1;
    end

endmodule

`resetall
