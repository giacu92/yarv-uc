# Quicksort benchmark -> Harvard imem.hex + dmem.hex.
#
# Recursive quicksort over a 256-word array filled by a deterministic LCG
# (same sequence on Spike and RTL; pseudo-random so the recursion stays near
# log2(N) deep instead of degenerating to N frames on sorted input), printed
# before and after the sort, returns 0x600D (pass) / 0xBAD (fail).
#
#   make          build build/imem.hex + build/dmem.hex
#   make show     disassemble build/program.elf
#   make clean    remove build/
#
# Load in the sim (from sim/):
#   make run RUN_ARGS="+IINIT=sw/quicksort/build/imem.hex +DINIT=sw/quicksort/build/dmem.hex"
#
# Plain integer code (-march=rv32imac, no zicsr in the arch string): no CSR /
# fence / atomics. Zilx indexed loads are hand-encoded with .insn in main.c.

ARCH := rv32imac

# PRINT_ARRAY=0 compiles out the array printing: the co-sim needs a build that
# makes no UART access before the sort (Spike has no UART slave).
# UART_TX_PACED=1 replaces the TX_READY poll with a software delay (board
# diagnostic: separates "the FIFO filled" from "the poll never returned").
PRINT_ARRAY   ?= 1
UART_TX_PACED ?= 0
EXTRA_CFLAGS := -DPRINT_ARRAY=$(PRINT_ARRAY) -DUART_TX_PACED=$(UART_TX_PACED)

C_SRCS := main.c

include ../common/sw_build.mk