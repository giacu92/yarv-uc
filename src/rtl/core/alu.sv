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
    input logic clk_i,
    input logic rst_ni,

    input logic    [XLEN-1:0] operand_a_i,
    input logic    [XLEN-1:0] operand_b_i,
    input alu_op_t            alu_op_i,
    input logic    [     1:0] shamt_i,      // Zilx index scale (log2 size, 0 unscaled)

    input  logic            start_i,         // impulso: lancia l'op (serve solo per DIV/REM)
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
            // Zilx indexed-load EA. Parentesi obbligatorie: '+' lega più
            // forte di '<<', quindi 'a + b << n' sarebbe '(a+b)<<n'.
            ALU_LX:   base_result = operand_a_i + (operand_b_i << shamt_i);
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
    // DIV/REM — multi-ciclo, restoring division, 32 iterazioni
    // TODO: gestire i case RISC-V-defined per div-by-zero e
    // overflow (INT_MIN / -1) prima di usare div_result.
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
    logic [XLEN-1:0] div_a_q, div_b_q;
    logic div_a_neg_q, div_b_neg_q;
    logic [2*XLEN-1:0] div_rem_q, div_rem_d;  // {remainder, quotient} shift register
    logic [XLEN-1:0] div_divisor_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            div_state_q <= DIV_IDLE;
            div_cnt_q   <= '0;
        end else begin
            div_state_q <= div_state_d;
            div_cnt_q   <= div_cnt_d;
        end
    end

    // operandi unsigned per il core della divisione; il segno si
    // riapplica in uscita per DIV/REM (non per DIVU/REMU)
    logic [XLEN-1:0] div_a_abs, div_b_abs;
    assign div_a_abs = (alu_op_i inside {ALU_DIV, ALU_REM}) && operand_a_i[XLEN-1] ? -operand_a_i :
        operand_a_i;
    assign div_b_abs = (alu_op_i inside {ALU_DIV, ALU_REM}) && operand_b_i[XLEN-1] ? -operand_b_i :
        operand_b_i;

    always_ff @(posedge clk_i) begin
        if (div_state_q == DIV_IDLE && start_i && is_div_op) begin
            div_a_q       <= div_a_abs;
            div_divisor_q <= div_b_abs;
            div_a_neg_q   <= (alu_op_i == ALU_DIV) && (operand_a_i[XLEN-1] ^ operand_b_i[XLEN-1]);
            div_b_neg_q   <= (alu_op_i == ALU_REM) && operand_a_i[XLEN-1];
            div_rem_q     <= {{XLEN{1'b0}}, div_a_abs};
        end else if (div_state_q == DIV_RUN) begin
            // uno shift-subtract per ciclo
            automatic logic [2*XLEN-1:0] shifted;
            automatic logic [  XLEN-1:0] rem_part;
            shifted  = div_rem_q << 1;
            rem_part = shifted[2*XLEN-1:XLEN];
            if (rem_part >= div_divisor_q) begin
                div_rem_q <= {rem_part - div_divisor_q, shifted[XLEN-2:0], 1'b1};
            end else begin
                div_rem_q <= shifted;
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
                else div_cnt_d = div_cnt_q + 1;
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
        unique case (alu_op_i)
            ALU_DIV:
            div_result = (div_b_q == 0) ? '1 : (div_a_neg_q ? -div_quot_raw : div_quot_raw);
            ALU_DIVU: div_result = (div_b_q == 0) ? '1 : div_quot_raw;
            ALU_REM:
            div_result = (div_b_q == 0) ? div_a_q : (div_b_neg_q ? -div_rem_raw : div_rem_raw);
            ALU_REMU: div_result = (div_b_q == 0) ? div_a_q : div_rem_raw;
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
