/*
 * Startup for the 2 KiB boot ROM.
 *
 * Not common/start.S, for one reason: the stack. The shared startup loads
 * sp = 0x4000, the top of the 16 KiB D-mem of a normal Harvard image. Here
 * code and data share ONE 2 KiB memory, so 0x4000 is 6 KiB past its end --
 * and the memory decodes only its own address bits, so every push would alias
 * silently back over the boot ROM's own code and data instead of faulting.
 * sp comes from __stack_top (bootrom_link.ld), the top of the real memory,
 * and the script's ASSERT keeps STACK_SIZE clear below it.
 *
 * Otherwise identical in duty to the shared file: set sp, zero .bss, zero the
 * argc/argv registers, call main, park.
 */

    .section .text.init, "ax"
    .global _start
_start:
    la      sp, __stack_top      /* top of the 2 KiB boot ROM; grows down */

    /* Zero .bss. Nothing else does: the section is NOBITS, so it is not part
     * of the image loaded into the memory, and on hardware its words come up
     * holding whatever the BSRAM powered up with. In simulation they read as
     * zero, which is what makes this class of bug invisible until silicon.
     * The linker script word-aligns both ends, so this stores words, and it
     * emits __bss_start == __bss_end when there is no .bss -- then the loop
     * body never runs. */
    la      t0, __bss_start
    la      t1, __bss_end
1:  bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:

    li      a0, 0                /* argc = 0 */
    li      a1, 0                /* argv = NULL */

    call    main
1:  j       1b                   /* main returns here; park */
