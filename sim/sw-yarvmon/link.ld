/* Linker script for Harvard sim programs: split the image across two
 * independent address spaces.
 *
 *   IMEM (rx)  : ORIGIN = 0x0000, LENGTH = 16K   -> .text.init + .text (fetch)
 *   DMEM (rwx) : ORIGIN = 0x2000, LENGTH = 8K    -> .rodata + .data + .bss
 *                                                    + stack (LSU)
 *
 * 16 KiB each is what the device holds: the GW2AR-18C has 46 BSRAM blocks,
 * 828 Kb in total, so two 64 KiB memories (1024 Kb) cannot both exist. The
 * D-mem spans 0x0000-0x3FFF and the data image starts at 0x2000, which
 * leaves 8 KiB for .rodata/.data/.bss and the stack.
 *
 * The CPU boots at 0x0 (top_module / sim_top boot_addr_i = 0); _start
 * (in .text.init, placed first) lands at IMEM 0x0. .data lands at DMEM
 * 0x2000; the stack grows down from the top of the D-mem (sp = 0x4000,
 * the 16 KiB physical BSRAM boundary; the first push lands at 0x3FFC,
 * clear of .data).
 *
 * Why DMEM ORIGIN = 0x2000 (not 0): the core is Harvard, but the co-sim
 * golden model (Spike) is von-Neumann -- one unified address space. With
 * .text@0 and .data@0 both at VMA 0, Spike's single space cannot hold
 * both (the second LOAD segment clobbers the first at vaddr 0). Putting
 * .data at 0x2000 keeps .text@0 and .data@0x2000 disjoint in BOTH the
 * RTL split spaces (I-mem 0, D-mem 0x2000) and Spike's unified space
 * (0x0:0x1000 for code, 0x2000:0xE000 for data+stack -- exactly the
 * cosim Makefile's SPIKE_MEM). medlow absolute addressing (lui+addi)
 * builds the 0x2000 data base the same way in both models.
 *
 * medlow (the gcc default; no -mcmodel is set) emits ABSOLUTE addressing
 * (lui+addi) for data symbols, which is what makes the split work on this
 * core: the hardware routes by operation, not address -- fetch reads
 * IMEM, the LSU reads DMEM. Do NOT switch to medany (auipc, PC-relative):
 * a PC-relative offset from .text to .data would land in IMEM, not DMEM.
 *
 * Freestanding image: no crt0, no libc, no runtime; start.S is the only
 * entry code. .bss is NOT zeroed at runtime (start.S does not clear it),
 * so put state that needs a known value in an initialized .data array
 * (part of the loaded image), not in uninitialized .bss globals. .bss
 * is placed LAST in DMEM so objcopy -j .rodata -j .data yields a
 * contiguous dmem.bin with no NOBITS gap. (The dmem.bin image starts at
 * the .data VMA 0x2000; the sim's $readmemh loads it at D-mem offset
 * 0x2000 -- sw/Makefile bin2hex keeps the @0 base and the .data words
 * follow, so preload lands the array at D-mem 0x2000.)
 */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    IMEM (rx)  : ORIGIN = 0x00000000, LENGTH = 16K
    DMEM (rwx) : ORIGIN = 0x00002000, LENGTH = 8K
}

SECTIONS
{
    .text : {
        KEEP(*(.text.init))   /* _start first -> IMEM 0x0 */
        *(.text*)
    } > IMEM

    /* Small-data sections are collected into these same output sections on
     * purpose. RISC-V gcc puts any constant or variable of at most
     * -msmall-data-limit bytes (8 by default) into .srodata / .sdata /
     * .sbss rather than .rodata / .data / .bss. Left uncollected they
     * become orphan sections: the linker still gives them addresses, but
     * the image is extracted with `objcopy -j .rodata -j .data`, so their
     * contents never reach the D-mem hex and every read of them returns
     * whatever the memory happens to hold -- zero in simulation. A 4-byte
     * const read as 0 while the same constant folded at compile time
     * reads correctly is exactly as confusing as it sounds. */
    .rodata : { *(.rodata*) *(.srodata*) } > DMEM
    .data   : { *(.data*) *(.sdata*) }     > DMEM
    .bss    : { *(.bss*) *(.sbss*) *(COMMON) } > DMEM

    /* Drop metadata that has no place in a flat image. */
    /DISCARD/ : {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
        *(.riscv.attributes)
    }
}