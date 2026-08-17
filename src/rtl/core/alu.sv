`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

// ---------------------------------------------------------------
// ALU combinazionale (RV32I) + estensione M + Zilx EA.
//
// Base RV32I: risultato pronto nello stesso ciclo (result_valid=1
// sempre per queste op). MUL è single-cycle (synth inferisce DSP
// sulla GoWin con l'operatore '*'). DIV/REM sono multi-ciclo
// (restoring division, 32 iterazioni) con handshake start/done,
// stesso stile di mem_req_t/mem_rsp_t: master lancia con
// div_start, bridge risponde con div_done.
//
// Zilx: l'ALU calcola solo l'effective address dell'indexed load:
//   EA = base + (index << shamt)   (ALU_LX)
// operand_a = rs2_data (base), operand_b = rs1_data (index), shamt
// arriva da shamt_i (de_t.mem_shamt: 0 unscaled, log2(size) scaled).
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
    input  wire             start_i,         // impulso: lancia l'op (serve solo per DIV/REM)
    output logic            result_valid_o,
    output logic [XLEN-1:0] result_o
);

    // -----------------------------------------------------------
    // Base RV32I — combinazionale
    // -----------------------------------------------------------
    logic [XLEN-1:0] base_result;
    logic [     4:0] shamt_rb;  // shift amount from operand_b (SLL/SRL/SRA)
    assign shamt_rb = operand_b_i[4:0];

    always_comb begin
        unique case (alu_op_i)
            ALU_ADD:  base_result = operand_a_i + operand_b_i;
            ALU_SUB:  base_result = operand_a_i - operand_b_i;
            ALU_SLL:  base_result = operand_a_i << shamt_rb;
            ALU_SLT:  base_result = {31'b0, $signed(operand_a_i) < $signed(operand_b_i)};
            ALU_SLTU: base_result = {31'b0, operand_a_i < operand_b_i};
            ALU_XOR:  base_result = operand_a_i ^ operand_b_i;
            ALU_SRL:  base_result = operand_a_i >> shamt_rb;
            ALU_SRA:  base_result = $signed(operand_a_i) >>> shamt_rb;
            ALU_OR:   base_result = operand_a_i | operand_b_i;
            ALU_AND:  base_result = operand_a_i & operand_b_i;
            ALU_LX:   base_result = operand_a_i + (operand_b_i << shamt_i);  // Zilx
            default:  base_result = '0;
        endcase
    end

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
    // DIV/REM — multi-ciclo, restoring division, 32 iterazioni.
    // Div-by-zero e' rilevato sul divisore memorizzato (div_divisor_q);
    // i risultati RISC-V (all-ones per DIV/DIVU, dividendo per REM/REMU)
    // sono codificati nel mux div_result qui sotto.
    // TODO: overflow (INT_MIN / -1) non ancora gestito.
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

    // operandi unsigned per il core della divisione; il segno si
    // riapplica in uscita per DIV/REM (non per DIVU/REMU)
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
        // TODO: overflow (INT_MIN / -1) is still not handled.
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
    always_comb begin
        if (is_div_op) begin
            result_o       = div_result;
            result_valid_o = (div_state_q == DIV_DONE);
        end else if (is_mul_op) begin
            result_o       = mul_result;
            result_valid_o = 1'b1;
        end else begin
            result_o       = base_result;
            result_valid_o = 1'b1;
        end
    end

endmodule

`resetall
