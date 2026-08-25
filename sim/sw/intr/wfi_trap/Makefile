# WFI-wake arbitration regression (pure assembly): wfi_halt_q must clear on
# int_pending, not take_interrupt (which loses priority to a sync trap) --
# otherwise a faulting instr behind wfi leaves the halt flag set, trap entry
# clears mstatus.MIE, dropping int_pending and freezing the pipe unrecoverably.
# Arms mtimecmp=400, runs a 32-cycle div to fill the pipe, then wfi + an illegal
# instr. On wake the illegal trap wins arbitration first (marker @0x2040), then
# the pending timer interrupt is taken (marker @0x2044).
#
#   make          build build/imem.hex + build/dmem.hex
#   make show     disassemble build/program.elf
#   make clean    remove build/
#
# Run in the sim (from sim/):
#   make run RUN_ARGS="+IINIT=sw/intr/wfi_trap/build/imem.hex +DINIT=sw/intr/wfi_trap/build/dmem.hex"
#
# Toolchain-free alternative (no assembler needed):
#   python3 gen_hex.py   # writes build/imem.hex + build/dmem.hex directly
#
# -march=rv32imac_zicsr_zifencei. Pure assembly with its own _start.

S_SRCS := wfi_trap_test.S

include ../../common/sw_build.mk