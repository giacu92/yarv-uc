# Instruction-access-fault oracle: jumps to 0x100000 (far outside the 16 KiB
# I-mem) and checks that exactly one trap arrived with mcause=1 and mtval equal
# to the address jumped to; writes 0x600D / 0xBAD at D-mem 0x2000. The handler
# does NOT mret to mepc (the faulting address is still unfetchable) -- it
# rewrites mepc to a known label, as a real handler must.
#
#   make          build build/imem.hex + build/dmem.hex
#   make show     disassemble build/program.elf
#   make clean    remove build/
#
# Run in the sim (from sim/):
#   make run RUN_ARGS="+IINIT=sw/isa/ifault/build/imem.hex +DINIT=sw/isa/ifault/build/dmem.hex"
#
# Pure assembly with its own _start; uses a minimal local link.ld (no .bss).

S_SRCS  := ifault_test.S
LINK_LD := link.ld

include ../../common/sw_build.mk