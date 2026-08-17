`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
 * Execute stage (DRAFT) — consumes the D/E control word (de_i) from
 * decode and:
 *
 *   - selects the ALU operands (rs1 / rs2 / pc / imm / pc4 / rs1-shifted)
 *     per de_i.alu_src_a / alu_src_b;
 *   - drives the ALU (base RV32I + M + Zilx EA), launching the
 *     multi-cycle DIV/REM with start_i and stalling the pipe until the
 *     ALU asserts result_valid_o;
 *   - writes back ALU / PC4 results to the register file (loads are the
 *     LSU's job — not present yet, so mem ops do not retire a write);
 *   - resolves branches and redirects fetch (branch_valid_o /
 *     branch_addr_o), flushing decode's D/E register on a taken branch;
 *   - exposes a native mem_req_o / mem_rsp_i port for the future LSU
 *     (wvalid is gated to 0 today, so the peri bridge stays idle).
 *
 * The CPU top used to tie the reg-file write port, the fetch redirect,
 * and decode's stall/flush to inert constants; this stage now drives
 * them. fe_* (fetch) / de_* (decode) / ex_* (execute) taps follow the
 * stage-sigil convention: ex_* is the E/M register — pc / instr / valid
 * of the retired operation.
 *
 * Known DRAFT limitations (TODO):
 *
 *   - No forwarding / hazard unit. Decode's reg-file async read for the
 *     next instruction overlaps the current instruction's writeback
 *     (both resolve at the same posedge), so an instruction that reads
 *     a register written by the immediately preceding instruction sees
 *     the STALE (pre-writeback) value. Add a bypass path or a
 *     stall-on-RAW interlock before relying on dependent sequences.
 *     Single-cycle ALU ops and DIV/REM share this hazard.
 *
 *   - No LSU. Loads / stores / Zilx compute their effective address in
 *     the ALU (mem_req_o.addr = alu_result) but do not launch a request
 *     (wvalid=0) and do not retire a register write, so the pipe never
 *     stalls on the (today tied-off) peri slave. Wire the memory
 *     launch + rsp.rvalid stall + WB_MEM writeback when the LSU lands.
 *
 *   - DIV/REM result is not bypassed (see hazard note): a consumer in
 *     the slot right after the div reads the stale value.
 *
 * Naming: ports *_i/_o; internals no prefix; flops _q/_d; instances u_*.
 */

module execute_stage (
    input wire clk_i,
    input wire rstn_i,

    // D/E control word from decode.
    input de_t de_i,

    // Back-pressure from a future downstream stage (tied 0 now).
    input wire stall_i,

    // Back-pressure to decode: stall the D/E register while a DIV/REM
    // is running (and the launch cycle).
    output wire stall_o,

    // Flush decode's D/E register on a taken branch.
    output wire flush_o,

    // Writeback to the register file. wb_data_o is driven procedurally in
    // the writeback always_comb below, so it must be a variable (logic),
    // not a wire — a wire/net cannot take a procedural assignment
    // (GowinSynthesis EX3900). The assign-driven wb_addr_o / wb_en_o stay
    // wire.
    output wire  [     4:0] wb_addr_o,
    output logic [XLEN-1:0] wb_data_o,
    output wire             wb_en_o,

    // Branch redirect to fetch.
    output wire            branch_valid_o,
    output wire [XLEN-1:0] branch_addr_o,

    // Native memory interface (future LSU). wvalid is gated to 0 today.
    output mem_req_t mem_req_o,
    input  mem_rsp_t mem_rsp_i,

    // ex_* per-stage taps (E/M register): pc / instr / valid of the retired
    // op. Named like fetch's fe_*_o (no _dbg suffix) so every pipeline stage
    // exposes a uniform pc / instr / valid output.
    output wire [XLEN-1:0] ex_pc_o,
    output wire [XLEN-1:0] ex_instr_o,
    output wire            ex_valid_o
);

    // =================================================================
    // Operand selection + PC-link (PC+2 compressed / PC+4)
    // =================================================================
    logic [XLEN-1:0] pc_link;
    assign pc_link = de_i.pc + (de_i.is_compressed ? 32'd2 : 32'd4);

    logic [XLEN-1:0] operand_a, operand_b;

    always_comb begin
        unique case (de_i.alu_src_a)
            ALU_A_RS1: operand_a = de_i.rs1_data;
            ALU_A_PC:  operand_a = de_i.pc;
            ALU_A_RS2: operand_a = de_i.rs2_data;
            default:   operand_a = '0;
        endcase
        unique case (de_i.alu_src_b)
            ALU_B_IMM:    operand_b = de_i.imm;
            ALU_B_RS2:    operand_b = de_i.rs2_data;
            ALU_B_PC4:    operand_b = pc_link;
            ALU_B_ZERO:   operand_b = '0;
            ALU_B_RS1_SH: operand_b = de_i.rs1_data;  // ALU applies shamt_i
            default:      operand_b = '0;
        endcase
    end

    // =================================================================
    // Multi-cycle DIV/REM control
    //
    // EX_IDLE: ready to accept a new op. A DIV/REM is launched (start_i)
    // for one cycle, then EX_BUSY holds the pipe until result_valid_o.
    // The done cycle drops the stall so decode advances and the same
    // div is not relaunched (ex_state_q is still BUSY at done, so
    // alu_start is 0; it clears to IDLE for the next cycle's new de_i).
    // =================================================================
    logic is_div_op;
    assign is_div_op = de_i.alu_op inside {ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU};

    logic is_mem_op;
    assign is_mem_op = de_i.mem_read | de_i.mem_write;

    typedef enum logic {
        EX_IDLE,
        EX_BUSY
    } ex_state_e;
    ex_state_e ex_state_q, ex_state_d;

    logic alu_start;
    assign alu_start = de_i.valid & is_div_op & (ex_state_q == EX_IDLE) & ~stall_i;

    logic            alu_result_valid;
    logic [XLEN-1:0] alu_result;

    logic            div_running;
    assign div_running = (ex_state_q == EX_BUSY) & ~alu_result_valid;
    assign stall_o     = alu_start | div_running | stall_i;

    always_comb begin
        ex_state_d = ex_state_q;
        unique case (ex_state_q)
            EX_IDLE: if (alu_start) ex_state_d = EX_BUSY;
            EX_BUSY: if (alu_result_valid) ex_state_d = EX_IDLE;
            default: ex_state_d = EX_IDLE;
        endcase
    end

    // =================================================================
    // ALU instance
    // =================================================================
    alu u_alu (
        .clk_i         (clk_i),
        .rst_ni        (rstn_i),
        .operand_a_i   (operand_a),
        .operand_b_i   (operand_b),
        .alu_op_i      (de_i.alu_op),
        .shamt_i       (de_i.mem_shamt),
        .start_i       (alu_start),
        .result_valid_o(alu_result_valid),
        .result_o      (alu_result)
    );

    // =================================================================
    // Writeback (ALU / PC4). Mem results need the LSU (not present).
    // =================================================================
    always_comb begin
        unique case (de_i.wb_src)
            WB_ALU:  wb_data_o = alu_result;
            WB_PC4:  wb_data_o = pc_link;
            WB_MEM:  wb_data_o = mem_rsp_i.rdata;  // 0 until the LSU lands
            default: wb_data_o = '0;
        endcase
    end
    assign wb_addr_o = de_i.rd;
    assign wb_en_o = de_i.valid & de_i.reg_write & ~de_i.illegal & ~is_mem_op &
        alu_result_valid & ~stall_i;

    // =================================================================
    // Memory interface (future LSU). The effective address (Zilx indexed
    // or base+offset) is the ALU result. The request is not launched yet
    // (wvalid=0) so the peri bridge stays idle; wire the launch + the
    // rsp.rvalid stall + WB_MEM writeback when the LSU lands.
    // =================================================================
    logic [STRB_WIDTH-1:0] store_wstrb;
    always_comb begin
        // Byte strobes for a store of de_i.mem_size at alu_result.
        unique case (de_i.mem_size)
            MS_B: store_wstrb = 4'b0001 << alu_result[1:0];
            MS_H: store_wstrb = 4'b0011 << {alu_result[1], 1'b0};
            MS_W: store_wstrb = 4'b1111;
            default: store_wstrb = 4'b1111;
        endcase
    end

    always_comb begin
        mem_req_o.wvalid = 1'b0;  // LSU TODO: launch on mem_read/mem_write
        mem_req_o.we     = de_i.mem_write;
        mem_req_o.addr   = alu_result;
        mem_req_o.wdata  = de_i.rs2_data;
        mem_req_o.wstrb  = store_wstrb;
        mem_req_o.rready = 1'b1;  // LSU TODO: from writeback acceptance
    end
    // mem_rsp_i unused until the LSU lands; sink it to keep it clean.
    wire  unused_mem_rsp = mem_rsp_i.wready | mem_rsp_i.rvalid | mem_rsp_i.rdata[0];

    // =================================================================
    // Branch resolve + redirect
    // =================================================================
    logic branch_taken;
    always_comb begin
        unique case (de_i.branch_type)
            BR_BEQ:  branch_taken = (de_i.rs1_data == de_i.rs2_data);
            BR_BNE:  branch_taken = (de_i.rs1_data != de_i.rs2_data);
            BR_BLT:  branch_taken = ($signed(de_i.rs1_data) < $signed(de_i.rs2_data));
            BR_BGE:  branch_taken = ($signed(de_i.rs1_data) >= $signed(de_i.rs2_data));
            BR_BLTU: branch_taken = (de_i.rs1_data < de_i.rs2_data);
            BR_BGEU: branch_taken = (de_i.rs1_data >= de_i.rs2_data);
            BR_JAL:  branch_taken = 1'b1;
            BR_JALR: branch_taken = 1'b1;
            default: branch_taken = 1'b0;  // BR_NONE
        endcase
    end

    assign branch_addr_o = (de_i.branch_type == BR_JALR) ?
        (de_i.rs1_data + de_i.imm) & 32'hFFFF_FFFE : (de_i.pc + de_i.imm);

    // Branches are single-cycle (ALU placeholder op, result_valid=1), so
    // alu_result_valid is always 1 for them; gate on it anyway for safety.
    assign branch_valid_o = de_i.valid & ~de_i.illegal & (de_i.branch_type != BR_NONE) &
        branch_taken & ~stall_i & alu_result_valid;
    assign flush_o = branch_valid_o;

    // =================================================================
    // E/M debug taps (retired instruction)
    // =================================================================
    logic [XLEN-1:0] ex_pc_q, ex_pc_d;
    logic [XLEN-1:0] ex_instr_q, ex_instr_d;
    logic ex_valid_q, ex_valid_d;

    // An op retires when it is valid, not a (non-issueing) mem op, and its
    // result is ready. Single-cycle ops retire the cycle they are valid;
    // DIV/REM retire on alu_result_valid.
    logic op_retires;
    assign op_retires = de_i.valid & ~de_i.illegal & ~is_mem_op & alu_result_valid & ~stall_i;

    assign ex_pc_d    = op_retires ? de_i.pc : ex_pc_q;
    assign ex_instr_d = op_retires ? de_i.instr : ex_instr_q;
    assign ex_valid_d = op_retires;

    assign ex_pc_o    = ex_pc_q;
    assign ex_instr_o = ex_instr_q;
    assign ex_valid_o = ex_valid_q;

    // =================================================================
    // Sequential
    // =================================================================
    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            ex_state_q <= EX_IDLE;
            ex_pc_q    <= '0;
            ex_instr_q <= '0;
            ex_valid_q <= 1'b0;
        end else begin
            ex_state_q <= ex_state_d;
            ex_pc_q    <= ex_pc_d;
            ex_instr_q <= ex_instr_d;
            ex_valid_q <= ex_valid_d;
        end
    end

endmodule

`resetall
