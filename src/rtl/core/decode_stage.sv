`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
 * Decode stage — phase 1 (RV32I + M + C, no execute yet).
 *
 * Consumes fetch's F/D outputs (fe_instr / fe_pc / fe_valid — `fe_` is
 * the fetch stage's sigil; the F/D register is fetch's output, so these
 * inputs take the producer's sigil) and produces a D/E control word
 * (de_o) latched into a D/E register. The register file is read
 * asynchronously from this stage so operands are captured at decode.
 * There is no execute stage yet, so de_o feeds debug taps only; the
 * reg-file write port has no producer (writeback) and is tied off in the
 * CPU top.
 *
 * Each pipeline stage exposes the PC it is treating, the instruction
 * word, and a valid as outputs (prefixed by its stage sigil: fe = fetch,
 * de = decode, ex = execute, ...). Further debug signals are added on
 * demand. Decode's output is the D/E register (de_o); the CPU top
 * exposes de_pc / de_instr / de_valid as taps.
 *
 * Strategy: **expand-then-decode-uniformly**. A 16-bit RVC instruction is
 * first turned into its 32-bit RV32I equivalent by c_expand(); the same
 * uniform decoder then decodes the 32-bit word whether it came native
 * (fe_instr) or from expansion. The M extension has no compressed
 * forms, so only RV32I compressed instructions are expanded.
 *
 * RVC spanning / phase-1 simplification: fetch always delivers a 32-bit
 * word; is-compressed = (word[1:0]!=2'b11) is derived here from
 * fe_instr_i. A compressed instruction sitting in the LOW half of a
 * word is decoded this cycle and the UPPER half is latched into a hold
 * buffer to be decoded next cycle (its PC = word_pc + 2). A 32-bit
 * instruction must be 4-byte aligned; the spanning case (low half
 * compressed AND the upper half's [1:0]==2'b11) is treated as
 * **undefined -> illegal=1**.
 *
 * Branch target in the UPPER half: a redirect may land on an odd-half
 * address (fe_pc_i[1]=1, a 16-bit compressed target). The low half was
 * branched over and is discarded; the upper half is decoded directly
 * (no hold buffer). Per the spec an instruction at bit[1]=1 is either a
 * compressed 16-bit or a 32-bit spanning instr (illegal), so the upper
 * half's [1:0]==2'b11 is the same spanning-illegal class. fetch
 * realigns pc_q after such a redirect so the following fetch is the
 * next word (low half), not another odd-half address.
 *
 * stall_o feeds fetch's stall_i so a future hazard unit can back-pressure
 * the pipe. It is wired (not tied) but currently INERT: hold_q and
 * fe_valid_i are mutually exclusive by construction (hold raises the
 * cycle fe_valid falls), so stall_o is 0 in steady state.
 *
 * Decoded-but-not-yet-executable opcodes (control rides the D/E register to
 * the debug taps; the LSU is not present yet, so loads don't retire):
 *   OPC_AMO with Zilx funct5 (10010 unscaled / 11010 scaled) -> indexed-load
 *     control (mem_read, ALU_LX effective address, WB_MEM). rs1=index,
 *     rs2=base (roles swapped vs base loads). Real AMOs (other funct5) and
 *     RV64-only encodings (funct5=11110, funct3=011/110) decode to illegal.
 *
 * Deferred opcodes (decode to illegal=1, not executed this phase):
 *   OPC_MISC_MEM (fence / fence.i — Zifencei),
 *   OPC_SYSTEM   (CSR / ecall / ebreak — Zicsr),
 *   atomics / any unknown opcode.
 *
 * Naming: ports *_i/_o; internal signals no prefix; flops _q, next-state
 * _d. Module instances keep u_*.
 */

module decode_stage (
    input wire clk_i,
    input wire rstn_i,

    // F/D register inputs (from fetch_stage). Named with the fetch
    // stage's `fe_` sigil: these are fetch's output, consumed here.
    // is-compressed is derived from fe_instr_i[1:0] (not a separate
    // port) so fetch exports only pc / instr / valid.
    input wire [XLEN-1:0] fe_instr_i,
    input wire [XLEN-1:0] fe_pc_i,
    input wire            fe_valid_i,

    // Register-file read port (decode drives addresses; data returns
    // combinationally the same cycle).
    output wire [     4:0] rs1_addr_o,
    output wire [     4:0] rs2_addr_o,
    input  wire [XLEN-1:0] rs1_data_i,
    input  wire [XLEN-1:0] rs2_data_i,

    // Back-pressure from a future execute / hazard unit (tied 0 now).
    input wire stall_i,
    input wire flush_i,

    // Back-pressure to fetch (so the pipe can stall). Currently inert.
    output wire stall_o,

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
                        // nzuimm[9:6]=c[10:7], [5:4]=c[12:11], [3]=c[6],
                        // [2]=c[5], [1:0]=00. Illegal if nzuimm==0.
                        logic [9:0] nz;
                        nz = {c[10:7], c[12:11], c[6], c[5], 2'b00};
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
                        // CJ offset scramble (verified vs c.j 16 = 0xA805):
                        // imm[11]=c[12] imm[10]=c[8] imm[9]=c[10] imm[8]=c[9]
                        // imm[7]=c[2]  imm[6]=c[7] imm[5]=c[6] imm[4]=c[11]
                        // imm[3]=c[5]  imm[2]=c[4] imm[1]=c[3]  imm[0]=0.
                        logic [11:0] joff;
                        joff = {
                            c[12],
                            c[8],
                            c[10],
                            c[9],
                            c[2],
                            c[7],
                            c[6],
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
                            // [5]=c[2], [4:0]=0 (mult of 16). Illegal if 0.
                            logic [9:0] nz;
                            nz = {c[12], c[4:3], c[5], c[2], 5'b0};
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
                    3'b100: begin  // c.srli / c.srai / c.andi / c.sub
                        //               / c.xor / c.or / c.and (CB / CA)
                        // Selector = {c[12], c[11:10]}:
                        //   000 srli  100 srai  001 andi
                        //   010 sub   110 xor   011 or   111 and
                        //   101 reserved -> illegal
                        unique case ({
                            c[12], c[11:10]
                        })
                            3'b000: begin  // c.srli  rd', shamt (RV32 shamt=c[6:2])
                                off = {25'b0, 2'b00, c[6:2]};
                                res = mk_i(OPC_OP_IMM, crd, crd, 3'b101, off);
                            end
                            3'b100: begin  // c.srai  rd', shamt
                                off = {20'b0, 7'b0100000, c[6:2]};
                                res = mk_i(OPC_OP_IMM, crd, crd, 3'b101, off);
                            end
                            3'b001: begin  // c.andi  rd', imm
                                logic [5:0] imm6;
                                imm6 = {c[12], c[6:2]};
                                off  = {{26{imm6[5]}}, imm6};
                                res  = mk_i(OPC_OP_IMM, crd, crd, 3'b111, off);
                            end
                            3'b010: begin  // c.sub  rd', rd' - rs2'
                                res = mk_r(OPC_OP, crd, crd, crs2, 3'b000, 7'b0100000);
                            end
                            3'b110: begin  // c.xor  rd', rd' ^ rs2'
                                res = mk_r(OPC_OP, crd, crd, crs2, 3'b100, 7'b0000000);
                            end
                            3'b011: begin  // c.or   rd', rd' | rs2'
                                res = mk_r(OPC_OP, crd, crd, crs2, 3'b110, 7'b0000000);
                            end
                            3'b111: begin  // c.and  rd', rd' & rs2'
                                res = mk_r(OPC_OP, crd, crd, crs2, 3'b111, 7'b0000000);
                            end
                            default: res = 32'h0000_0000;  // 101 reserved
                        endcase
                    end
                    3'b101: begin  // c.j -> jal x0, offset
                        logic [11:0] joff;
                        joff = {
                            c[12],
                            c[8],
                            c[10],
                            c[9],
                            c[2],
                            c[7],
                            c[6],
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
                            // c.jr (rd!=1) / c.jalr (rd==1): jalr rd, 0(rs1)
                            res = mk_i(OPC_JALR, rd5, rd5, 3'b000, 32'd0);
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

    // =================================================================
    // Hold buffer: when a 32-bit word's low half is compressed, decode it
    // this cycle and stash the upper half for next cycle.
    // =================================================================
    logic        hold_q;
    logic [31:0] hold_word_q;
    logic [31:0] hold_pc_q;

    logic        hold_d;
    logic [31:0] hold_word_d;
    logic [31:0] hold_pc_d;

    // =================================================================
    // D/E pipeline register
    // =================================================================
    de_t de_q, de_d, de_next;

    // =================================================================
    // Source selection + uniform 32-bit decode (one always_comb).
    // =================================================================
    // is-compressed of the fetched word, derived from the instruction
    // word itself (fetch no longer exports it as a separate port).
    wire         fe_is_compressed = (fe_instr_i[1:0] != 2'b11);

    logic [31:0] src_instr32;
    logic [31:0] src_pc;
    logic        src_is_compressed;
    logic        is_hold;
    logic        target_upper;  // redirect landed on an odd-half (upper) target
    logic        buffer_upper;
    logic        spanning_illegal;
    logic        decoded_valid;

    logic [ 4:0] rs1_addr_dec;
    logic [ 4:0] rs2_addr_dec;

    // ---- Field extraction ----
    logic [ 6:0] opcode;
    logic [ 2:0] funct3;
    logic [ 6:0] funct7;
    logic        funct7b5;  // funct7[5] — SUB/SRA, M-ext
    logic [ 4:0] funct5;  // AMO/Zilx mode (instr[31:27])
    logic aq, rl;  // AMO ordering bits (instr[26:25]) — must be 0 for Zilx
    logic [4:0] rd_field, rs1_field, rs2_field;
    logic is_m_ext;

    // ---- Immediates (sign-extended) ----
    logic [31:0] imm_i, imm_s, imm_b, imm_u, imm_j;

    // ---- Decoded control (defaults; recognised opcodes override) ----
    logic [31:0] imm;
    logic uses_rs1, uses_rs2;
    logic       reg_write;
    alu_op_t    alu_op;
    alu_src_a_t alu_src_a;
    alu_src_b_t alu_src_b;
    logic mem_read, mem_write;
    mem_size_t       mem_size;
    logic            mem_unsigned;
    logic      [1:0] mem_shamt;  // Zilx index scale (0 unscaled, log2 size scaled)
    wb_src_t         wb_src;
    branch_t         branch_type;
    logic            dec_illegal;

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

    always_comb begin
        // ---- Source selection (priority: hold buffer > odd-half target
        // > fresh F/D low half) ----
        is_hold      = hold_q;
        // A redirect landed on an odd-half compressed target: the
        // instruction is in the UPPER half of the fetched word.
        target_upper = !is_hold && fe_valid_i && fe_pc_i[1];

        if (is_hold) begin
            src_instr32       = c_expand(hold_word_q[15:0]);
            src_pc            = hold_pc_q;
            // Recompute: a 16-bit instr in the upper half is compressed
            // iff its [1:0] != 2'b11 (do NOT trust fe_is_compressed,
            // which describes the WHOLE word, not this half).
            src_is_compressed = (hold_word_q[1:0] != 2'b11);
        end else if (target_upper) begin
            // Branch/jump target in the UPPER half (fe_pc_i[1]=1). Per
            // the RISC-V spec an instruction at an odd half is either a
            // compressed 16-bit (decoded here) or a 32-bit spanning instr
            // (illegal -- caught by spanning_illegal below). The low half
            // was branched over and is discarded; do NOT stash it.
            src_instr32       = c_expand(fe_instr_i[31:16]);
            src_pc            = fe_pc_i;
            src_is_compressed = (fe_instr_i[17:16] != 2'b11);
        end else begin
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

        // Decode the low compressed half now -> stash the upper half.
        // Skip stashing when the target is the upper half itself (the low
        // half was branched over, nothing to defer).
        buffer_upper = (!is_hold) && !target_upper && fe_valid_i && fe_is_compressed;

        // Spanning case: a half that looks like a 32-bit instr (low bits
        // 2'b11). From the hold buffer (upper half of a fall-through word)
        // or from an odd-half branch target (upper half of the redirect
        // word) -- both are a 32-bit instr at a non-4-byte-aligned spot,
        // which is illegal.
        spanning_illegal = (is_hold && (hold_word_q[1:0] == 2'b11)) ||
            (target_upper && (fe_instr_i[17:16] == 2'b11));
        decoded_valid = is_hold || fe_valid_i;

        // ---- Field extraction ----
        opcode = src_instr32[6:0];
        funct3 = src_instr32[14:12];
        funct7 = src_instr32[31:25];
        funct7b5 = src_instr32[30];
        funct5 = src_instr32[31:27];  // AMO/Zilx mode
        aq = src_instr32[26];  // AMO aq (must be 0 for Zilx)
        rl = src_instr32[25];  // AMO rl (must be 0 for Zilx)
        rd_field = src_instr32[11:7];
        rs1_field = src_instr32[19:15];
        rs2_field = src_instr32[24:20];
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
                    alu_src_b   = ALU_B_RS1_SH;  // index (rs1) << shamt
                    uses_rs1    = 1'b1;  // index
                    uses_rs2    = 1'b1;  // base
                    imm         = 32'd0;
                    wb_src      = WB_MEM;
                end
            end

            default: begin
                // OPC_MISC_MEM (fence), OPC_SYSTEM (csr/ecall/ebreak),
                // atomics, anything else -> illegal this phase.
                dec_illegal = 1'b1;
            end
        endcase

        // Register-read addresses: force x0 for instrs that don't use
        // rs1/rs2 (avoids reading a bogus field, e.g. LUI's rs1 is imm).
        rs1_addr_dec       = uses_rs1 ? rs1_field : 5'd0;
        rs2_addr_dec       = uses_rs2 ? rs2_field : 5'd0;

        // ---- Assemble the D/E word for this cycle ----
        de_d               = '0;
        de_d.valid         = decoded_valid;
        de_d.pc            = src_pc;
        de_d.instr         = src_instr32;  // 32-bit word decode treated
        de_d.is_compressed = src_is_compressed;
        de_d.rs1_addr      = rs1_addr_dec;
        de_d.rs2_addr      = rs2_addr_dec;
        de_d.rs1_data      = rs1_data_i;
        de_d.rs2_data      = rs2_data_i;
        de_d.imm           = imm;
        de_d.rd            = rd_field;
        de_d.alu_op        = alu_op;
        de_d.alu_src_a     = alu_src_a;
        de_d.alu_src_b     = alu_src_b;
        de_d.mem_size      = mem_size;
        de_d.mem_unsigned  = mem_unsigned;
        de_d.mem_shamt     = mem_shamt;
        de_d.wb_src        = wb_src;
        de_d.branch_type   = branch_type;
        // reg_write / mem_read / mem_write are squashed by illegal or
        // the spanning case; illegal reflects that.
        if (spanning_illegal || dec_illegal) begin
            de_d.reg_write   = 1'b0;
            de_d.mem_read    = 1'b0;
            de_d.mem_write   = 1'b0;
            de_d.branch_type = BR_NONE;
            de_d.illegal     = decoded_valid;  // illegal=1 only when a word was present
        end else begin
            de_d.reg_write = reg_write;
            de_d.mem_read  = mem_read;
            de_d.mem_write = mem_write;
            de_d.illegal   = 1'b0;
        end
    end

    // =================================================================
    // Hold-buffer next-state
    // =================================================================
    always_comb begin
        if (flush_i) begin
            hold_d      = 1'b0;
            hold_word_d = hold_word_q;
            hold_pc_d   = hold_pc_q;
        end else if (stall_i) begin
            hold_d      = hold_q;
            hold_word_d = hold_word_q;
            hold_pc_d   = hold_pc_q;
        end else if (hold_q) begin
            // Upper half consumed this cycle; clear.
            hold_d      = 1'b0;
            hold_word_d = hold_word_q;
            hold_pc_d   = hold_pc_q;
        end else if (buffer_upper) begin
            // Decoded low compressed half; stash upper (PC = word_pc + 2).
            hold_d      = 1'b1;
            hold_word_d = fe_instr_i[31:16];
            hold_pc_d   = fe_pc_i + 32'd2;
        end else begin
            hold_d      = 1'b0;
            hold_word_d = hold_word_q;
            hold_pc_d   = hold_pc_q;
        end
    end

    // =================================================================
    // D/E register next-state
    // =================================================================
    always_comb begin
        if (flush_i) begin
            de_next = '0;
        end else if (stall_i) begin
            de_next = de_q;  // hold
        end else begin
            de_next = de_d;
        end
    end

    // =================================================================
    // Back-pressure to fetch (currently INERT — see header comment).
    // =================================================================
    assign stall_o    = (hold_q && fe_valid_i) || stall_i;

    // Register-read addresses drive the reg file.
    assign rs1_addr_o = rs1_addr_dec;
    assign rs2_addr_o = rs2_addr_dec;

    // D/E output
    assign de_o       = de_q;

    // de_* per-stage taps (fields of de_o / de_q).
    assign de_pc_o    = de_q.pc;
    assign de_instr_o = de_q.instr;
    assign de_valid_o = de_q.valid;

    // =================================================================
    // Sequential
    // =================================================================
    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            hold_q      <= 1'b0;
            hold_word_q <= 32'd0;
            hold_pc_q   <= 32'd0;
            de_q        <= '0;
        end else begin
            hold_q      <= hold_d;
            hold_word_q <= hold_word_d;
            hold_pc_q   <= hold_pc_d;
            de_q        <= de_next;
        end
    end

endmodule

`resetall
