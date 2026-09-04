/* Linker script for the riscv-tests ISA suite on this Harvard core.
 *
 * Replaces riscv-tests' env/p/link.ld, which lays code, tohost and data out
 * consecutively in one address space at 0x8000_0000. That layout has no
 * meaning here: fetch reads a dedicated read-only I-mem based at 0 and the
 * LSU reads a dedicated D-mem based at 0x2000, and the two images are loaded
 * separately ($readmemh of build/imem.hex and build/dmem.hex).
 *
 *   IMEM (rx) : ORIGIN = 0x0000, LENGTH = 16K  -> .text.init + .text
 *   DMEM (rw) : ORIGIN = 0x2000, LENGTH = 8K   -> .tohost + .data + .bss
 *
 * This mirrors sim/sw/common/link.ld (the layout every other firmware image
 * in the tree uses) with one addition that the test protocol depends on:
 *
 *   .tohost IS PLACED FIRST IN THE DMEM REGION, so `tohost` is always at
 *   0x2000 whatever the test. That is what makes a single fixed
 *   PROBE=0x2000 read the verdict of all ~70 tests -- the runner does not
 *   have to parse a symbol table per test. The section carries its own
 *   `.align 6` (from RVTEST_DATA_BEGIN); 0x2000 is 64-byte aligned, so the
 *   directive is a no-op and does not push tohost off the origin.
 *
 * It is folded into the OUTPUT section named .data rather than kept as its
 * own output section because sw_build.mk builds the data image with
 * `objcopy -O binary -j .rodata -j .data`: an output section named anything
 * else would simply be dropped from dmem.hex, and every test would then read
 * back tohost == 0 (i.e. "hung") no matter what it actually did.
 *
 * medlow (the gcc default; no -mcmodel here, and NOT upstream's -mcmodel=
 * medany) is required: data symbols must be reached by absolute lui+addi so
 * the address lands in the D-mem. A PC-relative auipc form computed from
 * .text would address the I-mem instead.
 *
 * The tests do not use a stack -- upstream's p environment never sets sp
 * either, and the test macros clobber x2 as an ordinary source register --
 * so no stack is reserved and .bss is present only for completeness.
 */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    IMEM (rx) : ORIGIN = 0x00000000, LENGTH = 16K
    DMEM (rw) : ORIGIN = 0x00002000, LENGTH = 8K
}

SECTIONS
{
    .text : {
        KEEP(*(.text.init))       /* _start -> IMEM 0x0 */
        *(.text .text.*)
        . = ALIGN(4);
    } > IMEM

    .data : {
        KEEP(*(.tohost))          /* tohost -> DMEM 0x2000, see above */
        *(.data .data.*)
        /* gcc's -msmall-data-limit default puts objects in .sdata/.srodata;
         * collect them here or objcopy -j .data silently drops them. */
        *(.sdata .sdata.* .sdata2*)
        *(.rodata .rodata.* .srodata*)
        . = ALIGN(4);
    } > DMEM

    .bss (NOLOAD) : {
        *(.bss .bss.* .sbss .sbss.*)
        *(COMMON)
        . = ALIGN(4);
    } > DMEM

    /DISCARD/ : {
        *(.comment)
        *(.note .note.*)
        *(.riscv.attributes)
        *(.eh_frame .eh_frame_hdr)
    }
}
