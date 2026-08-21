/* Linker script for Harvard sim programs: split the image across two
 * independent address spaces.
 *
 *   IMEM (rx)  : ORIGIN = 0x0000, LENGTH = 64K   -> .text.init + .text (fetch)
 *   DMEM (rwx) : ORIGIN = 0x2000, LENGTH = 56K   -> .rodata + .data + .bss
 *                                                    + stack (LSU)
 *
 * The CPU boots at 0x0 (top_module / sim_top boot_addr_i = 0); _start
 * (in .text.init, placed first) lands at IMEM 0x0. .data lands at DMEM
 * 0x2000; the stack grows down from the top of the D-mem (sp = 0x10000,
 * the 64 KiB physical BSRAM boundary; the first push lands at 0xFFFC,
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
    IMEM (rx)  : ORIGIN = 0x00000000, LENGTH = 64K
    DMEM (rwx) : ORIGIN = 0x00002000, LENGTH = 56K
}

SECTIONS
{
    .text : {
        KEEP(*(.text.init))   /* _start first -> IMEM 0x0 */
        *(.text*)
    } > IMEM

    .rodata : { *(.rodata*) } > DMEM
    .data   : { *(.data*) }   > DMEM
    .bss    : { *(.bss*) *(COMMON) } > DMEM

    /* Drop metadata that has no place in a flat image. */
    /DISCARD/ : {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
        *(.riscv.attributes)
    }
}