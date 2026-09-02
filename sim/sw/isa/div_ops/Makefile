# M-extension divide oracle: checks DIV / DIVU / REM / REMU against the
# RISC-V reference results, including every sign quadrant, signed overflow
# (INT_MIN / -1), division by zero with a NEGATIVE dividend, and unsigned
# divisors above 2^31. Writes 0x600D / 0xBAD @0x2000.
#
# Why it exists: nothing in the tree tested the divider directly -- mul_ops
# covers the multiply half of the M extension, and the benchmarks only emit
# ordinary positive divisions. It was written to pin a real bug found on
# 2026-09-02: REM rd, rs1, 0 with rs1 negative returned abs(rs1), because the
# divider stores abs(rs1) and the divide-by-zero path did not re-apply the
# sign. See the header comment in div_ops_test.S for the three divider
# properties the benchmarks cannot reach.
#
#   make          build build/imem.hex + build/dmem.hex + objdump
#   make show     disassemble build/program.elf
#   make clean    remove build/
#
# Run in the sim (from sim/):
#   make run RUN_ARGS="+IINIT=sw/isa/div_ops/build/imem.hex +DINIT=sw/isa/div_ops/build/dmem.hex"
# Pass = probe word 0x800 = 0x600D.
#
# Pure assembly with its own _start; no toolchain runtime.

S_SRCS := div_ops_test.S

include ../../common/sw_build.mk
