# Same-cycle RVC target-span stitch oracle (target_span_complete path).
#
# Branches (c.j) to a 32-bit (or compressed) instruction at offset 2 / 6 of an
# 8-byte-aligned fetch word and self-checks the result; a mtvec handler catches
# a mis-decoded jump/illegal as FAIL. Guards the bubble-removal path no existing
# oracle exercises (a 32-bit instr at a 2-byte-aligned branch target).
#
#   make          build build/imem.hex + build/dmem.hex + objdump
#   make show     disassemble build/program.elf
#   make clean    remove build/
#
# Run in the sim (from sim/):
#   make run RUN_ARGS="+IINIT=sw/isa/span_target/build/imem.hex +DINIT=sw/isa/span_target/build/dmem.hex"
# Pass = park @ `park` (not `bad`/`th_park`), probe word 0x800 = 0x600D.
#
# -march=rv32imac_zicsr_zifencei: c.addi + the CSR ops for mtvec. Pure assembly
# with its own _start.

S_SRCS := span_target_test.S

include ../../common/sw_build.mk