# ISA / memory probe: reports through fixed strings and a bit-dump built only
# from register-register AND and mask doubling -- never through the hex printer
# or any instruction under test (the printer was the thing that lied). Covers
# c.andi vs 32-bit andi, the shifts, reg-reg AND/OR, byte loads at each lane,
# and a memory matrix (lw / lbu const / lbu computed / lhu / byte stores) on one
# .rodata word and one .data word. Doubles as a board bring-up probe.
#
#   make          build build/imem.hex + build/dmem.hex
#   make show     disassemble build/program.elf
#   make clean    remove build/
#
# Run in the sim (from sim/):
#   make run RUN_ARGS="+IINIT=sw/isa/isa_probe/build/imem.hex +DINIT=sw/isa/isa_probe/build/dmem.hex"
# Board-accurate / TX-FIFO-safe: make UART_TX_PACED=1 (no TX_READY poll).

ARCH := rv32imac_zicsr_zifencei

UART_TX_PACED ?= 0
EXTRA_CFLAGS := -DUART_TX_PACED=$(UART_TX_PACED)

C_SRCS := isa_probe.c

# Board-fw-style: pad the I-mem image to the full declared depth with ebreak.
IMEM_PAD_WORDS := 4096

include ../../common/sw_build.mk