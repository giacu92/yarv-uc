/* Branch-predictor correctness oracle (gshare PHT + RAS, prediction-at-decode).
 *
 * No existing oracle/cosim exercises the predictor's architectural-invisibility
 * invariant directly: a prediction may mispredict as often as it likes, but it
 * must NEVER change architectural state -- only performance. A flush/recovery
 * or hold-buffer bug (the kind that bit the sequential-span fall-through after a
 * predicted-taken branch) lets a wrong-path instruction retire and corrupt a
 * register, which a retire-by-retire cosim can miss if the wrong-path writeback
 * coincidentally matches the golden value at that retire index.
 *
 * Each case computes a known result with a distinctive control-flow shape and
 * self-checks it with CHECK. A mtvec handler catches any stray trap as FAIL
 * (0xBAD) -- except the one expected ecall in case 9, which it resumes. Pass
 * marker: 0x600D at D-mem 0x2000 (= sim probe word 0x800).
 *
 * Cases (what they exercise):
 *   1  always-taken loop            PHT trains to strongly-taken
 *   2  never-taken branch           PHT trains to strongly-NT; a wrong
 *                                   predicted-taken must flush to fall-through
 *   3  T...T NT loop exit           mispredict at loop exit -> redirect to
 *                                   fall-through (the recovery path)
 *   4  alternating inner branch     2-bit counter + gshare on a 50% branch
 *   5  nested correlated branches   two branches sharing GHR history
 *   6  RVC branch loop (c.bnez)     compressed branch at PC[1], seq +2
 *   7  nested JAL call / JALR ret   RAS push (call) + pop (return), depth 2
 *   8  loop-exit mispredict,        drain 2 outstanding fetch reads on
      long body                     mispredict, no stale buffer entry consumed
 *   9  ecall trap vs predicted      sync trap on an older instr (ecall in
      branch                         execute) overrides a younger decode
 *                                   prediction -> trap > mispredict > predict
 *
 * -march=rv32imac_zicsr_zifencei: c.addi / c.bnez + the CSR ops for mtvec /
 * mepc / mcause. Pure assembly with its own _start.
 */

    .section .text.init, "ax"

    # CHECK reg, expect : li t1, expect ; bne reg, t1, bad
    .macro  CHECK reg, expect
    li      t1, \expect
    bne     \reg, t1, bad
    .endm

    .globl _start
_start:
    li      sp, 0x4000              # stack at top of 16 KiB D-mem (case 7
                                    # pushes ra; the pass marker lives at 0x2000)
    la      t0, trap_handler
    csrw    mtvec, t0
    li      t2, 0                   # case-9 trap marker (0 = no expected trap)

    # ===== Case 1: always-taken loop -> a0 == 16 =====
    li      a0, 0
    li      t0, 16
loop1:
    addi    a0, a0, 1
    blt     a0, t0, loop1           # taken 15x, NT at a0==16
    CHECK   a0, 16

    # ===== Case 2: never-taken branch -> a0 == 5 =====
    # A wrong predicted-taken here must be flushed back to the fall-through.
    li      a0, 5
    li      t0, 100
    bge     a0, t0, bad             # 5 >= 100 ? never -> NT; pred-taken flushes
    CHECK   a0, 5

    # ===== Case 3: T...T NT loop exit -> a0 == 8 =====
    li      a0, 0
    li      t0, 8
loop3:
    addi    a0, a0, 1
    blt     a0, t0, loop3           # taken 7x, NT at a0==8 (mispredict at exit)
    CHECK   a0, 8

    # ===== Case 4: alternating inner branch -> a0 == 0x55 =====
    # Inner beqz alternates T(even iter)/NT(odd iter); outer back-edge T 9x.
    li      a0, 0
    li      t1, 10
    li      t0, 0                   # iteration counter
loop4:
    andi    t2, t0, 1
    beqz    t2, took4               # even iter -> taken
    addi    a0, a0, 0x10            # odd iter: +0x10
    j       cont4
took4:
    addi    a0, a0, 0x01            # even iter: +1
cont4:
    addi    t0, t0, 1
    blt     t0, t1, loop4
    # 5 even (+1) + 5 odd (+0x10) = 5 + 0x50 = 0x55
    CHECK   a0, 0x55

    # ===== Case 5: nested correlated branches -> a0 == 0x24 =====
    li      a0, 0
    li      t1, 4
    li      t0, 0
loop5:
    addi    a0, a0, 1               # every iter: +1
    andi    t2, t0, 1
    bnez    t2, skip5               # odd iter -> skip the +0x10
    addi    a0, a0, 0x10            # even iter: +0x10
skip5:
    addi    t0, t0, 1
    blt     t0, t1, loop5
    # iters 0,1,2,3: even(0,2) +0x10 (2x=0x20); all +1 (4x=4) -> 0x24
    CHECK   a0, 0x24

    # ===== Case 6: RVC branch loop (c.bnez) -> a0 == 0 =====
    li      a0, 5
loop6:
    addi    a0, a0, -1              # gas -> c.addi (imm -1 fits nzimm)
    bnez    a0, loop6               # gas -> c.bnez (compressed, PC[1])
    # 5->4->3->2->1->0; c.bnez taken 4x, NT at 0
    CHECK   a0, 0

    # ===== Case 7: nested JAL call / JALR ret (RAS) -> a0 == 0x111 =====
    li      a0, 0
    jal     x1, f7o                 # direct call: RAS push at resolve
    CHECK   a0, 0x111
    j       case8

f7o:
    addi    a0, a0, 0x100
    addi    sp, sp, -4              # save ra: f7o calls f7i (jal x1) which
    sw      ra, 0(sp)               # overwrites ra, so f7o's own ret must
    jal     x1, f7i                 # restore it. nested call: RAS push (depth 2)
    lw      ra, 0(sp)
    addi    sp, sp, 4
    ret                            # jalr x0,x1,0 : RAS pop, predicted return
f7i:
    addi    a0, a0, 0x11
    ret                            # RAS pop, predicted return
    # a0 = 0x100 + 0x11 = 0x111

    # ===== Case 8: loop-exit mispredict, long body -> a0 == 8 =====
    # Long body keeps 2 fetch reads outstanding; exit mispredict drains them.
case8:
    li      a0, 0
    li      t0, 8
    li      a1, 0
    li      a2, 0
    li      a3, 0
loop8:
    addi    a0, a0, 1
    addi    a1, a1, 0               # filler: extends the loop body so the
    addi    a2, a2, 0               # 64-bit fetch keeps 2 reads in flight
    addi    a3, a3, 0
    blt     a0, t0, loop8           # taken 7x, NT at a0==8 (mispredict, drain)
    CHECK   a0, 8

    # ===== Case 9: ecall trap vs predicted branch -> a0 == 0x99 =====
    # ecall (in execute) traps; the younger `j c9done' (in decode) is predicted
    # taken but the sync trap wins (trap > mispredict > prediction): flush_i
    # squashes the prediction, fetch goes to mtvec. The handler advances mepc
    # past ecall and mrets; the j then re-decodes, predicts taken, runs.
    li      t2, 9                   # expected-trap marker for the handler
    ecall                         # M-mode ecall -> trap (mcause=11)
    j       c9done                  # predicted-taken; trap must squash it
c9done:
    li      t2, 0                   # clear marker (later stray traps -> FAIL)
    li      a0, 0x99
    CHECK   a0, 0x99

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

    # Handler: an expected case-9 ecall (mcause==11, t2==9) advances mepc by 4
    # and mrets; anything else is a stray trap -> FAIL. 4-aligned so mtvec
    # lands here exactly (direct-mode BASE = {mtvec[31:2],2'b00}; a 2-aligned
    # handler address would trap 2 bytes early).
    .balign 4
trap_handler:
    csrr    t0, mcause
    li      t1, 11
    bne     t0, t1, th_fail         # not ecall -> stray
    li      t1, 9
    bne     t2, t1, th_fail         # not the case-9 ecall -> stray
    csrr    t0, mepc
    addi    t0, t0, 4               # skip the ecall, resume at `j c9done'
    csrw    mepc, t0
    mret
th_fail:
    li      t0, 0x2000
    li      t1, 0xBAD
    sw      t1, 0(t0)
th_park:
    j       th_park