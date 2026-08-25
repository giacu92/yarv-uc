/*
 * Instruction-access-fault oracle.
 *
 * Jumps to an address outside the implemented I-mem and checks that the
 * core takes a precise trap for it: mcause = 1 (instruction access fault)
 * and mtval = the address that could not be fetched. Before the fault path
 * existed, that jump kept executing: GowinSynthesis sizes an inferred ROM
 * from its $readmemh content, so the fetch aliased back into the image and
 * ran plausible instructions with nothing reporting a problem.
 *
 * The handler does not return to the faulting address -- there is nothing
 * there to retry. It steps to a known label instead, which is also what a
 * real handler would do.
 *
 * Result: 0x600D at D-mem 0x2000 on pass, 0xBAD on failure. No toolchain
 * features beyond the assembler; built like the other .S oracles.
 */

    .equ DMEM_RESULT, 0x2000
    .equ BAD_ADDR,    0x00100000   /* 1 MiB: far outside a 16 KiB I-mem */

    .section .text.init, "ax"
    .global _start
_start:
    li      sp, 0x4000
    li      t3, 0                      /* fault count */
    li      t4, 0                      /* observed mcause */
    li      t5, 0                      /* observed mtval  */

    la      t0, trap_handler
    csrw    mtvec, t0

    /* Jump out of the implemented I-mem. */
    li      t0, BAD_ADDR
    jalr    t0

resume:
    /* Checks: exactly one fault, cause 1, mtval = the address jumped to. */
    li      t0, 0x600D
    li      t1, 1
    bne     t3, t1, fail
    li      t1, 1
    bne     t4, t1, fail
    li      t1, BAD_ADDR
    bne     t5, t1, fail
    j       done

fail:
    li      t0, 0xBAD
done:
    li      t1, DMEM_RESULT
    sw      t0, 0(t1)
1:  j       1b

    .balign 4
trap_handler:
    csrr    t4, mcause
    csrr    t5, mtval
    addi    t3, t3, 1
    /* Do not mret to mepc: the faulting address is still unfetchable. Go
     * to a known good label instead. */
    la      t6, resume
    csrw    mepc, t6
    mret
