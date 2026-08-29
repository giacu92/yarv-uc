`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
 * Instruction align + expand stage (A/D) — pipeline stage 2 of 4.
 *
 * Added 2026-08-28 to split the old single fetch->decode stage in two. It
 * owns everything between the fetch buffer and the decoder: the buffer read
 * mux, the RVC hold buffer, both spanning stitches, and c_expand(). Its
 * output is a REGISTERED, already-expanded 32-bit instruction, so the
 * decoder starts at a flop instead of behind an 8:1 LUT-RAM mux plus the
 * RVC expander.
 *
 * WHY (measured, not guessed). The 2026-08-28 timing probes (65 and 100 MHz
 * constraints, which returned bit-identical implementations) put the design
 * at 20.130 ns worst path, Fmax 49.590 MHz, Logic Level 14, TNS -2041.789 ns
 * over 1038 endpoints. Two clusters shared the 25 worst setup paths and were
 * 0.03 ns apart, i.e. the same length:
 *   A (12 of 25, longest 20.100 ns): head_q -> 8:1 buffer mux -> c_expand ->
 *     rs1_addr -> forward compare -> de_bus.rs1_data, and the same prefix
 *     into hold_pc_q / hold_word_q CE and pc_q D (via pred_redirect).
 *   B (13 of 25, longest 20.130 ns): regfile BSRAM DO -> forward mux ->
 *     operand select -> de_bus.rs2_data, plus six DO -> DI writeback-loop
 *     paths and five DO -> mem_wdata_q store-lane paths.
 * Both landed in the same de_bus.* flops because RVC expansion, decode,
 * regfile read and the forward mux all sat in ONE cycle. This stage cuts
 * cluster A's prefix out of that cycle. Cluster B is untouched by design --
 * the two are separate changes so each is measurable, per the same rule that
 * kept the 64-bit fetch and the cache apart.
 *
 * WHAT THIS COSTS. One more stage in front of decode means one extra cycle
 * of refill after every buffer kill, and both a mispredict AND a correct
 * predicted-taken redirect kill the buffer: on CoreMark that is 9319 + 38836
 * = 48155 extra cycles on 584637, about +8% CPI. Against a clock that this
 * is meant to raise, the trade is only worth it if the clock actually moves;
 * measure both. Recovering that 8% is the "hide the predicted-taken refill
 * bubble" item -- fetch into the predicted path instead of killing the
 * buffer -- which this change makes more valuable, not less.
 *
 * WHY THIS BOUNDARY AND NOT DECODE|OPERAND-FETCH. The alternative was to cut
 * after decode, leaving regfile read + forward mux alone in their own stage,
 * which would have shortened BOTH clusters. It was rejected for this round
 * because it moves the forward path: execute would have to forward to the
 * operand stage (distance 1) AND to decode for the addresses (distance 2),
 * needing a new interlock. This boundary sits BEFORE decode, so decode and
 * execute stay adjacent and the distance-1 execute->decode forward is
 * unchanged -- no new hazard, no new interlock.
 *
 * Pipeline contract:
 *   - Consumes the fetch buffer head and head+1 (one fa_t each) exactly as
 *     decode did, and drives fe_pop2_o.
 *   - Produces the A/D register as one ad_t bundle: instr (32-bit, RVC
 *     already expanded), pc (the instruction's own PC), valid, fault (access
 *     fault -- no word exists, decode turns it into a precise trap) and
 *     is_compressed (instruction size, for pc_link / mepc).
 *   - stall_i: decode cannot accept -> hold the output flop, hold the RVC
 *     stash, and back-pressure fetch. stall_o = that, OR this stage's own
 *     resource stall (a compressed-upper half is stashed while a fresh
 *     buffer word is present -- the stash has priority, so fetch must wait).
 *   - flush_i: execute redirect (trap / mret / interrupt / mispredict).
 *     Kills the output flop and the stash.
 *   - pred_flush_i: decode's predicted-taken redirect. The instruction in
 *     the output flop when it fires is the wrong-path one behind the branch,
 *     so it is killed too -- the fetch buffer kill does not reach either the
 *     flop or the stash.
 *
 * Naming: ports *_i/_o; internals no prefix; flops _q, next-state _d. Stage
 * sigil `al_` (fe_ / al_ / de_ / ex_).
 */
module align_stage (
    input wire clk_i,
    input wire rstn_i,

    // ---- F/A register: fetch buffer head, and head+1 for the same-cycle
    // target-span stitch (same fa_t shape) ----
    input  fa_t fe_head_i,
    input  fa_t fe_next_i,
    output wire fe_pop2_o,

    // ---- Back-pressure ----
    input  wire stall_i,  // decode cannot accept
    output wire stall_o,  // to fetch: decode back-pressure or own resource stall

    // ---- Flushes ----
    input wire flush_i,      // execute redirect
    input wire pred_flush_i, // decode's predicted-taken redirect

    // ---- A/D pipeline register: one aligned, expanded instruction ----
    output ad_t al_o
);

    // Field aliases for the F/A inputs. The align/expand body below was
    // written against these names when it lived in decode_stage and read
    // fetch's flat ports; keeping the aliases means the logic that moved is
    // the logic that was already verified, with only its container changed.
    wire [XLEN-1:0] fe_instr_i = fe_head_i.instr;
    wire [XLEN-1:0] fe_pc_i = fe_head_i.pc;
    wire            fe_valid_i = fe_head_i.valid;
    wire            fe_fault_i = fe_head_i.fault;
    wire [XLEN-1:0] fe_next_instr_i = fe_next_i.instr;
    wire [XLEN-1:0] fe_next_pc_i = fe_next_i.pc;
    wire            fe_next_valid_i = fe_next_i.valid;
    wire            fe_next_fault_i = fe_next_i.fault;

    // =================================================================
    // 32-bit instruction builders (used only by c_expand).
    // Each takes a sign-extended 32-bit offset / value and places the
    // immediate bits per the RV32I encoding. Keeping these separate from
    // the main decoder means the decoder is a pure consumer of a 32-bit
    // word, native or expanded.
    // =================================================================
    function automatic logic [31:0] mk_r(input logic [6:0] op, input logic [4:0] rd,
                                         input logic [4:0] rs1, input logic [4:0] rs2,
                                         input logic [2:0] f3, input logic [6:0] f7);
        return {f7, rs2, rs1, f3, rd, op};
    endfunction

    // I-type: imm[11:0] = off[11:0].
    function automatic logic [31:0] mk_i(input logic [6:0] op, input logic [4:0] rd,
                                         input logic [4:0] rs1, input logic [2:0] f3,
                                         input logic [31:0] off);
        return {off[11:0], rs1, f3, rd, op};
    endfunction

    // S-type: imm[11:5]=off[11:5], imm[4:0]=off[4:0].
    function automatic logic [31:0] mk_s(input logic [6:0] op, input logic [4:0] rs1,
                                         input logic [4:0] rs2, input logic [2:0] f3,
                                         input logic [31:0] off);
        return {off[11:5], rs2, rs1, f3, off[4:0], op};
    endfunction

    // B-type: imm[12]=off[12], imm[11]=off[11], imm[10:5]=off[10:5],
    // imm[4:1]=off[4:1], imm[0]=0. off[0] must be 0.
    function automatic logic [31:0] mk_b(input logic [6:0] op, input logic [4:0] rs1,
                                         input logic [4:0] rs2, input logic [2:0] f3,
                                         input logic [31:0] off);
        return {off[12], off[10:5], rs2, rs1, f3, off[4:1], off[11], op};
    endfunction

    // U-type: imm[31:12]=off[31:12].
    function automatic logic [31:0] mk_u(input logic [6:0] op, input logic [4:0] rd,
                                         input logic [31:0] off);
        return {off[31:12], rd, op};
    endfunction

    // J-type: imm[20]=off[20], imm[10:1]=off[10:1], imm[11]=off[11],
    // imm[19:12]=off[19:12], imm[0]=0. off[0] must be 0.
    function automatic logic [31:0] mk_j(input logic [6:0] op, input logic [4:0] rd,
                                         input logic [31:0] off);
        return {off[20], off[10:1], off[11], off[19:12], rd, op};
    endfunction

    // =================================================================
    // c_expand: 16-bit RVC -> 32-bit RV32I equivalent.
    //
    // Returns 32'h0000_0000 for illegal / unsupported compressed
    // encodings. The main decoder treats opcode 0000000 as illegal (no
    // major opcode matches), so a zero word decodes to illegal=1. Legal
    // expansions always produce a recognized 32-bit instruction.
    //
    // Compressed register mapping: crd/crs1/crs2 = {2'b01, 3-bit} -> x8..x15.
    //
    // Verified-by-hand encodings (see sim/program.hex):
    //   c.li   x1,5     -> 0x4095  -> addi x1,x0,5
    //   c.addi x1,1     -> 0x0085  -> addi x1,x1,1
    //   c.j    16        -> 0xA801  -> jal   x0,16
    //   c.lw   x8,4(x9)  -> 0x4180  -> lw    x8,4(x9)
    // The scrambled-immediate forms (c.lwsp/c.swsp/c.addi4spn/
    // c.addi16sp/c.beqz/bnez/c.srli/srai/andi) are implemented per the
    // RISC-V C spec table but pending exhaustive sim verification.
    // =================================================================
    function automatic logic [31:0] c_expand(input logic [15:0] c);
        logic [ 2:0] f3;  // c[15:13]
        logic [ 4:0] rd5;  // c[11:7]  (5-bit register, quad1/quad2)
        logic [ 4:0] crd;  // compressed rd   = {2'b01,c[4:2]}  (x8..x15)
        logic [ 4:0] crs1;  // compressed rs1  = {2'b01,c[9:7]}
        logic [ 4:0] crs2;  // compressed rs2  = {2'b01,c[4:2]}
        logic [ 4:0] rs2_5;  // c[6:2] (5-bit rs2 / shamt, quad2)
        logic [31:0] off;  // sign-extended offset / immediate
        logic [31:0] res;

        res   = 32'h0000_0000;  // default: illegal (decodes to illegal=1)
        f3    = c[15:13];
        rd5   = c[11:7];
        crd   = {2'b01, c[4:2]};
        crs1  = {2'b01, c[9:7]};
        crs2  = {2'b01, c[4:2]};
        rs2_5 = c[6:2];

        unique case (c[1:0])

            // ---------------------------------------------------
            // Quadrant 0 (c[1:0] = 00)
            // ---------------------------------------------------
            2'b00: begin
                unique case (f3)
                    3'b000: begin  // c.addi4spn  -> addi rd', x2, nzuimm
                        // nzuimm[9:6]=c[10:7], [5:4]=c[12:11], [3]=c[5],
                        // [2]=c[6], [1:0]=00. Illegal if nzuimm==0.
                        // (spec nzuimm[5:4|9:6|2|3]=instr[12:11|10:7|6|5];
                        //  bit[2] comes from c[6], bit[3] from c[5].)
                        logic [9:0] nz;
                        nz = {c[10:7], c[12:11], c[5], c[6], 2'b00};
                        if (nz != 10'd0) begin
                            off = {22'b0, nz};
                            res = mk_i(OPC_OP_IMM, crd, 5'd2, 3'b000, off);
                        end
                    end
                    3'b010: begin  // c.lw  -> lw rd', imm(rs1')
                        // offset[6]=c[5], [5:3]=c[12:10], [2]=c[6], [1:0]=00.
                        logic [6:0] lwoff;
                        lwoff = {c[5], c[12:10], c[6], 2'b00};
                        off   = {25'b0, lwoff};
                        res   = mk_i(OPC_LOAD, crd, crs1, 3'b010, off);
                    end
                    3'b110: begin  // c.sw  -> sw rs2', imm(rs1')
                        logic [6:0] swoff;
                        swoff = {c[5], c[12:10], c[6], 2'b00};
                        off   = {25'b0, swoff};
                        res   = mk_s(OPC_STORE, crs1, crs2, 3'b010, off);
                    end
                    // c.fld / c.flw / c.lq / c.fsd ... : not in RV32IMAC
                    default: res = 32'h0000_0000;
                endcase
            end

            // ---------------------------------------------------
            // Quadrant 1 (c[1:0] = 01)
            // ---------------------------------------------------
            2'b01: begin
                unique case (f3)
                    3'b000: begin  // c.addi / c.nop -> addi rd, rd, nzimm6
                        // imm6 = {c[12], c[6:2]}. c.nop = rd==0 && imm==0;
                        // rd==0 && imm!=0 is reserved -> illegal.
                        logic [5:0] imm6;
                        imm6 = {c[12], c[6:2]};
                        if (rd5 == 5'd0 && imm6 == 6'd0) begin
                            res = mk_i(OPC_OP_IMM, 5'd0, 5'd0, 3'b000, 32'd0);
                        end else if (rd5 != 5'd0) begin
                            off = {{26{imm6[5]}}, imm6};  // sext to 32
                            res = mk_i(OPC_OP_IMM, rd5, rd5, 3'b000, off);  // rs1=rd
                        end
                    end
                    3'b001: begin  // c.jal (RV32) -> jal x1, offset
                        // CJ offset scramble (verified vs c.j 16 = 0xA801):
                        // imm[11]=c[12] imm[10]=c[8] imm[9]=c[10] imm[8]=c[9]
                        // imm[7]=c[6]  imm[6]=c[7] imm[5]=c[2] imm[4]=c[11]
                        // imm[3]=c[5]  imm[2]=c[4] imm[1]=c[3]  imm[0]=0.
                        logic [11:0] joff;
                        joff = {
                            c[12],
                            c[8],
                            c[10],
                            c[9],
                            c[6],
                            c[7],
                            c[2],
                            c[11],
                            c[5],
                            c[4],
                            c[3],
                            1'b0
                        };
                        off = {{20{joff[11]}}, joff};
                        res = mk_j(OPC_JAL, 5'd1, off);  // rd = x1
                    end
                    3'b010: begin  // c.li -> addi rd, x0, imm6
                        logic [5:0] imm6;
                        imm6 = {c[12], c[6:2]};
                        if (rd5 != 5'd0) begin  // rd==0 is HINT -> illegal
                            off = {{26{imm6[5]}}, imm6};
                            res = mk_i(OPC_OP_IMM, rd5, 5'd0, 3'b000, off);  // rs1=x0
                        end
                    end
                    3'b011: begin  // c.addi16sp (rd==x2) / c.lui (else)
                        if (rd5 == 5'd2) begin
                            // nzimm[9]=c[12], [8:7]=c[4:3], [6]=c[5],
                            // [5]=c[2], [4]=c[6], [3:0]=0 (mult of 16).
                            // Illegal if 0.
                            logic [9:0] nz;
                            nz = {c[12], c[4:3], c[5], c[2], c[6], 4'b0};
                            if (nz != 10'd0) begin
                                off = {{22{nz[9]}}, nz};
                                res = mk_i(OPC_OP_IMM, 5'd2, 5'd2, 3'b000, off);
                            end
                        end else begin
                            // c.lui -> lui rd, nzimm6<<12.
                            // Illegal if rd==0 or imm6==0.
                            logic [5:0] imm6;
                            imm6 = {c[12], c[6:2]};
                            if (rd5 != 5'd0 && imm6 != 6'd0) begin
                                off = {{14{imm6[5]}}, imm6, 12'b0};
                                res = mk_u(OPC_LUI, rd5, off);
                            end
                        end
                    end
                    3'b100: begin  // c.srli / c.srai / c.andi (CB) +
                        //               c.sub / c.xor / c.or / c.and (CA)
                        // All share rd' = c[9:7] (x8..x15) as BOTH rd and
                        // rs1 (srli/srai/andi: rd=rs1=rd'; sub/xor/or/and:
                        // rd=rs1=rd', rs2=rs2'=c[4:2]). c[12] is shamt[5]
                        // (srli/srai) or imm[5] (andi); RV32 requires
                        // shamt[5]=0 for srli/srai. Top selector = c[11:10]:
                        //   00 srli  01 srai  10 andi
                        //   11 arith by c[6:5]: 00 sub 01 xor 10 or 11 and
                        unique case (c[11:10])
                            2'b00: begin  // c.srli  rd', shamt (RV32 shamt=c[6:2])
                                off = {25'b0, 2'b00, c[6:2]};
                                res = mk_i(OPC_OP_IMM, crs1, crs1, 3'b101, off);
                            end
                            2'b01: begin  // c.srai  rd', shamt
                                off = {20'b0, 7'b0100000, c[6:2]};
                                res = mk_i(OPC_OP_IMM, crs1, crs1, 3'b101, off);
                            end
                            2'b10: begin  // c.andi  rd', imm
                                logic [5:0] imm6;
                                imm6 = {c[12], c[6:2]};
                                off  = {{26{imm6[5]}}, imm6};
                                res  = mk_i(OPC_OP_IMM, crs1, crs1, 3'b111, off);
                            end
                            2'b11: begin  // c.sub / c.xor / c.or / c.and (CA)
                                unique case (c[6:5])
                                    2'b00: begin  // c.sub  rd', rd' - rs2'
                                        res = mk_r(OPC_OP, crs1, crs1, crs2, 3'b000, 7'b0100000);
                                    end
                                    2'b01: begin  // c.xor  rd', rd' ^ rs2'
                                        res = mk_r(OPC_OP, crs1, crs1, crs2, 3'b100, 7'b0000000);
                                    end
                                    2'b10: begin  // c.or   rd', rd' | rs2'
                                        res = mk_r(OPC_OP, crs1, crs1, crs2, 3'b110, 7'b0000000);
                                    end
                                    2'b11: begin  // c.and  rd', rd' & rs2'
                                        res = mk_r(OPC_OP, crs1, crs1, crs2, 3'b111, 7'b0000000);
                                    end
                                    default: res = 32'h0000_0000;
                                endcase
                            end
                            default: res = 32'h0000_0000;
                        endcase
                    end
                    3'b101: begin  // c.j -> jal x0, offset
                        // CJ offset scramble (see c.jal above).
                        logic [11:0] joff;
                        joff = {
                            c[12],
                            c[8],
                            c[10],
                            c[9],
                            c[6],
                            c[7],
                            c[2],
                            c[11],
                            c[5],
                            c[4],
                            c[3],
                            1'b0
                        };
                        off = {{20{joff[11]}}, joff};
                        res = mk_j(OPC_JAL, 5'd0, off);  // rd = x0
                    end
                    3'b110: begin  // c.beqz rs1', offset  -> beq rs1', x0
                        // CB branch offset: imm[8]=c[12], [7:6]=c[6:5],
                        // [5]=c[2], [4:3]=c[11:10], [2:1]=c[4:3], [0]=0.
                        logic [8:0] boff;
                        boff = {c[12], c[6:5], c[2], c[11:10], c[4:3], 1'b0};
                        off  = {{23{boff[8]}}, boff};
                        res  = mk_b(OPC_BRANCH, crs1, 5'd0, 3'b000, off);  // beq
                    end
                    3'b111: begin  // c.bnez rs1', offset  -> bne rs1', x0
                        logic [8:0] boff;
                        boff = {c[12], c[6:5], c[2], c[11:10], c[4:3], 1'b0};
                        off  = {{23{boff[8]}}, boff};
                        res  = mk_b(OPC_BRANCH, crs1, 5'd0, 3'b001, off);  // bne
                    end
                endcase
            end

            // ---------------------------------------------------
            // Quadrant 2 (c[1:0] = 10)
            // ---------------------------------------------------
            2'b10: begin
                unique case (f3)
                    3'b000: begin  // c.slli rd, shamt -> slli rd, rd, shamt
                        // shamt = {c[12], c[6:2]} (RV32 uses [4:0]).
                        // rd==0 is HINT -> illegal.
                        if (rd5 != 5'd0) begin
                            off = {25'b0, 2'b00, c[6:2]};
                            res = mk_i(OPC_OP_IMM, rd5, rd5, 3'b001, off);
                        end
                    end
                    3'b010: begin  // c.lwsp rd, imm(x2) -> lw rd, imm(x2)
                        // uimm[5]=c[12], [4:2]=c[6:4], [7:6]=c[3:2], [1:0]=00.
                        // rd==0 reserved -> illegal.
                        logic [7:0] uimm;
                        uimm = {c[3:2], c[12], c[6:4], 2'b00};
                        off  = {24'b0, uimm};
                        if (rd5 != 5'd0) begin
                            res = mk_i(OPC_LOAD, rd5, 5'd2, 3'b010, off);
                        end
                    end
                    3'b100: begin  // c.jr / c.jalr / c.mv / c.add / c.ebreak
                        // rs2==0: c.jr/c.jalr/c.ebreak. rs2!=0: c.mv/c.add
                        // (selected by c[12]: 0=mv, 1=add).
                        if (rd5 == 5'd0 && rs2_5 == 5'd0) begin
                            // c.ebreak -> illegal (SYSTEM, not decoded)
                        end else if (rs2_5 == 5'd0) begin
                            // c.jr (c[12]=0) / c.jalr (c[12]=1): jalr rd, 0(rs1).
                            // rs1 = c[11:7] (= rd5); rd = x0 for c.jr (discard
                            // link), x1 (ra) for c.jalr. c.ebreak (rs1==0) was
                            // caught above. Using rd5 as rd would write the link
                            // back INTO the jump register, corrupting it.
                            res = mk_i(OPC_JALR, c[12] ? 5'd1 : 5'd0, rd5, 3'b000, 32'd0);
                        end else begin
                            // c.mv / c.add — rd==0 is HINT -> illegal
                            if (rd5 != 5'd0) begin
                                if (c[12])  // c.add  -> add rd, rd, rs2
                                    res = mk_r(OPC_OP, rd5, rd5, rs2_5, 3'b000, 7'b0000000);
                                else  // c.mv   -> add rd, x0, rs2
                                    res = mk_r(OPC_OP, rd5, 5'd0, rs2_5, 3'b000, 7'b0000000);
                            end
                        end
                    end
                    3'b110: begin  // c.swsp rs2, imm(x2) -> sw rs2, imm(x2)
                        // uimm[5:2]=c[12:9], [7:6]=c[8:7], [1:0]=00.
                        logic [7:0] uimm;
                        uimm = {c[8:7], c[12:9], 2'b00};
                        off  = {24'b0, uimm};
                        res  = mk_s(OPC_STORE, 5'd2, rs2_5, 3'b010, off);
                    end
                    // c.fldsp / c.flwsp / c.fswsp : not in RV32IMAC
                    default: res = 32'h0000_0000;
                endcase
            end

            default: res = 32'h0000_0000;
        endcase

        return res;
    endfunction
    // Hold buffer: when a 32-bit word's low half is compressed, decode it
    // this cycle and stash the upper half for next cycle.
    // =================================================================
    logic        hold_q;
    logic [31:0] hold_word_q;
    logic [31:0] hold_pc_q;

    logic        hold_d;
    logic [31:0] hold_word_d;
    logic [31:0] hold_pc_d;
    // Source selection + uniform 32-bit decode (one always_comb).
    // =================================================================
    // is-compressed of the fetched word, derived from the instruction
    // word itself (fetch no longer exports it as a separate port).
    wire         fe_is_compressed = (fe_instr_i[1:0] != 2'b11);

    logic [31:0] src_instr32;
    logic [31:0] src_pc;
    logic        src_is_compressed;
    logic        buffer_upper;
    logic        decoded_valid;

    // -----------------------------------------------------------------
    // Spanning-stitch predicates.
    //
    // A 32-bit instruction at a 2-byte-aligned-but-not-4-byte-aligned
    // address (offset 2 of a fetch word) SPANS two fetch words: its low
    // halfword is bytes 2-3 of word W, its upper halfword is bytes 0-1 of
    // word W+1. The hold buffer stashes that low halfword; whether the
    // stash is a compressed upper half or a spanning 32-bit low half is
    // derivable from the stashed halfword's [1:0] (==2'b11 -> 32-bit
    // low half). So the stitch needs NO new flop: these are all wires
    // over flops + inputs.
    // -----------------------------------------------------------------
    wire         hold_is_span = (hold_word_q[1:0] == 2'b11);  // stashed low half of a 32-bit instr
    // A fault entry outranks every other source. If a spanning
    // instruction was waiting for its upper half, that upper half is
    // exactly what could not be fetched, so the fault belongs to it and the
    // stash is dropped rather than stitched against a synthesised word.
    wire         fetch_fault = fe_valid_i && fe_fault_i;

    wire         is_hold = hold_q;
    wire         is_hold_plain = !fetch_fault && hold_q && !hold_is_span;  // upper half ready
    wire         span_pending = hold_q && hold_is_span;  // spanning low half held
    wire         span_complete = !fetch_fault && span_pending && fe_valid_i;  // stitch
    wire         span_wait = !fetch_fault && span_pending && !fe_valid_i;  // waiting for the word
    wire         target_upper = !fetch_fault && !hold_q && fe_valid_i && fe_pc_i[1];  // odd half
    wire         target_span = target_upper && (fe_instr_i[17:16] == 2'b11);  // 32-bit at target
    // Same-cycle stitch: the target word's low half (head[31:16]) is the
    // 32-bit instr's low half, and head+1's low half (fe_next_instr_i[15:0])
    // is its upper half — both buffered, so stitch now (no bubble). A fault
    // at head+1 falls back to wait (stall-and-wait the old way) so the fault
    // routes through with the faulting word's PC next cycle.
    wire         target_span_complete = target_span && fe_next_valid_i && !fe_next_fault_i;
    wire         target_span_wait = target_span && !target_span_complete;

    always_comb begin
        // Priority: spanning stitch > compressed hold > odd-half branch
        // target > fresh F/D low half. A spanning 32-bit instr's low
        // halfword is stashed in the hold buffer (or sits at an odd-half
        // branch target); its upper halfword is the next fetch word's
        // low half, stitched in here when that word arrives (span_complete).
        if (fetch_fault) begin
            // No instruction word exists. src_instr32 is a don't-care; the
            // exception below carries the cause and the faulting PC.
            src_instr32       = 32'd0;
            src_pc            = fe_pc_i;
            src_is_compressed = 1'b0;
        end else if (span_complete) begin
            // Stitch: low half = hold_word_q[15:0] (bytes 2-3 of word W),
            // upper half = fe_instr_i[15:0] (bytes 0-1 of word W+1). PC
            // is the spanning instr's own PC (hold_pc_q). The stitched
            // word is a real 32-bit instr -> is_compressed = 0.
            src_instr32       = {fe_instr_i[15:0], hold_word_q[15:0]};
            src_pc            = hold_pc_q;
            src_is_compressed = 1'b0;
        end else if (span_wait) begin
            // Spanning low half held, upper-half fetch word not here yet:
            // no complete instruction this cycle (bubble). src_instr32 is
            // a don't-care (decoded_valid=0 gates de_d.valid/illegal).
            src_instr32       = 32'd0;
            src_pc            = hold_pc_q;
            src_is_compressed = 1'b0;
        end else if (is_hold_plain) begin
            // Compressed upper half stashed last cycle: decode it.
            // Recompute is_compressed from THIS half (its [1:0]), not
            // from fe_is_compressed (which describes the whole word).
            src_instr32       = c_expand(hold_word_q[15:0]);
            src_pc            = hold_pc_q;
            src_is_compressed = (hold_word_q[1:0] != 2'b11);
        end else if (target_upper) begin
            if (target_span_complete) begin
                // Same-cycle stitch: target word's upper half (head[31:16])
                // is the 32-bit instr's low half; head+1's low half
                // (fe_next_instr_i[15:0]) is its upper half. PC is the
                // target PC (fe_pc_i). A real 32-bit word -> bypasses
                // c_expand. head+1's upper half is re-stashed (hold
                // next-state) as the next instruction.
                src_instr32       = {fe_next_instr_i[15:0], fe_instr_i[31:16]};
                src_pc            = fe_pc_i;
                src_is_compressed = 1'b0;
            end else if (target_span_wait) begin
                // Branch target at offset 2/6 is a 32-bit instr's low half
                // but head+1 is absent or faults: no emit this cycle (bubble),
                // stash the low half, stitch completes next cycle (the old
                // span path). A fault at head+1 lands here -> trap next cycle.
                src_instr32       = 32'd0;
                src_pc            = fe_pc_i;
                src_is_compressed = 1'b0;
            end else begin
                // Compressed target in the upper half (fe_pc_i[1]=1). The
                // low half was branched over and is discarded; do NOT
                // stash it.
                src_instr32       = c_expand(fe_instr_i[31:16]);
                src_pc            = fe_pc_i;
                src_is_compressed = (fe_instr_i[17:16] != 2'b11);
            end
        end else begin
            // Fresh F/D low half (fe_pc_i[1]=0).
            if (fe_is_compressed) begin
                src_instr32       = c_expand(fe_instr_i[15:0]);
                src_pc            = fe_pc_i;
                src_is_compressed = 1'b1;
            end else begin
                src_instr32       = fe_instr_i;
                src_pc            = fe_pc_i;
                src_is_compressed = 1'b0;
            end
        end

        // Stash the upper half of a fresh word whose low half was
        // consumed this cycle (a fresh compressed instr at offset 0).
        // Spanning low halves are stashed separately (span_complete /
        // target_span in the hold next-state). The compressed-vs-spanning
        // distinction is derived from the stashed halfword's [1:0], so
        // buffer_upper needs no span flag of its own.
        buffer_upper = (!is_hold) && !target_upper && fe_valid_i && fe_is_compressed;

        // A COMPLETE instruction is available this cycle: every case
        // EXCEPT span_wait (upper-half word not here yet) and target_span_wait
        // (just stashed the low half, waiting for the stitch). This becomes
        // al_o.valid, which gates de_d.valid and the forward-path compare
        // in decode, so neither wait state emits a spurious valid.
        decoded_valid = fetch_fault | span_complete | is_hold_plain | (target_upper && !target_span)
            | target_span_complete | (fe_valid_i && !hold_q && !target_upper);
    end

    // =================================================================
    // Hold-buffer next-state
    // =================================================================
    always_comb begin
        // Defaults: hold (preserve the stash).
        hold_d      = hold_q;
        hold_word_d = hold_word_q;
        hold_pc_d   = hold_pc_q;

        if (flush_i) begin
            hold_d = 1'b0;  // execute redirect: drop any stashed half
        end else if (pred_flush_i) begin
            // Predicted-taken redirect: the half sitting after this control-
            // flow instr is wrong-path, drop it. The span_complete /
            // buffer_upper / target_span_complete branches below would
            // otherwise re-stash that half this cycle (the fetch buffer kill
            // reaches neither this stash nor the A/D flop), letting it retire.
            hold_d = 1'b0;
        end else if (fetch_fault) begin
            hold_d = 1'b0;  // the unfetchable half is gone; drop the stash
        end else if (stall_i) begin
            // DIV-REM / mem-wait stall: preserve the stash.
        end else if (span_wait) begin
            // Spanning low half held, upper-half word not here yet:
            // keep waiting (preserve). Do NOT stall fetch -- it must
            // capture word W+1 -- and stall_o reflects that (no term).
        end else if (span_complete) begin
            // Stitch consumed the spanning low (hold) AND fe_instr's low
            // half (bytes 0-1 of word W+1). The next instruction is
            // fe_instr's upper half (bytes 2-3 of W+1) -> stash it
            // unconditionally (its [1:0] flags compressed vs another
            // spanning low; consecutive spanning instrs fall through
            // here). PC = fe_pc + 2.
            hold_d      = 1'b1;
            hold_word_d = fe_instr_i[31:16];
            hold_pc_d   = fe_pc_i + 32'd2;
        end else if (is_hold_plain) begin
            // Compressed upper half consumed; clear.
            hold_d = 1'b0;
        end else if (target_span_complete) begin
            // Same-cycle stitch consumed head (target word: low half branched
            // over, upper half = 32-bit instr's low half) AND head+1's low half
            // (the instr's upper half). The next instruction is head+1's upper
            // half -> stash it (its [1:0] flags compressed vs another spanning
            // low; consecutive spanning instrs chain here). PC = head+1 PC + 2.
            // span_complete (needs hold_q) and target_span_complete (needs
            // !hold_q) are mutually exclusive, so the if-else priority holds.
            hold_d      = 1'b1;
            hold_word_d = fe_next_instr_i[31:16];
            hold_pc_d   = fe_next_pc_i + 32'd2;
        end else if (target_span_wait) begin
            // Branch target at offset 2/6 is a 32-bit instr's low half, but
            // head+1 is absent or faults: stash the low half and wait for the
            // upper-half word (the old target_span behavior). The spanning
            // instr sits AT the target, so hold_pc = fe_pc (not +2).
            hold_d      = 1'b1;
            hold_word_d = fe_instr_i[31:16];
            hold_pc_d   = fe_pc_i;
        end else if (buffer_upper) begin
            // Decoded a fresh low compressed half; stash the upper half
            // (PC = word_pc + 2). Its [1:0] flags a spanning low.
            hold_d      = 1'b1;
            hold_word_d = fe_instr_i[31:16];
            hold_pc_d   = fe_pc_i + 32'd2;
        end else begin
            hold_d = 1'b0;  // nothing to stash
        end
    end

    // =================================================================
    // Back-pressure to fetch: this stage's own resource stall, or decode
    // back-pressure passed through (which is execute's stall -- DIV/REM,
    // mem-wait, CSR-wait). RAW is NOT a source of back-pressure; the
    // execute->decode forward path resolves it without stalling anything.
    // The hold_q && fe_valid_i term fires for a compressed-upper hold
    // alongside a fresh buffer word (the stash has priority -> hold fetch).
    // It is gated on !hold_is_span: a spanning hold with fe_valid is
    // span_complete, which CONSUMES word W+1 (no stall) -- without the
    // gate, the stitch would wrongly hold F/D and re-see W+1. span_wait
    // has fe_valid=0 (no term). The stall_i term carries real
    // back-pressure.
    // =================================================================
    wire resource_stall = (hold_q && !hold_is_span && fe_valid_i);
    assign stall_o   = resource_stall || stall_i;

    // Same-cycle target-span stitch: pop 2 (head + head+1). target_span_complete
    // has hold_q=0 so resource_stall=0; only stall_i back-pressures, which fetch
    // already gates out of buf_pop_cnt. Asserted only when fe_next_valid_i
    // (count>=2) -> pop-2 <= count.
    assign fe_pop2_o = target_span_complete;


    // =================================================================
    // A/D pipeline register + sequential
    // =================================================================
    logic [XLEN-1:0] al_instr_q, al_pc_q;
    logic al_valid_q, al_fault_q, al_comp_q;

    // Kill the output flop on either redirect: on an execute redirect the
    // instruction in it is squashed, and on a predicted-taken redirect it is
    // the wrong-path instruction sitting behind the branch decode consumed
    // this cycle. Otherwise hold on stall_i (decode cannot accept) and
    // capture the aligned instruction when it can.
    wire al_kill = flush_i | pred_flush_i;

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            hold_q      <= 1'b0;
            hold_word_q <= 32'd0;
            hold_pc_q   <= 32'd0;
            al_instr_q  <= 32'd0;
            al_pc_q     <= 32'd0;
            al_valid_q  <= 1'b0;
            al_fault_q  <= 1'b0;
            al_comp_q   <= 1'b0;
        end else begin
            hold_q      <= hold_d;
            hold_word_q <= hold_word_d;
            hold_pc_q   <= hold_pc_d;
            if (al_kill) begin
                al_valid_q <= 1'b0;
                al_fault_q <= 1'b0;
            end else if (!stall_i) begin
                al_instr_q <= src_instr32;
                al_pc_q    <= src_pc;
                al_valid_q <= decoded_valid;
                al_fault_q <= fetch_fault;
                al_comp_q  <= src_is_compressed;
            end
        end
    end

    assign al_o.instr         = al_instr_q;
    assign al_o.pc            = al_pc_q;
    assign al_o.valid         = al_valid_q;
    assign al_o.fault         = al_fault_q;
    assign al_o.is_compressed = al_comp_q;

endmodule

`resetall
