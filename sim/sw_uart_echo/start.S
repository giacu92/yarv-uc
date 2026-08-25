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
 * D-mem; the stack grows down from there. It has to be a real address:
 * the D-mem decodes only ADDR_W bits, so a stack pointer above the top
 * aliases silently back into the data it is supposed to sit clear of.
 *
 * The peri (MMIO) region above PERI_ADDR_BIT is a separate space served by
 * the UART / timer / MSIP slaves, so keep ordinary data in the dmem region
 * and address peripherals only through their own base addresses.
 */

    .section .text.init, "ax"
    .global _start
_start:
    li      sp, 0x4000           /* top of the 16 KiB D-mem; stack grows down */
    call    main
1:  j       1b                   /* main returns here; loop forever */