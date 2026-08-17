/*
 * Startup for sim C programs (freestanding, rv32imac).
 *
 * _start is the reset entry (the CPU boots at 0x0; link.ld places
 * .text.init, and thus _start, at 0x0). It sets up the stack pointer and
 * calls main(); main() returns into an infinite loop (there is no exit
 * mechanism on this core).
 *
 * The LSU is live and the shared imem bus carries von Neumann data (loads
 * and stores retire through it; fetch and the LSU share one port via
 * mem_arbiter). Stack spill/fill and .data globals therefore work. The
 * peri (MMIO) bus slave is still tied off, so code that targets the peri
 * address region stalls the LSU; keep programs in the mem region.
 */

    .section .text.init, "ax"
    .global _start
_start:
    li      sp, 0x10000          /* top of the 64 KiB image; stack grows down */
    call    main
1:  j       1b                   /* main returns here; loop forever */