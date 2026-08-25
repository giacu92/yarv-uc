# Per-scramble-bit RVC decode oracle for c_expand(): feeds every RVC scrambled-
# immediate form (c.addi4spn / c.addi16sp / c.li / c.addi / c.lui / c.andi /
# c.srli / c.srai / c.lw / c.sw / c.lwsp / c.swsp / c.j / c.jal / c.beqz /
# c.bnez) with each immediate bit set in isolation, self-checks, writes
# 0x600D / 0xBAD @0x2000. A mtvec handler catches any mis-decoded jump/offset as
# FAIL (no hang). The guard for the scramble-bit class of bugs -- cosim/oracles
# do not toggle those bits.
#
#   make          build build/imem.hex + build/dmem.hex + objdump
#   make show     disassemble build/program.elf
#   make clean    remove build/
#
# Run in the sim (from sim/):
#   make run RUN_ARGS="+IINIT=sw/isa/rvc_scramble/build/imem.hex +DINIT=sw/isa/rvc_scramble/build/dmem.hex"
# Pass = wb x6 = 0x0000600d / probe word 0x800 = 0x600D.
#
# -march=rv32imac_zicsr_zifencei: the assembler emits the compressed encodings
# under test plus the CSR ops for mtvec. The core's c_expand() is the thing
# being verified. Pure assembly with its own _start.

S_SRCS := rvc_scramble_test.S

include ../../common/sw_build.mk