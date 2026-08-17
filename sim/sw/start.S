/*
 * Startup for sim C programs (freestanding, rv32imac).
 *
 * _start is the reset entry (the CPU boots at 0x0; link.ld places
 * .text.init, and thus _start, at 0x0). It sets up the stack pointer and
 * calls main(); main() returns into an infinite loop (there is no exit
 * mechanism on this core).
 *
 * NOTE on the current core (DRAFT): the peri (data) bus has no slave yet
 * and there is no LSU, so stack / data accesses are silently no-ops (a
 * store drops, a load reads 0). The sp value below is therefore
 * forward-looking — pure-register programs that never spill run fine
 * today; anything that touches memory will misbehave until the LSU + a
 * data slave land.
 */

    .section .text.init, "ax"
    .global _start
_start:
    li      sp, 0x10000          /* top of the 64 KiB image; stack grows down */
    call    main
1:  j       1b                   /* main returns here; loop forever */