/* Sync-trap cosim probe (rv32imac_zicsr_zifencei, M-mode). A minimal
 * program that exercises an illegal-instruction sync trap + mret return,
 * so the RTL retire/PC stream can be diffed against Spike (the golden ISA
 * ref).
 *
 * Why illegal (not ecall): Spike hijacks an M-mode ecall as the htif
 * host-call (exit) mechanism -- there is no tohost, so Spike stops at the
 * ecall instead of taking it as a normal M-mode trap. An illegal
 * instruction traps to mtvec in both models with no hijack. The MSIP
 * software interrupt is also not Spike-comparable (Spike has no slave at
 * our MSIP MMIO address 0x1000_0000), so it is exercised only by the
 * standalone sw_trap oracle, not here.
 *
 * Flow: set mtvec (direct) -> illegal instr (.word 0, traps, NOT retired
 * -- no commit line in either model) -> handler (csrr mcause/mepc,
 * advance mepc +4 to skip the faulting instr, store marker, mret) ->
 * store sentinel -> park self-loop. Both models run the same binary, so
 * per-retire (pc, rd, val) must match.
 */
    .section .text.init, "ax"
    .global _start
_start:
    li      sp, 0x10000
    la      t0, trap_handler
    csrw    mtvec, t0
    .word   0x0000007f          /* illegal (opcode 0x7f) -> trap, not retired */
    /* handler returns here (mepc advanced +4 past the faulting word) */
    li      t0, 0x2000
    li      t1, 0x600D
    sw      t1, 0(t0)
park:
    j       park

    .align 2
trap_handler:
    csrr    t0, mcause
    csrr    t1, mepc
    addi    t1, t1, 4
    csrw    mepc, t1
    li      t3, 0x2000
    li      t4, 0x2             /* illegal-cause marker */
    sw      t4, 0(t3)
    mret