# Trap/exception/interrupt oracle (pure assembly): exercises ecall /
# load-misaligned / illegal / MSIP self-write + WFI wake; self-checks, writes
# 0x600D / 0xBAD at D-mem 0x2000.
#
#   make          build build/imem.hex + build/dmem.hex
#   make show     disassemble build/program.elf
#   make clean    remove build/
#
# Run in the sim (from sim/):
#   make run RUN_ARGS="+IINIT=sw/intr/trap/build/imem.hex +DINIT=sw/intr/trap/build/dmem.hex"
#
# -march=rv32imac_zicsr_zifencei so the toolchain emits CSR / mret / wfi /
# fence.i. Pure assembly with its own _start.

S_SRCS := trap_test.S

include ../../common/sw_build.mk