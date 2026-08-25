/* Per-scramble-bit RVC decode oracle for c_expand().
 *
 * The quicksort / ecall cosims and the hand-crafted oracles emit no RVC
 * instruction whose scattered (scrambled) immediate bits land on the
 * non-contiguous source fields, so a swapped or dropped scramble bit
 * (c.addi16sp nzimm[4], c.jal/c.j imm[7]/imm[5]) is invisible to them.
 * This program feeds c_expand() every scramble-bit immediate form with
 * each immediate bit set in isolation, self-checks the architectural
 * effect, and writes 0x600D (pass) / 0xBAD (fail) at D-mem 0x2000.
 *
 * Toolchain-assembled: the assembler packs the compressed half-words
 * and resolves the branch/jump offsets, emitting the SPEC-correct 16-bit
 * encodings. The point under test is the core's c_expand() DECODER -- if
 * it mis-scrambles a field, the computed value / control flow is wrong
 * and the self-check branches to `bad`.
 *
 * Forms covered (each immediate bit set alone, where the field scrambles):
 *   c.addi4spn  nzuimm[5:4|9:6|2|3]    K = 4,8,16,32,64,128,256,512
 *   c.addi16sp  nzimm[9|4|6|8:7|5]      K = 16,32,64,128,256,512
 *   c.li        nzimm6={c[12],c[6:2]}   31, -1, -32
 *   c.addi      nzimm6                  +5, -8 (on a known base)
 *   c.lui       nzimm6<<12              0x1000, 0x1F000, 0xFFFE0000
 *   c.andi      imm6                    1, 0x1F, 0x20(-32), 0x3F(-1)
 *   c.srli      shamt                   1, 5, 15, 31
 *   c.srai      shamt                   1, 5, 15, 31
 *   c.lw/c.sw   uimm[5:3|2|6]           off = 4,8,16,32,64 (round-trip)
 *   c.lwsp/swsp uimm[5|4:2|7:6]/[..]    off = 4,8,16,32,64,128 (round-trip)
 *   c.j         imm[11:1]               +4,8,16,32,64,128,256,512,1024,-2048
 *   c.jal       imm[11:1]               +32,128,1024 (also checks ra = PC+2)
 *   c.beqz      imm[8:1]                +4,8,16,32,64,128,256
 *   c.bnez      imm[8:1]                +4,32,128,256
 *
 * A trap handler (mtvec) writes 0xBAD and parks, so any illegal-trap
 * induced by a mis-decoded jump/offset is caught as a FAIL instead of a
 * hang. Pass marker: 0x600D at D-mem 0x2000 (= sim probe word 0x800).
 */

    .section .text.init, "ax"

    # CHECK reg, expect : li t1, expect ; bne reg, t1, bad
    .macro  CHECK reg, expect
    li      t1, \expect
    bne     \reg, t1, bad
    .endm

    # JTEST off : c.j +off must skip a fail-flag write. off >= 4, even.
    .macro  JTEST off
    c.li    t2, 0
    c.j     Lj_\off
    c.li    t2, 1
    .rept   (\off - 4) / 2
    c.nop
    .endr
Lj_\off:
    bne     t2, x0, bad
    .endm

    # JALTEST off : c.jal +off links ra = PC+2, target returns via c.jr ra.
    # The return-check block (la 8 + bne 4 + c.j 2 = 14 bytes) sits between
    # c.jal and the target; nops pad the rest so the c.jal offset == off.
    # off >= 16, even.
    .macro  JALTEST off
    c.jal   Ljal_\off
Ljalret_\off:
    la      t1, Ljalret_\off
    bne     ra, t1, bad
    j       Ljalc_\off
    .rept   (\off - 16) / 2
    c.nop
    .endr
Ljal_\off:
    c.jr    ra
Ljalc_\off:
    .endm

    # BEQZTEST off : a0=0 so c.beqz taken; skip-over-fail. off >= 4, even.
    .macro  BEQZTEST off
    c.li    a0, 0
    c.li    t2, 0
    c.beqz  a0, Lbz_\off
    c.li    t2, 1
    .rept   (\off - 4) / 2
    c.nop
    .endr
Lbz_\off:
    bne     t2, x0, bad
    .endm

    # BNEZTEST off : a0=1 so c.bnez taken; skip-over-fail. off >= 4, even.
    .macro  BNEZTEST off
    c.li    a0, 1
    c.li    t2, 0
    c.bnez  a0, Lnz_\off
    c.li    t2, 1
    .rept   (\off - 4) / 2
    c.nop
    .endr
Lnz_\off:
    bne     t2, x0, bad
    .endm

    .globl _start
_start:
    li      sp, 0x2000              # data base / compressed-stack base
    la      t0, trap_handler
    csrw    mtvec, t0

    # ===== c.addi4spn : nzuimm[5:4|9:6|2|3] (CIW) -- rd' = a0, rs1 = sp
    li      sp, 0x2000
    c.addi4spn a0, sp, 4
    CHECK   a0, 0x2004
    li      sp, 0x2000
    c.addi4spn a0, sp, 8
    CHECK   a0, 0x2008
    li      sp, 0x2000
    c.addi4spn a0, sp, 16
    CHECK   a0, 0x2010
    li      sp, 0x2000
    c.addi4spn a0, sp, 32
    CHECK   a0, 0x2020
    li      sp, 0x2000
    c.addi4spn a0, sp, 64
    CHECK   a0, 0x2040
    li      sp, 0x2000
    c.addi4spn a0, sp, 128
    CHECK   a0, 0x2080
    li      sp, 0x2000
    c.addi4spn a0, sp, 256
    CHECK   a0, 0x2100
    li      sp, 0x2000
    c.addi4spn a0, sp, 512
    CHECK   a0, 0x2200

    # ===== c.addi16sp : nzimm[9|4|6|8:7|5] (CI) -- rd = sp, rs1 = sp
    li      sp, 0x2000
    c.addi16sp sp, 16
    CHECK   sp, 0x2010
    li      sp, 0x2000
    c.addi16sp sp, 32
    CHECK   sp, 0x2020
    li      sp, 0x2000
    c.addi16sp sp, 64
    CHECK   sp, 0x2040
    li      sp, 0x2000
    c.addi16sp sp, 128
    CHECK   sp, 0x2080
    li      sp, 0x2000
    c.addi16sp sp, 256
    CHECK   sp, 0x2100
    li      sp, 0x2000
    c.addi16sp sp, -512              # nzimm bit9 (sign) -> sp = 0x1E00
    CHECK   sp, 0x1E00

    # ===== c.li : nzimm6 sext (CI)
    c.li    a0, 31
    CHECK   a0, 31
    c.li    a0, -1
    CHECK   a0, 0xFFFFFFFF
    c.li    a0, -32
    CHECK   a0, 0xFFFFFFE0

    # ===== c.addi : nzimm6 sext on a known base (CI)
    li      a0, 0x1000
    c.addi  a0, 5
    CHECK   a0, 0x1005
    li      a0, 0x1000
    c.addi  a0, -8
    CHECK   a0, 0x0FF8

    # ===== c.lui : nzimm6 sext << 12 (CI)
    c.lui   a0, 1
    CHECK   a0, 0x1000
    c.lui   a0, 0x1F
    CHECK   a0, 0x1F000
    lui     a0, 0xFFFE0           # c.lui nzimm6=0x20(sext -32) -> 0xFFFE0000
    CHECK   a0, 0xFFFE0000

    # ===== c.andi : imm6 sext (CB) -- rd' = rs1' = a0
    li      a0, 0xFF
    c.andi  a0, 1
    CHECK   a0, 0x1
    li      a0, 0xFF
    c.andi  a0, 0x1F
    CHECK   a0, 0x1F
    li      a0, 0xFF
    c.andi  a0, -32              # sext -> 0xFFFFFFE0 ; & 0xFF = 0xE0
    CHECK   a0, 0xE0
    li      a0, 0xFF
    c.andi  a0, -1               # sext -> -1
    CHECK   a0, 0xFF

    # ===== c.srli : shamt (CB) -- rd' = rs1' = a0
    li      a0, 0xFFFFFFFF
    c.srli  a0, 1
    CHECK   a0, 0x7FFFFFFF
    li      a0, 0xFFFFFFFF
    c.srli  a0, 5
    CHECK   a0, 0x07FFFFFF
    li      a0, 0xFFFFFFFF
    c.srli  a0, 15
    CHECK   a0, 0x0001FFFF
    li      a0, 0xFFFFFFFF
    c.srli  a0, 31
    CHECK   a0, 0x00000001

    # ===== c.srai : arithmetic shamt (CB) -- rd' = rs1' = a0
    li      a0, 0x80000000
    c.srai  a0, 1
    CHECK   a0, 0xC0000000
    li      a0, 0x80000000
    c.srai  a0, 5
    CHECK   a0, 0xFC000000
    li      a0, 0x80000000
    c.srai  a0, 15
    CHECK   a0, 0xFFFF0000
    li      a0, 0x80000000
    c.srai  a0, 31
    CHECK   a0, 0xFFFFFFFF

    # ===== c.sw / c.lw : uimm[5:3|2|6] (CL/CS) round-trip -- base a1
    li      a1, 0x2100
    li      a0, 0x12345678
    c.sw    a0, 4(a1)
    c.lw    a2, 4(a1)
    CHECK   a2, 0x12345678
    li      a0, 0x12345678
    c.sw    a0, 8(a1)
    c.lw    a2, 8(a1)
    CHECK   a2, 0x12345678
    li      a0, 0x12345678
    c.sw    a0, 16(a1)
    c.lw    a2, 16(a1)
    CHECK   a2, 0x12345678
    li      a0, 0x12345678
    c.sw    a0, 32(a1)
    c.lw    a2, 32(a1)
    CHECK   a2, 0x12345678
    li      a0, 0x12345678
    c.sw    a0, 64(a1)
    c.lw    a2, 64(a1)
    CHECK   a2, 0x12345678

    # ===== c.swsp / c.lwsp : uimm[5|4:2|7:6] / [5:2|7:6] (CSS/CI) -- base sp
    li      sp, 0x2100
    li      a0, 0xDEADBEEF
    c.swsp  a0, 4(sp)
    c.lwsp  a3, 4(sp)
    CHECK   a3, 0xDEADBEEF
    li      a0, 0xDEADBEEF
    c.swsp  a0, 8(sp)
    c.lwsp  a3, 8(sp)
    CHECK   a3, 0xDEADBEEF
    li      a0, 0xDEADBEEF
    c.swsp  a0, 16(sp)
    c.lwsp  a3, 16(sp)
    CHECK   a3, 0xDEADBEEF
    li      a0, 0xDEADBEEF
    c.swsp  a0, 32(sp)
    c.lwsp  a3, 32(sp)
    CHECK   a3, 0xDEADBEEF
    li      a0, 0xDEADBEEF
    c.swsp  a0, 64(sp)
    c.lwsp  a3, 64(sp)
    CHECK   a3, 0xDEADBEEF
    li      a0, 0xDEADBEEF
    c.swsp  a0, 128(sp)
    c.lwsp  a3, 128(sp)
    CHECK   a3, 0xDEADBEEF

    # ===== c.j : imm[11:1] (CJ) -- each offset set alone, skip-over-fail test
    # c.j over a "fail flag" write; if the jump lands short/long, t2 != 0 -> bad.
    JTEST   4
    JTEST   8
    JTEST   16
    JTEST   32
    JTEST   64
    JTEST   128
    JTEST   256
    JTEST   512
    JTEST   1024

    # c.j imm[11] (sign bit): backward -2046. A 32-bit `j` skips the pad the
    # first time; the c.j then jumps back to land, which clears the flag.
    # (-2048 is the c.j min but GAS expands the explicit c.j there to a
    # 32-bit jal; -2046 still sets imm[11] and stays a 2-byte c.j.)
    c.li    t2, 1                  # preset FAIL
    j       jb_do
jback_target:                      # landing (2046 bytes before the c.j)
    c.li    t2, 0                  # reached -> pass
    c.j     jb_cont
    .rept   1021
    c.nop
    .endr
jb_do:
    c.j     jback_target           # offset = -2046 (imm[11]=1)
jb_cont:
    bne     t2, x0, bad

    # ===== c.jal : imm[11:1] (CJ) + ra = PC+2 check
    JALTEST 32
    JALTEST 128
    JALTEST 1024

    # ===== c.beqz : imm[8:1] (CB) -- a0=0 so taken; skip-over-fail
    BEQZTEST 4
    BEQZTEST 8
    BEQZTEST 16
    BEQZTEST 32
    BEQZTEST 64
    BEQZTEST 128
    BEQZTEST 256

    # ===== c.bnez : imm[8:1] (CB) -- a0=1 so taken; skip-over-fail
    BNEZTEST 4
    BNEZTEST 32
    BNEZTEST 128
    BNEZTEST 256

    # ===== all checks passed =====
    li      t0, 0x2000
    li      t1, 0x600D
    sw      t1, 0(t0)
park:
    j       park

bad:
    li      t0, 0x2000
    li      t1, 0xBAD
    sw      t1, 0(t0)
badpark:
    j       badpark

trap_handler:
    li      t0, 0x2000
    li      t1, 0xBAD
    sw      t1, 0(t0)
th_park:
    j       th_park