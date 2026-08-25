# Timer-interrupt oracle (pure assembly): arms mtimecmp=200, wfi's, wakes on
# MTIP (mcause=0x8000_0007), handler stores marker=7 @0x2040, clears MTIP
# (mtimecmp=0xFFFFFFFF_FFFFFFFF). Not Spike-comparable (no CLINT slave in Spike)
# -- standalone oracle only.
#
#   make          build build/imem.hex + build/dmem.hex
#   make show     disassemble build/program.elf
#   make clean    remove build/
#
# Run in the sim (from sim/):
#   make run RUN_ARGS="+IINIT=sw/intr/timer/build/imem.hex +DINIT=sw/intr/timer/build/dmem.hex"
#
# -march=rv32imac_zicsr_zifencei so the toolchain emits CSR / mret / wfi /
# fence.i. Pure assembly with its own _start.

S_SRCS := timer_test.S

include ../../common/sw_build.mk