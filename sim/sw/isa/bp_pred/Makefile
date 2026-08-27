# Branch-predictor correctness oracle (gshare PHT + RAS, prediction-at-decode).
#
# Exercises every predictor path (always-taken / always-NT / loop-exit
# mispredict / alternating / correlated / RVC branch / RAS call-return /
# mispredict-with-fetch-outstanding / trap-vs-prediction) and self-checks the
# architectural result. Guards the invariant a predictor must never alter: a
# prediction may mispredict freely but must never change architectural state --
# only performance. A flush/hold-buffer bug that lets a wrong-path instr retire
# corrupts a register and fails a CHECK. A mtvec handler resumes the one
# expected ecall (case 9) and fails any stray trap.
#
#   make          build build/imem.hex + build/dmem.hex + objdump
#   make show     disassemble build/program.elf
#   make clean    remove build/
#
# Run in the sim (from sim/):
#   make run RUN_ARGS="+IINIT=sw/isa/bp_pred/build/imem.hex +DINIT=sw/isa/bp_pred/build/dmem.hex"
# Pass = park @ `park` (not `bad`/`th_park`), probe word 0x800 = 0x600D.
#
# -march=rv32imac_zicsr_zifencei: c.addi / c.bnez + the CSR ops for mtvec /
# mepc / mcause. Pure assembly with its own _start.

S_SRCS := bp_pred_test.S

include ../../common/sw_build.mk