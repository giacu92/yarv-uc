# CoreMark -> Harvard imem.hex + dmem.hex.
#
#   make                    build build/imem.hex + build/dmem.hex
#   make ITERATIONS=10      more iterations (default 1, which is all a
#                           simulation run can afford)
#   make clean
#
# Run in the sim (from sim/), no waveform, generous cycle bound:
#   NO_VCD=1 MAX_CYC=40000000 make run \
#     RUN_ARGS="+IINIT=sw/coremark/build/imem.hex +DINIT=sw/coremark/build/dmem.hex"
#
# eembc/ holds the unmodified EEMBC CoreMark sources (Apache-2.0, see
# eembc/LICENSE.md); core_portme.[ch] and ee_printf.c are this core's port.
#
# ARCH keeps zicsr: the port reads mcycle for the timing.
#
# Score validity: an official CoreMark score needs a run of at least 10 s,
# i.e. ITERATIONS large enough at the board clock. That is a hardware run,
# not a simulation one -- one iteration is already a few million cycles.
# Note also that mcycle here is 32 bits with no mcycleh, so the timed
# region must stay under 2^32 cycles (107 s at 40 MHz).

ARCH := rv32imac_zicsr_zifencei

ITERATIONS ?= 1
RUN_TYPE   ?= PERFORMANCE_RUN
CLK_HZ     ?= 40000000
# SKIP_TIME_CHECK=1 (default) drops CoreMark's "must run for at least 10
# secs" gate, which no simulation run can pass -- with it left in, a run
# whose CRCs all matched still ends in "Errors detected". Set it to 0 for a
# board run long enough to be a reportable score.
SKIP_TIME_CHECK ?= 1
# COSIM=1 builds the variant the Spike co-sim runs: it reads no cycle
# counter (see core_portme.c), because a counter value is the one register
# write that can never match an instruction-based golden model.
COSIM ?= 0

EXTRA_CFLAGS := -I. -Ieembc -DITERATIONS=$(ITERATIONS) -D$(RUN_TYPE)=1 \
                -DCLK_HZ=$(CLK_HZ) -DHAS_PRINTF=1 \
                -DSKIP_TIME_CHECK=$(SKIP_TIME_CHECK) -DCOSIM=$(COSIM) \
                -DCOMPILER_FLAGS='"-O2 -march=$(ARCH) -mabi=ilp32"'

vpath %.c eembc

C_SRCS := core_portme.c ee_printf.c \
          coremark_main.c core_list_join.c core_matrix.c core_state.c core_util.c

include ../common/sw_build.mk
