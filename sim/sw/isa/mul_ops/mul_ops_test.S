/* M-extension multiply oracle -- MUL / MULH / MULHSU / MULHU.
 *
 * Every case is a hand-computed reference, chosen so that a wrong operand
 * sign-extension or a swapped high/low word select cannot pass:
 *
 *   - MUL's low word is signedness-independent, so it is checked separately
 *     from the three high-word forms and cannot cover them.
 *   - MULH vs MULHU differ for any operand with bit 31 set; MULHSU differs
 *     from both. Each vector below uses at least one negative operand, so
 *     the three high-word forms give three DIFFERENT answers on the same
 *     inputs -- a form that falls through to the wrong sign-extension is
 *     caught, not masked.
 *   - 0x8000_0000 (INT_MIN) appears squared and against -1, the two cases
 *     where a 32x32 signed product needs the full 33rd bit.
 *
 * Reference values (a, b as 32-bit patterns):
 *
 *   a=0x00000003 b=0x00000005
 *     mul  0x0000000F  mulh 0x00000000  mulhsu 0x00000000  mulhu 0x00000000
 *   a=0xFFFFFFFF (-1) b=0xFFFFFFFF (-1)
 *     s*s = 1                  -> mulh   0x00000000, mul 0x00000001
 *     s*u = -1 * 4294967295    = -4294967295 = 0xFFFFFFFF_00000001
 *                              -> mulhsu 0xFFFFFFFF
 *     u*u = 4294967295^2       = 0xFFFFFFFE_00000001
 *                              -> mulhu  0xFFFFFFFE
 *   a=0x80000000 (INT_MIN) b=0x80000000
 *     s*s = 2^62               = 0x40000000_00000000 -> mulh   0x40000000
 *     s*u = -2^31 * 2^31       = -2^62 = 0xC0000000_00000000
 *                              -> mulhsu 0xC0000000
 *     u*u = 2^62               = 0x40000000_00000000 -> mulhu  0x40000000
 *     mul 0x00000000
 *   a=0x80000000 b=0xFFFFFFFF
 *     s*s = -2^31 * -1 = 2^31  = 0x00000000_80000000 -> mulh   0x00000000
 *     s*u = -2^31 * 4294967295 = -9223372034707292160
 *                              = 0x80000000_80000000 -> mulhsu 0x80000000
 *     u*u = 2^31 * 4294967295  = 0x7FFFFFFF_80000000 -> mulhu  0x7FFFFFFF
 *     mul 0x80000000
 *   a=0x7FFFFFFF b=0x7FFFFFFF  (both positive: all three high forms agree)
 *     0x3FFFFFFF_00000001      -> mulh/mulhsu/mulhu 0x3FFFFFFF, mul 0x00000001
 *   a=0xFFFFFFFE (-2) b=0x00000003
 *     s*s = -6                 = 0xFFFFFFFF_FFFFFFFA -> mulh   0xFFFFFFFF
 *     s*u = -6                                       -> mulhsu 0xFFFFFFFF
 *     u*u = 4294967294*3 = 0x00000002_FFFFFFFA       -> mulhu  0x00000002
 *     mul 0xFFFFFFFA
 *   a=0x00000003 b=0xFFFFFFFE  (operands swapped: catches a/b extension mixup)
 *     s*s = -6                                       -> mulh   0xFFFFFFFF
 *     s*u = 3 * 4294967294 = 0x00000002_FFFFFFFA     -> mulhsu 0x00000002
 *     u*u = same as s*u                              -> mulhu  0x00000002
 *     mul 0xFFFFFFFA
 *
 * The last two vectors are the pair that pins MULHSU's asymmetry: MULHSU
 * treats rs1 as signed and rs2 as unsigned, so swapping the operands must
 * change its answer (0xFFFFFFFF vs 0x00000002) while MUL and MULH do not
 * move. A build that sign-extends the wrong operand passes one and fails the
 * other.
 *
 * A mtvec handler writes 0xBAD and parks, so an illegal-instruction trap
 * (e.g. an encoding the core does not decode) is a FAIL rather than a hang.
 * Pass marker: 0x600D at D-mem 0x2000 (= sim probe word 0x800).
 */

    .section .text.init, "ax"

    # CHECK reg, expect : bne reg, expect -> bad
    .macro  CHECK reg, expect
    li      t1, \expect
    bne     \reg, t1, bad
    .endm

    # MULCASE a, b, e_mul, e_mulh, e_mulhsu, e_mulhu
    # Loads the two operands once and runs all four forms on them, so a
    # vector cannot pass by accident with only one form implemented.
    .macro  MULCASE a, b, e_mul, e_mulh, e_mulhsu, e_mulhu
    li      a0, \a
    li      a1, \b
    mul     a2, a0, a1
    CHECK   a2, \e_mul
    mulh    a2, a0, a1
    CHECK   a2, \e_mulh
    mulhsu  a2, a0, a1
    CHECK   a2, \e_mulhsu
    mulhu   a2, a0, a1
    CHECK   a2, \e_mulhu
    .endm

    .globl _start
_start:
    la      t0, trap_handler
    csrw    mtvec, t0

    # ===== small positives: every form is zero in the high word
    MULCASE 0x00000003, 0x00000005, 0x0000000F, 0x00000000, 0x00000000, 0x00000000

    # ===== -1 * -1 : the three high forms give three different answers
    MULCASE 0xFFFFFFFF, 0xFFFFFFFF, 0x00000001, 0x00000000, 0xFFFFFFFF, 0xFFFFFFFE

    # ===== INT_MIN squared : needs the 33rd bit on both operands
    MULCASE 0x80000000, 0x80000000, 0x00000000, 0x40000000, 0xC0000000, 0x40000000

    # ===== INT_MIN * -1 : the classic signed-overflow corner
    MULCASE 0x80000000, 0xFFFFFFFF, 0x80000000, 0x00000000, 0x80000000, 0x7FFFFFFF

    # ===== INT_MAX squared : all three high forms must agree
    MULCASE 0x7FFFFFFF, 0x7FFFFFFF, 0x00000001, 0x3FFFFFFF, 0x3FFFFFFF, 0x3FFFFFFF

    # ===== -2 * 3 and 3 * -2 : MULHSU must change, MUL/MULH must not
    MULCASE 0xFFFFFFFE, 0x00000003, 0xFFFFFFFA, 0xFFFFFFFF, 0xFFFFFFFF, 0x00000002
    MULCASE 0x00000003, 0xFFFFFFFE, 0xFFFFFFFA, 0xFFFFFFFF, 0x00000002, 0x00000002

    # ===== rd == rs1 and rd == rs2 (the DSP result must not be read after
    # its own operand register was overwritten)
    li      a0, 0xFFFFFFFE
    li      a1, 0x00000003
    mulh    a0, a0, a1
    CHECK   a0, 0xFFFFFFFF
    li      a0, 0xFFFFFFFE
    li      a1, 0x00000003
    mulhu   a1, a0, a1
    CHECK   a1, 0x00000002

    # ===== distance-1 forward into a multiply operand (the forward path
    # feeds the DSP directly; a stale operand shows up here)
    li      a0, 0x00010000
    addi    a1, a0, 0x10           # a1 = 0x00010010, forwarded
    mulhu   a2, a0, a1             # 0x00010000 * 0x00010010 = 0x00000001_00100000
    CHECK   a2, 0x00000001
    mul     a2, a0, a1
    CHECK   a2, 0x00100000

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
