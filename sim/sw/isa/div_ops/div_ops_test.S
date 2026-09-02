/* M-extension divide oracle -- DIV / DIVU / REM / REMU.
 *
 * Why it exists: nothing in the tree tested the divider directly. mul_ops
 * covers the multiply half of the M extension; DIV/REM were only ever
 * exercised incidentally by quicksort / CoreMark / Dhrystone, which between
 * them emit a handful of ordinary positive divisions and never a division by
 * zero, never a signed overflow, and never an unsigned divisor above 2^31.
 * Three properties of alu.sv's restoring divider are invisible to those:
 *
 *   1. THE SIGN ON THE DIVIDE-BY-ZERO PATH. The divider stores abs(rs1) and
 *      re-applies the sign to the RESULT. RISC-V requires REM rd, rs1, 0 to
 *      return rs1 unchanged -- sign included -- so the by-zero path has to
 *      re-apply the sign too. It did not (found 2026-09-02): REM -5, 0
 *      returned +5. DIV by zero must NOT re-apply it (the answer is -1
 *      whatever the dividend's sign), so the two paths differ and a single
 *      shared negate has to be gated correctly. Vector "-5 / 0" is the one
 *      that pins this; "5 / 0" and "INT_MIN / 0" pin the two neighbours.
 *
 *   2. THE 32-BIT PARTIAL REMAINDER. rem_part is 32 bits wide, so bit 32 of
 *      2*rem + next_bit is DROPPED. That is only sound because the partial
 *      remainder after k iterations is below 2^k as well as below the
 *      divisor -- a bound that comes from the 32-bit dividend and the
 *      32-iteration count, NOT from the divisor. So an unsigned divisor
 *      above 2^31, where the final remainder itself exceeds 2^31, is the
 *      shape that would expose a widened dividend or a changed iteration
 *      count. Vectors with divisor 0xFFFFFFFF / 0x80000000 cover it.
 *
 *   3. SIGNED OVERFLOW. INT_MIN / -1 must give DIV = INT_MIN and REM = 0
 *      with no special case in the RTL (abs(INT_MIN) is INT_MIN again).
 *
 * Every vector runs all four forms on the same operand pair, so a vector
 * cannot pass while only one form is right. All expected values below are
 * the RISC-V M-extension reference results.
 *
 * A mtvec handler writes 0xBAD and parks, so a trap is a FAIL rather than a
 * hang. Pass marker: 0x600D at D-mem 0x2000 (= sim probe word 0x800).
 */

    .section .text.init, "ax"

    # CHECK reg, expect : bne reg, expect -> bad
    .macro  CHECK reg, expect
    li      t1, \expect
    bne     \reg, t1, bad
    .endm

    # DIVCASE a, b, e_div, e_divu, e_rem, e_remu
    # Loads the operands once and runs all four forms, back to back -- which
    # also exercises re-launching the divider FSM on the cycle after it
    # reported done.
    .macro  DIVCASE a, b, e_div, e_divu, e_rem, e_remu
    li      a0, \a
    li      a1, \b
    div     a2, a0, a1
    CHECK   a2, \e_div
    divu    a2, a0, a1
    CHECK   a2, \e_divu
    rem     a2, a0, a1
    CHECK   a2, \e_rem
    remu    a2, a0, a1
    CHECK   a2, \e_remu
    .endm

    .globl _start
_start:
    la      t0, trap_handler
    csrw    mtvec, t0

    # ===== 100 / 7 -- ordinary positives
    #   div 0x0000000E  divu 0x0000000E  rem 0x00000002  remu 0x00000002
    DIVCASE 0x00000064, 0x00000007, 0x0000000E, 0x0000000E, 0x00000002, 0x00000002
    # ===== -100 / 7 -- negative dividend: DIV truncates toward zero, REM takes the dividend's sign
    #   div 0xFFFFFFF2  divu 0x24924916  rem 0xFFFFFFFE  remu 0x00000002
    DIVCASE 0xFFFFFF9C, 0x00000007, 0xFFFFFFF2, 0x24924916, 0xFFFFFFFE, 0x00000002
    # ===== 100 / -7 -- negative divisor
    #   div 0xFFFFFFF2  divu 0x00000000  rem 0x00000002  remu 0x00000064
    DIVCASE 0x00000064, 0xFFFFFFF9, 0xFFFFFFF2, 0x00000000, 0x00000002, 0x00000064
    # ===== -100 / -7 -- both negative
    #   div 0x0000000E  divu 0x00000000  rem 0xFFFFFFFE  remu 0xFFFFFF9C
    DIVCASE 0xFFFFFF9C, 0xFFFFFFF9, 0x0000000E, 0x00000000, 0xFFFFFFFE, 0xFFFFFF9C
    # ===== INT_MIN / -1 -- signed overflow: DIV = INT_MIN, REM = 0
    #   div 0x80000000  divu 0x00000000  rem 0x00000000  remu 0x80000000
    DIVCASE 0x80000000, 0xFFFFFFFF, 0x80000000, 0x00000000, 0x00000000, 0x80000000
    # ===== INT_MIN / 1
    #   div 0x80000000  divu 0x80000000  rem 0x00000000  remu 0x00000000
    DIVCASE 0x80000000, 0x00000001, 0x80000000, 0x80000000, 0x00000000, 0x00000000
    # ===== INT_MIN / INT_MAX
    #   div 0xFFFFFFFF  divu 0x00000001  rem 0xFFFFFFFF  remu 0x00000001
    DIVCASE 0x80000000, 0x7FFFFFFF, 0xFFFFFFFF, 0x00000001, 0xFFFFFFFF, 0x00000001
    # ===== INT_MAX / -1
    #   div 0x80000001  divu 0x00000000  rem 0x00000000  remu 0x7FFFFFFF
    DIVCASE 0x7FFFFFFF, 0xFFFFFFFF, 0x80000001, 0x00000000, 0x00000000, 0x7FFFFFFF
    # ===== 5 / 0 -- division by zero, positive dividend
    #   div 0xFFFFFFFF  divu 0xFFFFFFFF  rem 0x00000005  remu 0x00000005
    DIVCASE 0x00000005, 0x00000000, 0xFFFFFFFF, 0xFFFFFFFF, 0x00000005, 0x00000005
    # ===== -5 / 0 -- division by zero, NEGATIVE dividend: REM must return the dividend UNCHANGED (sign included)
    #   div 0xFFFFFFFF  divu 0xFFFFFFFF  rem 0xFFFFFFFB  remu 0xFFFFFFFB
    DIVCASE 0xFFFFFFFB, 0x00000000, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFB, 0xFFFFFFFB
    # ===== INT_MIN / 0
    #   div 0xFFFFFFFF  divu 0xFFFFFFFF  rem 0x80000000  remu 0x80000000
    DIVCASE 0x80000000, 0x00000000, 0xFFFFFFFF, 0xFFFFFFFF, 0x80000000, 0x80000000
    # ===== 0 / 0
    #   div 0xFFFFFFFF  divu 0xFFFFFFFF  rem 0x00000000  remu 0x00000000
    DIVCASE 0x00000000, 0x00000000, 0xFFFFFFFF, 0xFFFFFFFF, 0x00000000, 0x00000000
    # ===== 0 / 5
    #   div 0x00000000  divu 0x00000000  rem 0x00000000  remu 0x00000000
    DIVCASE 0x00000000, 0x00000005, 0x00000000, 0x00000000, 0x00000000, 0x00000000
    # ===== 1 / 2 -- quotient 0, remainder = dividend
    #   div 0x00000000  divu 0x00000000  rem 0x00000001  remu 0x00000001
    DIVCASE 0x00000001, 0x00000002, 0x00000000, 0x00000000, 0x00000001, 0x00000001
    # ===== -1 / -1 signed; 0xFFFFFFFF / 0xFFFFFFFF unsigned
    #   div 0x00000001  divu 0x00000001  rem 0x00000000  remu 0x00000000
    DIVCASE 0xFFFFFFFF, 0xFFFFFFFF, 0x00000001, 0x00000001, 0x00000000, 0x00000000
    # ===== divisor 0xFFFFFFFF: unsigned remainder 0xFFFFFFFE, above 2^31
    #   div 0x00000002  divu 0x00000000  rem 0x00000000  remu 0xFFFFFFFE
    DIVCASE 0xFFFFFFFE, 0xFFFFFFFF, 0x00000002, 0x00000000, 0x00000000, 0xFFFFFFFE
    # ===== divisor exactly 2^31
    #   div 0x00000000  divu 0x00000001  rem 0xFFFFFFFF  remu 0x7FFFFFFF
    DIVCASE 0xFFFFFFFF, 0x80000000, 0x00000000, 0x00000001, 0xFFFFFFFF, 0x7FFFFFFF
    # ===== dividend 2^31, divisor 0xFFFFFFFF
    #   div 0x80000000  divu 0x00000000  rem 0x00000000  remu 0x80000000
    DIVCASE 0x80000000, 0xFFFFFFFF, 0x80000000, 0x00000000, 0x00000000, 0x80000000
    # ===== alternating dividend, divisor 0xFFFFFFFF
    #   div 0x55555556  divu 0x00000000  rem 0x00000000  remu 0xAAAAAAAA
    DIVCASE 0xAAAAAAAA, 0xFFFFFFFF, 0x55555556, 0x00000000, 0x00000000, 0xAAAAAAAA
    # ===== 1 / 0xFFFFFFFF -- quotient 0 for 32 iterations
    #   div 0xFFFFFFFF  divu 0x00000000  rem 0x00000000  remu 0x00000001
    DIVCASE 0x00000001, 0xFFFFFFFF, 0xFFFFFFFF, 0x00000000, 0x00000000, 0x00000001
    # ===== 0xFFFFFFFF / 2 -- unsigned, top dividend bit set
    #   div 0x00000000  divu 0x7FFFFFFF  rem 0xFFFFFFFF  remu 0x00000001
    DIVCASE 0xFFFFFFFF, 0x00000002, 0x00000000, 0x7FFFFFFF, 0xFFFFFFFF, 0x00000001
    # ===== power-of-two divisor
    #   div 0x00012345  divu 0x00012345  rem 0x00000678  remu 0x00000678
    DIVCASE 0x12345678, 0x00001000, 0x00012345, 0x00012345, 0x00000678, 0x00000678

    # ===== rd == rs1 and rd == rs2: the result must not be read after its
    # own operand register has been overwritten.
    li      a0, 0xFFFFFF9C          # -100
    li      a1, 0x00000007
    div     a0, a0, a1
    CHECK   a0, 0xFFFFFFF2          # -14
    li      a0, 0xFFFFFF9C
    li      a1, 0x00000007
    rem     a1, a0, a1
    CHECK   a1, 0xFFFFFFFE          # -2

    # ===== distance-1 forward into a divide operand. The forward path feeds
    # the divider's launch-cycle abs() directly, so a stale operand is
    # latched into div_a_q / div_divisor_q and never recovers.
    li      a0, 0x00000064          # 100
    addi    a1, a0, -0x5D           # a1 = 7, forwarded
    div     a2, a0, a1
    CHECK   a2, 0x0000000E          # 14
    li      a0, 0x000000C8          # 200
    addi    a1, a0, -0x00C1         # a1 = 7, forwarded
    remu    a2, a0, a1
    CHECK   a2, 0x00000004          # 200 % 7

    # ===== distance-1 forward OUT of a divide: the quotient is consumed the
    # cycle it retires, which is the load-use-shaped hazard on the div path.
    li      a0, 0x000003E8          # 1000
    li      a1, 0x00000003
    div     a2, a0, a1              # 333
    addi    a3, a2, 1
    CHECK   a3, 0x0000014E          # 334

    # ===== back-to-back divides with no instruction between them (the FSM
    # must return to DIV_IDLE and re-arm, not re-run the previous operands).
    li      a0, 0x00000064
    li      a1, 0x00000007
    div     a2, a0, a1
    div     a3, a1, a0
    CHECK   a2, 0x0000000E
    CHECK   a3, 0x00000000

    # ===== a branch that depends on a quotient (resolve must wait for the
    # divider, not sample an unready result)
    li      a0, 0x00000064
    li      a1, 0x00000032          # 50
    div     a2, a0, a1              # 2
    li      t2, 2
    bne     a2, t2, bad

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
