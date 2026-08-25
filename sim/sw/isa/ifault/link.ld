OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY { IMEM (rx) : ORIGIN = 0x00000000, LENGTH = 16K
         DMEM (rwx): ORIGIN = 0x00002000, LENGTH = 8K }
SECTIONS {
  .text : { KEEP(*(.text.init)) *(.text*) } > IMEM
  .rodata : { *(.rodata*) *(.srodata*) } > DMEM
  .data   : { *(.data*) *(.sdata*) } > DMEM
  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) *(.riscv.attributes) }
}
