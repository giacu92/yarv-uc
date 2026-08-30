# YarvMon -> Harvard imem.hex + dmem.hex.
#
# Wozmon-style serial monitor over the UART (115200 8N1): hex address to
# examine, `:` to deposit, `.` for a block dump, `R` to call. This is the
# board's default product firmware as well as a sim program, which is why it
# pads the I-mem image to the full declared depth (see IMEM_PAD_WORDS below).
#
#   make          build build/imem.hex + build/dmem.hex
#   make show     disassemble build/program.elf
#   make clean    remove build/
#
# Load in the sim (from sim/):
#   UART_RX='2000\r' make run \
#     RUN_ARGS="+IINIT=sw/yarvmon/build/imem.hex +DINIT=sw/yarvmon/build/dmem.hex"
#
# Plain integer code (-march=rv32imac, no zicsr in the arch string): no CSR /
# fence / atomics. Zilx indexed loads are hand-encoded with .insn in yarvmon.c.
ARCH := rv32imac

# Board firmware, so the I-mem image is padded to the full 2048-element (64-bit)
# depth: GowinSynthesis sizes an inferred ROM from its $readmemh content, not
# from the declared depth, and an image-sized ROM lets a fetch above the image
# alias back into real instructions instead of faulting.
IMEM_PAD_WORDS := 2048

C_SRCS := yarvmon.c

include ../common/sw_build.mk
