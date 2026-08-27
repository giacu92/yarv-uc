/* Linker script for Dhrystone: the common one with DMEM ORIGIN moved to 0.
 *
 *   IMEM (rx)  : ORIGIN = 0x0000, LENGTH = 16K  -> .text.init + .text
 *   DMEM (rwx) : ORIGIN = 0x0000, LENGTH = 16K  -> .rodata + .data + .bss
 *                                                  + stack
 *
 * Why this harness cannot use common/link.ld: Dhrystone's Arr_2_Glob is
 * `int [50][50]`, 10 000 bytes of .bss on its own, and Arr_1_Glob adds 200
 * more. common/link.ld starts DMEM at 0x2000 and so has 8 KiB for
 * .rodata + .data + .bss AND the stack -- the array alone does not fit.
 * The array size is part of the benchmark, so the memory has to move, not
 * the workload. Starting DMEM at 0 gives the full 16 KiB the D-mem
 * physically has (ADDR_W = 14), which leaves roughly 3.5 KiB of stack
 * below sp = 0x4000. Dhrystone does not recurse and its deepest frame is a
 * couple of Str_30 buffers, so that is ample.
 *
 * What it costs: the Spike co-sim. Spike is von-Neumann -- one address
 * space -- and this core boots at 0, so .text must be at VMA 0 there too.
 * With .data also at 0 the two overlap and no co-simulation is possible.
 * common/link.ld's 0x2000 split exists precisely to keep them disjoint;
 * quicksort and CoreMark are co-simulated, Dhrystone is not. See
 * sifive/UPSTREAM.md.
 *
 * Everything else is common/link.ld verbatim: the small-data collection,
 * the word-aligned __bss_start/__bss_end that start.S clears, medlow
 * absolute addressing, and the discarded metadata. The reasoning for each
 * is in common/link.ld and is not repeated here.
 */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    IMEM (rx)  : ORIGIN = 0x00000000, LENGTH = 16K
    DMEM (rwx) : ORIGIN = 0x00000000, LENGTH = 16K
}

SECTIONS
{
    .text : {
        KEEP(*(.text.init))   /* _start first -> IMEM 0x0 */
        *(.text*)
    } > IMEM

    /* .rodata is placed first, so nothing this program takes the address of
     * lands at D-mem 0. Dhrystone compares a Rec_Pointer against Null (0),
     * and the malloc pool it allocates from lives in .bss at the far end. */
    .rodata : { *(.rodata*) *(.srodata*) } > DMEM
    .data   : { *(.data*) *(.sdata*) }     > DMEM
    . = ALIGN(4);
    __bss_start = .;
    .bss    : { *(.bss*) *(.sbss*) *(COMMON) } > DMEM
    . = ALIGN(4);
    __bss_end = .;

    /* The stack grows down from sp = 0x4000 (set by common/start.S, the top
     * of the 16 KiB D-mem). Fail the link rather than let .bss grow into
     * it: an overlap here is silent at run time -- the array simply shares
     * words with the stack and Dhrystone's final-value checks start
     * disagreeing for no visible reason. */
    __stack_top   = 0x4000;
    __stack_limit = __stack_top - 0x400;   /* keep 1 KiB clear */
    ASSERT(__bss_end <= __stack_limit,
           "dhrystone: .rodata + .data + .bss leaves under 1 KiB of stack")

    /DISCARD/ : {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
        *(.riscv.attributes)
    }
}
