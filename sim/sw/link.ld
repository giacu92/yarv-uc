/* Linker script for sim programs: place everything at the CPU boot
 * address (0x0000_0000) inside the 64 KiB instruction RAM. The CPU boots
 * at 0x0 (top_module / sim_top boot_addr_i = 0), so _start (in .text.init,
 * placed first) must land at 0x0.
 *
 * This is a freestanding image: no crt0, no libc, no runtime. The startup
 * in start.S is the only entry code. .bss is NOT zeroed at runtime (the
 * core has no LSU / data memory yet), so keep programs free of zero-init
 * globals until the LSU lands.
 */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    RAM (rwxa) : ORIGIN = 0x00000000, LENGTH = 64K
}

SECTIONS
{
    .text : {
        KEEP(*(.text.init))   /* _start first -> address 0x0 */
        *(.text*)
    } > RAM

    .rodata : { *(.rodata*) } > RAM
    .data   : { *(.data*) }   > RAM
    .bss    : { *(.bss*) *(COMMON) } > RAM

    /* Drop metadata that has no place in a flat image. */
    /DISCARD/ : {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
        *(.riscv.attributes)
    }
}