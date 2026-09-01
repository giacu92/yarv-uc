# M-extension multiply oracle: checks MUL / MULH / MULHSU / MULHU against
# hand-computed 64-bit references, including every signedness corner (INT_MIN,
# -1, 0x8000_0000 squared, mixed signs). Writes 0x600D / 0xBAD @0x2000.
#
# Why it exists: no cosim or oracle in the tree emitted MULH / MULHSU / MULHU
# at all -- gcc only reaches for them on 64-bit arithmetic, which none of the
# benchmarks do. So the whole signed/unsigned half of the M extension was
# unguarded, and it is exactly what alu.sv's MUL_SHARED_DSP restructure
# changes: one signed 33x33 product with the signedness moved onto the
# operands, instead of three 32x32 products selected on their results. A
# swapped sign-extension is invisible on ordinary MUL (the low word does not
# care) and wrong only in the high word.
#
#   make          build build/imem.hex + build/dmem.hex + objdump
#   make show     disassemble build/program.elf
#   make clean    remove build/
#
# Run in the sim (from sim/):
#   make run RUN_ARGS="+IINIT=sw/isa/mul_ops/build/imem.hex +DINIT=sw/isa/mul_ops/build/dmem.hex"
# Pass = probe word 0x800 = 0x600D. Run it both ways to prove the restructure
# is behaviour-neutral:
#   rm -rf obj_dir && make VPARAMS="-GMUL_SHARED_DSP=0" && ...
#
# Pure assembly with its own _start; no toolchain runtime.

S_SRCS := mul_ops_test.S

include ../../common/sw_build.mk
