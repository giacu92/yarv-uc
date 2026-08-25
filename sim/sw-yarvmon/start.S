/*
 * Startup for sim C programs (freestanding, rv32imac).
 *
 * _start is the reset entry (the CPU boots at 0x0; link.ld places
 * .text.init, and thus _start, at IMEM 0x0). It sets up the stack pointer
 * and calls main(); main() returns into an infinite loop (there is no
 * exit mechanism on this core).
 *
 * Harvard: fetch reads the dedicated I-mem (this image, IMEM 0-based);
 * the LSU reads/writes the dedicated D-mem (DMEM 0-based), where .data
 * globals and the stack live. sp = 0x4000 is the top of the 16 KiB
 * D-mem; the stack grows down from there. It must stay inside that
 * range: the D-mem decodes only ADDR_W bits, so a pointer above the top
 * aliases silently back into the data it is meant to sit clear of. The peri (MMIO) bus slave is
 * still tied off, so code that targets the peri address region stalls
 * the LSU; keep programs in the dmem region.
 */

    .section .text.init, "ax"
    .global _start
_start:
    li      sp, 0x4000           /* top of the 16 KiB D-mem; stack grows down */
    call    main
1:  j       1b                   /* main returns here; loop forever */