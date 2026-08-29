`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
 * Decode stage — RV32I + M + C + Zilx indexed loads + Zicsr CSR ops.
 *
 * Consumes the A/D register as one ad_t bundle (al_i: instr / pc / valid /
 * fault / is_compressed — `al_` is align_stage's sigil; the A/D register is
 * align_stage's output, so this input takes the producer's sigil) and
 * produces a D/E control word (de_o) latched into a D/E register. The
 * register file is read asynchronously from this stage so operands are
 * captured at decode. de_o feeds the execute stage, which drives the
 * reg-file write port (ALU/PC4/load/old-CSR writeback), the CSR file RMW,
 * the fetch redirect, and decode's stall/flush.
 *
 * Each pipeline stage exposes the PC it is treating, the instruction word,
 * and a valid as outputs (prefixed by its stage sigil: fe = fetch,
 * al = align, de = decode, ex = execute). Further debug signals are added
 * on demand. Decode's output is the D/E register (de_o); the CPU top
 * exposes de_pc / de_instr / de_valid as taps.
 *
 * WHAT THIS STAGE NO LONGER DOES (2026-08-28, 3-stage -> 4-stage split).
 * Instruction *alignment and expansion* moved out to align_stage.sv: the
 * depth-8 buffer read mux, the RVC hold buffer, both spanning stitches
 * (sequential and same-cycle branch-target), and c_expand() itself. Decode
 * is now a pure consumer of ONE registered, already-expanded 32-bit word.
 * That was a timing change, and align_stage.sv carries the measurements and
 * the reasoning; the short version is that RVC expansion + decode + regfile
 * read + forward mux all sat in one cycle at 14 logic levels, and the
 * expansion half of it is now a stage earlier.
 *
 * The split deliberately sits BEFORE decode, not between decode and the
 * regfile read, so **decode and execute stay adjacent and the distance-1
 * execute -> decode forward path is unchanged**. No new hazard distance, no
 * new interlock. The alternative boundary (decode | operand-fetch) would
 * have shortened the regfile-side paths too, but at the cost of forwarding
 * to two stages at two distances.
 *
 * Strategy: **decode uniformly**. Whatever arrived — a native 32-bit
 * instruction or a c_expand()ed RVC one — is decoded by one decoder. The
 * only residue of compression here is al_i.is_compressed, which sets the
 * instruction size for pc_link / mepc.
 *
 * stall_o feeds align_stage's stall_i and is now a pure pass-through of
 * execute's stall_i (DIV/REM busy / mem-wait / CSR-wait): the
 * compressed-upper hold that used to add a resource_stall term here went
 * with the hold buffer. RAW hazards are NOT a source of back-pressure:
 * execute-to-decode forwarding (fwd_rs1/fwd_rs2, see below) resolves
 * same-cycle RAW at decode without stalling fetch or bubbling D/E.
 *
 * Decoded opcodes that ride the D/E register to execute:
 *   OPC_AMO with Zilx funct5 (10010 unscaled / 11010 scaled) -> indexed-load
 *     control (mem_read, ALU_LX effective address, WB_MEM). rs1=index,
 *     rs2=base (roles swapped vs base loads). Real AMOs (other funct5) and
 *     RV64-only encodings (funct5=11110, funct3=011/110) decode to illegal.
 *   OPC_SYSTEM funct3!=0 -> Zicsr CSR op (CSRRW/S/C + immediate variants):
 *     csr_op / csr_wren / csr_addr, reg_write=1, wb_src=WB_CSR (rd<-old
 *     CSR). The ALU result is unused for CSR ops; execute does the RMW.
 *     Immediate variants carry zimm in imm ({27'b0,rs1_field}, uses_rs1=0);
 *     register variants uses_rs1=1. csr_wren is decode's op-present flag
 *     (squashed by dec_illegal); execute qualifies the actual write.
 *
 * Deferred opcodes (decode to illegal=1, not executed this phase):
 *   OPC_MISC_MEM (fence / fence.i — Zifencei),
 *   OPC_SYSTEM funct3=0 (ecall / ebreak / mret / wfi — no trap machinery),
 *   atomics / any unknown opcode.
 *
 * Naming: ports *_i/_o; internal signals no prefix; flops _q, next-state
 * _d. Module instances keep u_*.
 */

module decode_stage #(
    // Branch-prediction enable. 1 = predict at decode (gshare PHT direction +
    // direct pc+imm target + RAS returns); 0 = emit no predictions (de_d.pred_*
    // zeroed, no predicted redirect) so execute resolves every control-flow
    // instruction exactly as before the predictor existed — the A/B baseline
    // and a safety fallback. The predictor block may stay instantiated.
    parameter int BP_EN = 1
) (
    input wire clk_i,
    input wire rstn_i,

    // ---- A/D pipeline register in (from align_stage), one ad_t bundle ----
    // A registered, already-RVC-expanded 32-bit instruction: instr / pc /
    // valid / fault / is_compressed. The buffer read mux, the hold buffer,
    // both spanning stitches and c_expand() all live in align_stage now, so
    // decode is a pure consumer of one 32-bit word and its PC — it cannot
    // tell a compressed instruction from a native one except through
    // .is_compressed (instruction size, for pc_link and mepc). .fault means
    // the instruction could not be fetched (PC outside the implemented
    // I-mem): there is no word to decode, and it becomes a precise trap with
    // that PC as mtval. See align_stage.sv for why the split exists and what
    // it costs.
    input ad_t al_i,

    // Register-file read port (decode drives addresses; data returns
    // combinationally the same cycle).
    output wire [     4:0] rs1_addr_o,
    output wire [     4:0] rs2_addr_o,
    input  wire [XLEN-1:0] rs1_data_i,
    input  wire [XLEN-1:0] rs2_data_i,

    // Back-pressure from execute (DIV/REM stall) and a branch redirect.
    input wire stall_i,
    input wire flush_i,

    // Execute writeback observation for the forward path: when execute
    // retires a register write this cycle (ex_wb_en_i) to a destination
    // (ex_wb_addr_i, ex_wb_data_i) that the instruction being decoded
    // reads, decode forwards the fresh value straight into the D/E
    // operands instead of the stale async regfile read (see fwd_rs1 /
    // fwd_rs2 below) — zero bubble, no D/E bubble and no F/D hold.
    input wire            ex_wb_en_i,
    input wire [     4:0] ex_wb_addr_i,
    // Execute writeback data: same cycle as ex_wb_en_i/ex_wb_addr_i,
    // qualified by result_ready (valid on ALU, DIV-done, or load-done).
    input wire [XLEN-1:0] ex_wb_data_i,

    // Back-pressure to align_stage. Decode has no resource stall of its own
    // any more (the RVC hold buffer moved to align_stage), so this is
    // execute's back-pressure passed through; align_stage adds its own term
    // and passes the result to fetch.
    output wire stall_o,

    // Branch-predictor lookup. Decode queries the predictor for the
    // control-flow instruction in the A/D register: the PC (gshare index base
    // and RAS-key identity), whether it is a conditional branch (consult the
    // PHT for direction), and whether it is a JALR return (consult the RAS for
    // the target). The predictor answers combinationally off its flops (PC +
    // GHR only — no register data, so this stays off the regfile -> forward ->
    // compare critical path). Decode builds the prediction from the answer +
    // the direct pc+imm target it computes itself.
    output wire bp_lookup_req_t bp_lookup_o,
    input  wire bp_lookup_rsp_t bp_lookup_i,

    // Predicted redirect. Asserted the cycle a control-flow instruction in
    // the A/D register is consumed into de_d AND predicted taken. It steers
    // fetch to pred_target and kills the wrong-path entries behind the
    // branch: the fetch buffer, the align stage's A/D flop AND its RVC stash
    // (align_stage's pred_flush_i) — all three hold wrong-path state.
    // Lower priority than execute's redirect (trap / mret / interrupt /
    // mispredict), which flushes decode (flush_i) and overrides this.
    output wire            pred_redirect_valid_o,
    output wire [XLEN-1:0] pred_redirect_addr_o,

    // D/E pipeline register output: the full decoded control word, consumed
    // by the execute stage.
    output de_t de_o,

    // de_* per-stage taps (D/E register): the PC / instruction word / valid
    // decode is treating. Exposed like fetch's fe_*_o so every pipeline stage
    // has a uniform pc / instr / valid output (these are fields of de_o,
    // broken out as named ports so the stage boundary shows them even when
    // nothing downstream reads the full struct).
    output wire [XLEN-1:0] de_pc_o,     // D/E instruction PC
    output wire [XLEN-1:0] de_instr_o,  // 32-bit word decode treated
    output wire            de_valid_o   // D/E valid
);

    // =================================================================
    // A/D register aliases
    //
    // The decoder body was written against src_instr32 / src_pc /
    // src_is_compressed / decoded_valid / fetch_fault when it also owned the
    // buffer mux, the hold buffer and c_expand(). Those all moved to
    // align_stage (2026-08-28); these aliases keep the body reading the same
    // names, now sourced from the A/D register instead of computed here. That
    // is the whole point of the boundary: decode is a pure consumer of one
    // registered 32-bit word.
    //
    // al_i.fault is already qualified (align asserts it only when a fault
    // entry was actually present, and al_i.valid is high in that case), so
    // fetch_fault needs no extra gate.
    // =================================================================
    wire [31:0] src_instr32 = al_i.instr;
    wire [31:0] src_pc = al_i.pc;
    wire src_is_compressed = al_i.is_compressed;
    wire decoded_valid = al_i.valid;
    wire fetch_fault = al_i.fault;

    // =================================================================
    // D/E pipeline register
    // =================================================================
    de_t de_q, de_d, de_next;

    // =================================================================
    // RAW hazard resolution (execute -> decode forwarding)
    //
    // Replaces the former stall-on-RAW bubble interlock. Decode's live
    // combinational source addresses (rs1_addr_dec / rs2_addr_dec, forced
    // to x0 when unused, so an unused source can never match) are compared
    // against execute's retiring writeback destination. When execute
    // retires a writeback this cycle (ex_wb_en_i) to a register the decoded
    // instruction reads, the fresh value is forwarded straight into the
    // D/E operands instead of the stale async regfile read (see fwd_rs1 /
    // fwd_rs2 below) — zero bubble, no D/E bubble and no F/D hold. The
    // legacy raw_haz bubble logic is retained commented-out below for
    // reference; it is no longer in the stall_o term.
    // =================================================================
    // (legacy, DISABLED) RAW hazard bubble interlock — replaced by
    // fwd_rs1/fwd_rs2 forwarding. Kept for reference.
    // =================================================================
    //logic raw_haz;
    //assign raw_haz = decoded_valid & ~flush_i & ex_wb_en_i & (ex_wb_addr_i != 5'd0) &
    //    ((rs1_addr_dec != 5'd0 & rs1_addr_dec == ex_wb_addr_i) |
    //     (rs2_addr_dec != 5'd0 & rs2_addr_dec == ex_wb_addr_i));

    // =================================================================
    // RAW forwarding (execute -> decode)
    //
    // Bypasses the regfile write-then-read: when execute retires a
    // writeback this cycle to a register the instruction being decoded
    // reads, inject ex_wb_data_i directly instead of the stale async
    // read. Covers DIV/REM and load results too — wb_en_o/wb_data_o
    // are qualified by result_ready in execute, so they're valid
    // exactly the cycle the result is ready, and decode is already
    // parked (stall_i) through the whole busy/wait window. No bubble.
    // =================================================================
    wire fwd_rs1 = ex_wb_en_i & (ex_wb_addr_i != 5'd0) & (rs1_addr_dec == ex_wb_addr_i);
    wire fwd_rs2 = ex_wb_en_i & (ex_wb_addr_i != 5'd0) & (rs2_addr_dec == ex_wb_addr_i);

`ifdef VERILATOR
    // Sim-only: count the distance-1 RAW forwards that are actually CONSUMED
    // (~stall & ~flush, the same qualifier ret_consume uses -- fwd_rs* are
    // held levels, so a forward waiting out an execute stall must not be
    // counted once per waiting cycle).
    //
    // This is the price list for a writeback stage. Registering alu_result
    // would force forwarding from alu_result_q (post-flop, distance 2), so
    // every one of these events becomes a 1-cycle bubble: after one bubble
    // the producer sits in W and the forward works. Read this counter against
    // retires to get the CPI the W stage would add.
    wire fwd_consume = (fwd_rs1 | fwd_rs2) & ~stall_i & ~flush_i;
    longint unsigned fwd_d1_q;
    always_ff @(posedge clk_i) begin
        if (!rstn_i) fwd_d1_q <= 64'd0;
        else if (fwd_consume) fwd_d1_q <= fwd_d1_q + 64'd1;
    end
`endif

    wire [XLEN-1:0] rs1_fwd = fwd_rs1 ? ex_wb_data_i : rs1_data_i;
    wire [XLEN-1:0] rs2_fwd = fwd_rs2 ? ex_wb_data_i : rs2_data_i;

    logic [4:0] rs1_addr_dec;
    logic [4:0] rs2_addr_dec;
    logic [11:0] csr_addr_dec;

    // ---- Field extraction ----
    logic [6:0] opcode;
    logic [2:0] funct3;
    logic [4:0] funct5;  // AMO/Zilx mode (instr[31:27])
    logic [6:0] funct7;
    logic funct7b5;  // funct7[5] — SUB/SRA, M-ext
    logic [11:0] funct12;
    logic aq, rl;  // AMO ordering bits (instr[26:25]) — must be 0 for Zilx
    logic [4:0] rd_field, rs1_field, rs2_field;
    logic is_m_ext;

    // ---- Immediates (sign-extended) ----
    logic [31:0] imm_i, imm_s, imm_b, imm_u, imm_j;

    // ---- Decoded control (defaults; recognised opcodes override) ----
    logic [31:0] imm;
    logic uses_rs1, uses_rs2;
    logic       reg_write;
    logic       csr_wren;
    alu_op_t    alu_op;
    alu_src_a_t alu_src_a;
    alu_src_b_t alu_src_b;
    logic mem_read, mem_write;
    mem_size_t            mem_size;
    logic                 mem_unsigned;
    logic      [     1:0] mem_shamt;  // Zilx index scale (0 unscaled, log2 size scaled)
    wb_src_t              wb_src;
    branch_t              branch_type;
    logic                 dec_illegal;
    logic                 is_csr;
    csr_op_t              csr_op;
    sys_op_t              sys_op;
    logic                 exc_req;  // decode requests a sync trap
    logic      [XLEN-1:0] exc_cause;
    logic      [XLEN-1:0] exc_tval;

    // ---- Branch-prediction (prediction-at-decode) ----
    // Control-flow classification off the already-decoded branch_type + rd/rs1
    // fields (no register data). is_return = JALR reading a link register
    // (x1/x5) with rd=x0. The direct pc+imm target is computed for JAL and
    // conditional branches (both PC-relative); JALR targets are rs1+imm
    // (data-dependent) so they are not predicted here -- returns use the RAS,
    // calls/indirect fall to execute (a call still pushes the RAS at resolve,
    // where execute re-derives the kind from branch_type/rd).
    logic is_cf, is_cond_cf, is_return_cf;
    logic                    pred_valid;
    logic                    pred_taken;
    logic         [XLEN-1:0] pred_target;
    pred_source_t            pred_source;
    logic         [     5:0] pred_pht_index;
    logic         [XLEN-1:0] pred_dir_target;  // src_pc + imm (PC-relative target)

    // Zilx indexed-load decode helpers (OPC_AMO). Hoisted to module scope
    // and driven with a default every cycle in the decode always_comb below:
    // declaring them inside the OPC_AMO case branch and assigning them only
    // there made GowinSynthesis infer a latch (EX2420/EX3101) — they "held"
    // when any other opcode ran. Defaults at the top of the always_comb kill
    // the latch; the OPC_AMO branch overrides zilx_ok to 1 when the encoding
    // is a valid RV32 Zilx indexed load.
    logic is_unscaled, is_scaled;
    logic size_ok_rv32;
    logic zilx_ok;

    // =================================================================
    // Uniform 32-bit decode (one always_comb). The source-selection half of
    // this block -- buffer read mux, RVC hold buffer, both spanning stitches,
    // c_expand() -- moved to align_stage (2026-08-28); what remains starts
    // from the A/D register and decodes one 32-bit word.
    // =================================================================
    always_comb begin
        // ---- Field extraction ----
        opcode = src_instr32[6:0];
        funct3 = src_instr32[14:12];
        funct7 = src_instr32[31:25];
        funct7b5 = src_instr32[30];
        funct5 = src_instr32[31:27];  // AMO/Zilx mode
        funct12 = src_instr32[31:20];
        aq = src_instr32[26];  // AMO aq (must be 0 for Zilx)
        rl = src_instr32[25];  // AMO rl (must be 0 for Zilx)
        rd_field = src_instr32[11:7];
        rs1_field = src_instr32[19:15];
        rs2_field = src_instr32[24:20];
        is_csr = (opcode == OPC_SYSTEM) && (funct3 != 3'b000);
        is_m_ext = (opcode == OPC_OP) && (funct7 == 7'b0000001);

        // ---- Immediates (sign-extended) ----
        imm_i = {{20{src_instr32[31]}}, src_instr32[31:20]};
        imm_s = {{20{src_instr32[31]}}, src_instr32[31:25], src_instr32[11:7]};
        imm_b = {
            {19{src_instr32[31]}},
            src_instr32[31],
            src_instr32[7],
            src_instr32[30:25],
            src_instr32[11:8],
            1'b0
        };
        imm_u = {src_instr32[31:12], 12'b0};
        imm_j = {
            {11{src_instr32[31]}},
            src_instr32[31],
            src_instr32[19:12],
            src_instr32[20],
            src_instr32[30:21],
            1'b0
        };

        // ---- Decoded control defaults (recognised opcodes override) ----
        imm = 32'd0;
        uses_rs1 = 1'b0;
        uses_rs2 = 1'b0;
        reg_write = 1'b0;
        csr_wren = 1'b0;
        csr_op = CSR_NONE;
        alu_op = ALU_ADD;
        alu_src_a = ALU_A_RS1;
        alu_src_b = ALU_B_IMM;
        mem_read = 1'b0;
        mem_write = 1'b0;
        mem_size = MS_W;
        mem_unsigned = 1'b0;
        mem_shamt = 2'd0;
        wb_src = WB_ALU;
        branch_type = BR_NONE;
        dec_illegal = 1'b1;  // default: anything not matched is illegal
        sys_op = SYS_NONE;
        exc_req = 1'b0;
        exc_cause = '0;
        exc_tval = '0;
        // Zilx helpers: assigned here so every opcode path drives them (no
        // latch). Only OPC_AMO below reads/overrides zilx_ok.
        is_unscaled = (funct5 == 5'b10010);  // lx  (unscaled)
        is_scaled = (funct5 == 5'b11010);  // lxs (scaled)
        size_ok_rv32 = (funct3 inside {3'b000, 3'b001, 3'b010, 3'b100, 3'b101});
        zilx_ok = 1'b0;

        unique case (opcode)
            OPC_LUI: begin
                reg_write   = 1'b1;
                alu_op      = ALU_ADD;
                alu_src_a   = ALU_A_RS1;  // rs1 forced to x0 -> 0
                alu_src_b   = ALU_B_IMM;
                wb_src      = WB_ALU;
                imm         = imm_u;
                dec_illegal = 1'b0;
            end
            OPC_AUIPC: begin
                reg_write   = 1'b1;
                alu_op      = ALU_ADD;
                alu_src_a   = ALU_A_PC;
                alu_src_b   = ALU_B_IMM;
                wb_src      = WB_ALU;
                imm         = imm_u;
                dec_illegal = 1'b0;
            end
            OPC_JAL: begin
                reg_write   = 1'b1;
                alu_op      = ALU_ADD;
                alu_src_a   = ALU_A_PC;
                alu_src_b   = ALU_B_PC4;
                wb_src      = WB_PC4;
                branch_type = BR_JAL;
                imm         = imm_j;
                dec_illegal = 1'b0;
            end
            OPC_JALR: begin
                if (funct3 == 3'b000) begin
                    reg_write   = 1'b1;
                    alu_op      = ALU_ADD;
                    alu_src_a   = ALU_A_RS1;
                    alu_src_b   = ALU_B_IMM;
                    wb_src      = WB_PC4;
                    branch_type = BR_JALR;
                    uses_rs1    = 1'b1;
                    imm         = imm_i;
                    dec_illegal = 1'b0;
                end
            end
            OPC_BRANCH: begin
                alu_op    = ALU_SUB;  // placeholder; branch resolves in execute
                alu_src_a = ALU_A_RS1;
                alu_src_b = ALU_B_RS2;
                uses_rs1  = 1'b1;
                uses_rs2  = 1'b1;
                imm       = imm_b;
                unique case (funct3)
                    3'b000: begin
                        branch_type = BR_BEQ;
                        dec_illegal = 1'b0;
                    end
                    3'b001: begin
                        branch_type = BR_BNE;
                        dec_illegal = 1'b0;
                    end
                    3'b100: begin
                        branch_type = BR_BLT;
                        dec_illegal = 1'b0;
                    end
                    3'b101: begin
                        branch_type = BR_BGE;
                        dec_illegal = 1'b0;
                    end
                    3'b110: begin
                        branch_type = BR_BLTU;
                        dec_illegal = 1'b0;
                    end
                    3'b111: begin
                        branch_type = BR_BGEU;
                        dec_illegal = 1'b0;
                    end
                    default: ;  // funct3 010/011 reserved -> illegal
                endcase
            end
            OPC_LOAD: begin
                reg_write = 1'b1;
                alu_op    = ALU_ADD;  // base + offset
                alu_src_a = ALU_A_RS1;
                alu_src_b = ALU_B_IMM;
                wb_src    = WB_MEM;
                mem_read  = 1'b1;
                uses_rs1  = 1'b1;
                imm       = imm_i;
                unique case (funct3)
                    3'b000: begin
                        mem_size     = MS_B;
                        mem_unsigned = 1'b0;
                        dec_illegal  = 1'b0;
                    end  // lb
                    3'b001: begin
                        mem_size     = MS_H;
                        mem_unsigned = 1'b0;
                        dec_illegal  = 1'b0;
                    end  // lh
                    3'b010: begin
                        mem_size     = MS_W;
                        mem_unsigned = 1'b0;
                        dec_illegal  = 1'b0;
                    end  // lw
                    3'b100: begin
                        mem_size     = MS_B;
                        mem_unsigned = 1'b1;
                        dec_illegal  = 1'b0;
                    end  // lbu
                    3'b101: begin
                        mem_size     = MS_H;
                        mem_unsigned = 1'b1;
                        dec_illegal  = 1'b0;
                    end  // lhu
                    default: ;  // 011/110/111 reserved (RV32) -> illegal
                endcase
            end
            OPC_STORE: begin
                alu_op    = ALU_ADD;  // base + offset
                alu_src_a = ALU_A_RS1;
                alu_src_b = ALU_B_IMM;
                mem_write = 1'b1;
                uses_rs1  = 1'b1;
                uses_rs2  = 1'b1;
                imm       = imm_s;
                unique case (funct3)
                    3'b000: begin
                        mem_size    = MS_B;
                        dec_illegal = 1'b0;
                    end  // sb
                    3'b001: begin
                        mem_size    = MS_H;
                        dec_illegal = 1'b0;
                    end  // sh
                    3'b010: begin
                        mem_size    = MS_W;
                        dec_illegal = 1'b0;
                    end  // sw
                    default: ;  // RV32 has no sd -> illegal
                endcase
            end
            OPC_OP_IMM: begin
                reg_write   = 1'b1;
                alu_src_a   = ALU_A_RS1;
                alu_src_b   = ALU_B_IMM;
                uses_rs1    = 1'b1;
                imm         = imm_i;
                dec_illegal = 1'b0;
                unique case (funct3)
                    3'b000:  alu_op = ALU_ADD;  // addi
                    3'b010:  alu_op = ALU_SLT;  // slti
                    3'b011:  alu_op = ALU_SLTU;  // sltiu
                    3'b100:  alu_op = ALU_XOR;  // xori
                    3'b110:  alu_op = ALU_OR;  // ori
                    3'b111:  alu_op = ALU_AND;  // andi
                    3'b001: begin  // slli — funct7 must be 0000000
                        alu_op = ALU_SLL;
                        if (funct7 != 7'b0000000) dec_illegal = 1'b1;
                    end
                    3'b101: begin  // srli / srai — funct7 0000000 or 0100000
                        alu_op = funct7b5 ? ALU_SRA : ALU_SRL;
                        if (funct7 != 7'b0000000 && funct7 != 7'b0100000) dec_illegal = 1'b1;
                    end
                    default: dec_illegal = 1'b1;
                endcase
            end
            OPC_OP: begin
                reg_write   = 1'b1;
                alu_src_a   = ALU_A_RS1;
                alu_src_b   = ALU_B_RS2;
                uses_rs1    = 1'b1;
                uses_rs2    = 1'b1;
                dec_illegal = 1'b0;
                if (is_m_ext) begin
                    unique case (funct3)
                        3'b000:  alu_op = ALU_MUL;
                        3'b001:  alu_op = ALU_MULH;
                        3'b010:  alu_op = ALU_MULHSU;
                        3'b011:  alu_op = ALU_MULHU;
                        3'b100:  alu_op = ALU_DIV;
                        3'b101:  alu_op = ALU_DIVU;
                        3'b110:  alu_op = ALU_REM;
                        3'b111:  alu_op = ALU_REMU;
                        default: dec_illegal = 1'b1;
                    endcase
                end else begin
                    unique case (funct3)
                        3'b000:  alu_op = funct7b5 ? ALU_SUB : ALU_ADD;  // add/sub
                        3'b001:  alu_op = ALU_SLL;  // sll
                        3'b010:  alu_op = ALU_SLT;  // slt
                        3'b011:  alu_op = ALU_SLTU;  // sltu
                        3'b100:  alu_op = ALU_XOR;  // xor
                        3'b101:  alu_op = funct7b5 ? ALU_SRA : ALU_SRL;  // srl/sra
                        3'b110:  alu_op = ALU_OR;  // or
                        3'b111:  alu_op = ALU_AND;  // and
                        default: dec_illegal = 1'b1;
                    endcase
                    // Base R-type: funct7 must be 0000000 (or 0100000 for
                    // sub/sra, allowed above). Anything else is illegal.
                    if (funct7 != 7'b0000000 && funct7 != 7'b0100000) dec_illegal = 1'b1;
                end
            end
            OPC_AMO: begin
                // Zilx indexed loads (AMO opcode). Encoding:
                //   funct5=[31:27] mode, aq=[26]/rl=[25] (must be 0),
                //   rs2=[24:20]=base, rs1=[19:15]=index, funct3=[14:12]
                //   size/sign, rd=[11:7]. rs1=index, rs2=base — roles
                //   swapped vs base loads. EA = base + (index << shamt),
                //   computed in the ALU (ALU_LX); the load itself is the
                //   LSU's job (mem_read / WB_MEM) — not present yet, so
                //   control rides the D/E register to the debug taps.
                //   Real AMOs (funct5 not in the Zilx set) and RV64-only
                //   encodings decode to illegal=1 this phase.
                // is_unscaled / is_scaled / size_ok_rv32 / zilx_ok default
                // are set at the top of this always_comb (no latch —
                // declaring them here and assigning only in this branch
                // made GowinSynthesis infer a latch, EX2420/EX3101).
                // funct5 == 5'b11110 (lxsuw) is RV64-only -> illegal on RV32.

                // funct3 -> access size/sign (same map as OPC_LOAD).
                unique case (funct3)
                    3'b000: begin
                        mem_size     = MS_B;
                        mem_unsigned = 1'b0;
                    end
                    3'b001: begin
                        mem_size     = MS_H;
                        mem_unsigned = 1'b0;
                    end
                    3'b010: begin
                        mem_size     = MS_W;
                        mem_unsigned = 1'b0;
                    end
                    3'b100: begin
                        mem_size     = MS_B;
                        mem_unsigned = 1'b1;
                    end
                    3'b101: begin
                        mem_size     = MS_H;
                        mem_unsigned = 1'b1;
                    end
                    default: begin
                        mem_size     = MS_W;
                        mem_unsigned = 1'b0;
                    end
                    // 3'b011 / 3'b110 (RV64) and 3'b111 -> reserved
                endcase
                if (aq || rl) begin
                    // aq/rl reserved -> illegal (zilx_ok stays 0 from default)
                end else if (is_unscaled) begin
                    // lx: no unscaled byte (funct3[1:0]==00); RV64 sizes reserved.
                    if (size_ok_rv32 && funct3[1:0] != 2'b00) begin
                        zilx_ok   = 1'b1;
                        mem_shamt = 2'd0;  // unscaled
                    end
                end else if (is_scaled) begin
                    // lxs: byte/half/word, signed/unsigned all valid on RV32.
                    if (size_ok_rv32) begin
                        zilx_ok = 1'b1;
                        case (mem_size)
                            MS_B: mem_shamt = 2'd0;
                            MS_H: mem_shamt = 2'd1;
                            MS_W: mem_shamt = 2'd2;
                            default: mem_shamt = 2'd0;
                        endcase
                    end
                end
                // else: funct5=11110 (RV64) or real AMO -> illegal.

                if (zilx_ok) begin
                    dec_illegal = 1'b0;
                    reg_write   = 1'b1;
                    mem_read    = 1'b1;
                    alu_op      = ALU_LX;
                    alu_src_a   = ALU_A_RS2;  // base (rs2)
                    alu_src_b   = ALU_B_RS1;  // index (rs1); ALU_LX applies <<shamt
                    uses_rs1    = 1'b1;  // index
                    uses_rs2    = 1'b1;  // base
                    imm         = 32'd0;
                    wb_src      = WB_MEM;
                end
            end

            OPC_SYSTEM: begin
                uses_rs2 = 1'b0;  // CSR ops never read rs2
                // Zicsr CSR ops (funct3 != 0) + ecall/ebreak/mret/wfi
                // (funct3 == 0). Only the CSR ops execute this phase; the
                // trap-entry ops stay illegal (no trap machinery yet).
                //
                // RV32 Zicsr:
                //   funct3=001 CSRRW   rd <- csr; csr <- rs1
                //   funct3=010 CSRRS   rd <- csr; csr <- csr |  rs1
                //   funct3=011 CSRRC   rd <- csr; csr <- csr & ~rs1
                //   funct3=101 CSRRWI  rd <- csr; csr <- zimm
                //   funct3=110 CSRRSI  rd <- csr; csr <- csr |  zimm
                //   funct3=111 CSRRCI  rd <- csr; csr <- csr & ~zimm
                //
                // rd always receives the OLD csr value (WB_CSR); the
                // RMW side effect is computed in execute (csr_wdata_o /
                // csr_wren_o). CSRRS/CSRRC with rs1==0 (and CSRRSI/CSRRCI
                // with zimm==0) do NOT write the CSR — execute gates the
                // write; CSRRW always writes. decode only flags the op
                // (csr_wren=1, csr_op, csr_addr); the dec_illegal squash
                // below clears csr_wren for non-CSR / illegal encodings.
                // The ALU result is unused for CSR ops (wb_src=WB_CSR,
                // csr_wdata computed in execute), so no alu_src/alu_op
                // override is needed — defaults leave alu_result_valid=1
                // (combinational), which retires the op in one cycle.
                if (is_csr) begin
                    reg_write   = 1'b1;  // rd <- old CSR value
                    wb_src      = WB_CSR;
                    csr_wren    = 1'b1;  // execute qualifies the actual write
                    dec_illegal = 1'b0;
                    unique case (funct3)
                        3'b001: begin  // CSRRW
                            csr_op   = CSR_RW;
                            uses_rs1 = 1'b1;
                        end
                        3'b010: begin  // CSRRS
                            csr_op   = CSR_RS;
                            uses_rs1 = 1'b1;
                        end
                        3'b011: begin  // CSRRC
                            csr_op   = CSR_RC;
                            uses_rs1 = 1'b1;
                        end
                        3'b101: begin  // CSRRWI  (zimm = instr[19:15])
                            csr_op = CSR_RWI;
                            imm    = {27'b0, rs1_field};  // zimm, zero-extended
                        end
                        3'b110: begin  // CSRRSI
                            csr_op = CSR_RSI;
                            imm    = {27'b0, rs1_field};
                        end
                        3'b111: begin  // CSRRCI
                            csr_op = CSR_RCI;
                            imm    = {27'b0, rs1_field};
                        end
                        default: dec_illegal = 1'b1;  // unreachable (is_csr => funct3!=0)
                    endcase
                end else begin
                    // Trap-entry / return / halt ops (funct3 == 0). Retire
                    // with side effects handled in execute (redirect + CSR
                    // writes via the trap unit); NOT marked illegal. ecall/
                    // ebreak raise a sync trap (exc_req=1) the cycle they
                    // retire; mret/wfi are legal no-side-eff at decode.
                    // SFENCE.VMA (no VM) stays illegal -> traps as illegal.
                    if (funct12 == 12'h000) begin  // ECALL -> env call from M-mode
                        sys_op      = SYS_ECALL;
                        dec_illegal = 1'b0;
                        exc_req     = 1'b1;
                        exc_cause   = MCAUSE_ECALL_M;
                        exc_tval    = '0;
                    end else if (funct12 == 12'h001) begin  // EBREAK -> breakpoint
                        sys_op      = SYS_EBREAK;
                        dec_illegal = 1'b0;
                        exc_req     = 1'b1;
                        exc_cause   = MCAUSE_BREAKPOINT;
                        exc_tval    = '0;
                    end else if (funct7 == 7'b0001000 && rs2_field == 5'b00101 &&
                                 rs1_field == 5'b00000) begin  // WFI
                        sys_op      = SYS_WFI;
                        dec_illegal = 1'b0;
                    end else if (funct7 == 7'b0011000 && rs2_field == 5'b00010 &&
                                 rs1_field == 5'b00000) begin  // MRET
                        sys_op      = SYS_MRET;
                        dec_illegal = 1'b0;
                    end else if (funct7 == 7'b0001001) begin  // SFENCE.VMA -> illegal (no VM)
                        dec_illegal = 1'b1;
                    end else begin
                        dec_illegal = 1'b1;
                    end
                end
            end

            OPC_MISC_MEM: begin
                // Zifencei: fence (funct3=0) / fence.i (funct3=1). Harvard
                // in-order single-core with no D->I path -> both are legal
                // nops here (no ordering side effect needed). Retire as
                // single-cycle nops (no reg/mem/csr/branch). Other funct3
                // reserved -> illegal.
                unique case (funct3)
                    3'b000: begin  // fence
                        sys_op      = SYS_FENCE;
                        dec_illegal = 1'b0;
                    end
                    3'b001: begin  // fence.i
                        sys_op      = SYS_FENCE_I;
                        dec_illegal = 1'b0;
                    end
                    default: dec_illegal = 1'b1;
                endcase
            end

            default: begin
                // Atomics, unknown opcodes -> illegal (traps as illegal
                // instruction in execute). OPC_SYSTEM / OPC_MISC_MEM are
                // handled above.
                dec_illegal = 1'b1;
            end
        endcase

        // Register-read addresses: force x0 for instrs that don't use
        // rs1/rs2 (avoids reading a bogus field, e.g. LUI's rs1 is imm).
        rs1_addr_dec = uses_rs1 ? rs1_field : 5'd0;
        rs2_addr_dec = uses_rs2 ? rs2_field : 5'd0;
        csr_addr_dec = is_csr ? src_instr32[31:20] : 12'd0;  // CSR index is 12 bits

        // Any illegal (and present) instruction requests an illegal-instr
        // sync trap in execute. ecall/ebreak set exc_req explicitly above
        // (dec_illegal=0); misaligned-access traps are detected in execute
        // (need the EA) and override cause/tval there. Gate on
        // decoded_valid so a span_wait / target_span bubble (no real
        // instruction) does not raise a spurious trap.
        if (dec_illegal && decoded_valid) begin
            exc_req   = 1'b1;
            exc_cause = MCAUSE_ILLEGAL;
            exc_tval  = src_instr32;
        end

        // An access fault overrides the illegal decode of the don't-care
        // word above: there was no instruction to be illegal. mtval is the
        // address that could not be fetched, which is what makes the trap
        // useful -- it names where the pc went.
        if (fetch_fault) begin
            exc_req   = 1'b1;
            exc_cause = MCAUSE_INSTR_ACC;
            exc_tval  = src_pc;
        end

        // ---- Branch prediction (prediction-at-decode) ----
        // Classify the control-flow instruction at the head. branch_type is
        // BR_NONE for a fault (the don't-care word decodes to no opcode) and is
        // squashed to BR_NONE for an illegal below, so is_cf gates both out.
        is_cf = decoded_valid & ~dec_illegal & (branch_type != BR_NONE);
        is_cond_cf = is_cf &
            (branch_type inside {BR_BEQ, BR_BNE, BR_BLT, BR_BGE, BR_BLTU, BR_BGEU});
        is_return_cf = is_cf & (branch_type == BR_JALR) & (rs1_field == 5'd1 || rs1_field == 5'd5) &
            (rd_field == 5'd0);

        // Direct PC-relative target for JAL and conditional branches (imm is
        // imm_j / imm_b respectively, set above). JALR targets are rs1+imm --
        // not PC-relative -- so pred_dir_target is not used for JALR.
        pred_dir_target = src_pc + imm;

        // Build the prediction. pred_valid marks a classified control-flow
        // instruction (records NT predictions and unpredicted JALR for uniform
        // mispredict accounting in execute); pred_taken is the speculated
        // direction; pred_target is the taken target (valid when pred_taken).
        pred_valid = is_cf;
        pred_source = PRED_NONE;
        pred_taken = 1'b0;
        pred_target = '0;
        pred_pht_index = 6'd0;
        if (is_cf) begin
            if (is_return_cf) begin
                // Return: target from the RAS; taken only if the RAS has an
                // entry (else fall back to execute, the legacy path).
                pred_source = PRED_RAS;
                pred_taken  = bp_lookup_i.ras_valid;
                pred_target = bp_lookup_i.ras_top;
            end else if (is_cond_cf) begin
                // Conditional: direction from the gshare PHT, target pc+imm.
                pred_source    = PRED_PHT;
                pred_taken     = bp_lookup_i.pht_taken;
                pred_target    = pred_dir_target;
                pred_pht_index = bp_lookup_i.pht_index;
            end else if (branch_type == BR_JAL) begin
                // Unconditional JAL / c.j / c.jal: always taken, pc+imm.
                pred_source = PRED_DIRECT;
                pred_taken  = 1'b1;
                pred_target = pred_dir_target;
            end
            // JALR call / indirect (JALR, not a return): no target prediction
            // (rs1+imm is data-dependent); pred_taken stays 0 and execute
            // resolves it as before the predictor existed.
        end

        // ---- Assemble the D/E word for this cycle ----
        de_d                 = '0;
        de_d.valid           = decoded_valid;
        de_d.pc              = src_pc;
        de_d.instr           = src_instr32;  // 32-bit word decode treated
        de_d.is_compressed   = src_is_compressed;
        de_d.rs1_addr        = rs1_addr_dec;
        de_d.rs2_addr        = rs2_addr_dec;
        //        de_d.rs1_data      = rs1_data_i;
        //        de_d.rs2_data      = rs2_data_i;
        de_d.rs1_data        = rs1_fwd;
        de_d.rs2_data        = rs2_fwd;
        de_d.imm             = imm;
        de_d.rd              = rd_field;
        de_d.alu_op          = alu_op;
        de_d.alu_src_a       = alu_src_a;
        de_d.alu_src_b       = alu_src_b;
        de_d.mem_size        = mem_size;
        de_d.mem_unsigned    = mem_unsigned;
        de_d.mem_shamt       = mem_shamt;
        de_d.wb_src          = wb_src;
        de_d.branch_type     = branch_type;
        de_d.sys_op          = sys_op;
        de_d.exception       = exc_req;
        de_d.exception_cause = exc_cause;
        de_d.exception_tval  = exc_tval;
        de_d.csr_op          = csr_op;
        de_d.csr_addr        = csr_addr_dec;
        // Branch-prediction metadata. When BP_EN=0 the predictor is disabled:
        // zero the metadata so execute resolves every control-flow instruction
        // exactly as before (pred_valid=0 -> pred_t=0 -> mispredict reduces to
        // the legacy taken-redirect, and no predicted redirect fires).
        de_d.pred_valid      = (BP_EN != 0) & pred_valid;
        de_d.pred_taken      = (BP_EN != 0) & pred_taken;
        de_d.pred_target     = (BP_EN != 0) ? pred_target : '0;
        de_d.pred_source     = (BP_EN != 0) ? pred_source : PRED_NONE;
        de_d.pred_pht_index  = (BP_EN != 0) ? pred_pht_index : 6'd0;
        // reg_write / mem_read / mem_write / csr_wren are squashed by
        // illegal. A spanning stitch decodes a real 32-bit instr through
        // the uniform decoder, so spanning no longer forces illegal.
        if (dec_illegal) begin
            de_d.reg_write   = 1'b0;
            de_d.mem_read    = 1'b0;
            de_d.mem_write   = 1'b0;
            de_d.csr_wren    = 1'b0;
            de_d.branch_type = BR_NONE;
            de_d.illegal     = decoded_valid;  // illegal=1 only when a word was present
        end else begin
            de_d.reg_write = reg_write;
            de_d.mem_read  = mem_read;
            de_d.mem_write = mem_write;
            de_d.csr_wren  = csr_wren;
            de_d.illegal   = 1'b0;
        end
    end

    // =================================================================
    // D/E register next-state
    // =================================================================
    always_comb begin
        if (flush_i) begin
            de_next = '0;
        end else if (stall_i) begin
            de_next = de_q;  // DIV/REM / mem-wait stall: hold
        end else begin
            de_next = de_d;
        end
    end

    // =================================================================
    // Back-pressure to align_stage. Decode holds de_q for exactly the cycles
    // execute cannot accept a new instruction, and has no stall source of its
    // own: the RVC hold buffer, which used to add resource_stall here, moved
    // to align_stage. align_stage ORs in its own resource stall and passes
    // the result to fetch.
    // =================================================================
    assign stall_o                 = stall_i;

    // Branch-predictor lookup outputs (PC only, no register data). The
    // predictor exports the PHT entry and the RAS top unconditionally and the
    // selection above picks between them, so no kind bits are needed. The one
    // extra field is the sim-only return-lookup event, which carries decode's
    // consume condition: bp_lookup_o is a held level, so a return waiting out
    // an execute stall must not be counted once per waiting cycle.
    assign bp_lookup_o.pc          = src_pc;
    assign bp_lookup_o.ret_consume = is_return_cf & ~stall_i & ~flush_i;

    // Predicted redirect: fire the cycle a control-flow instruction in the
    // A/D register is consumed into de_d (~stall_i, ~flush_i) and predicted
    // taken. Gated by BP_EN; lower priority than execute's redirect (a
    // trap/mret/interrupt/mispredict flushes decode via flush_i and overrides).
    // It goes to fetch (kill the buffer, steer pc_q) AND to align_stage as
    // pred_flush_i, because a predicted-taken redirect must also drop the
    // wrong-path instruction sitting in the A/D flop and any stashed RVC half
    // behind the branch — exactly like an execute flush does. The fetch
    // buffer kill reaches neither of those two, and without the align flush
    // the fall-through half after a predicted-taken spanning branch survives
    // the redirect and retires.
    wire pred_redirect_fire = (BP_EN != 0) & is_cf & pred_taken & ~stall_i & ~flush_i;
    assign pred_redirect_valid_o = pred_redirect_fire;
    assign pred_redirect_addr_o  = pred_target;

    // Register-read addresses drive the reg file.
    assign rs1_addr_o            = rs1_addr_dec;
    assign rs2_addr_o            = rs2_addr_dec;

    // D/E output
    assign de_o                  = de_q;

    // de_* per-stage taps (fields of de_o / de_q).
    assign de_pc_o               = de_q.pc;
    assign de_instr_o            = de_q.instr;
    assign de_valid_o            = de_q.valid;

    // =================================================================
    // Sequential
    // =================================================================
    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            de_q <= '0;
        end else begin
            de_q <= de_next;
        end
    end

endmodule

`resetall
