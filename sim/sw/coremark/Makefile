# CoreMark -> Harvard imem.hex + dmem.hex.
#
#   make                    build build/imem.hex + build/dmem.hex
#   make ITERATIONS=10      more iterations (default 1, which is all a
#                           simulation run can afford)
#   make TOTAL_DATA_SIZE=6000   the 6K profile instead of the 2K one
#   make IMEM_PAD_WORDS=2048    pad the I-mem image for a board build (16 KiB
#                              / 8 = 2048 64-bit words)
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
# region must stay under 2^32 cycles (~86 s at 50 MHz).
#
# One iteration costs 604704 cycles in a multi-iteration run (2K profile,
# -O3; a single-iteration run reads 622006, the difference being one-time
# work inside the timed region that 2000 iterations amortise away). At
# 50 MHz a run is valid between roughly these bounds:
#
#   2K: ITERATIONS 828 .. 7102   (10 s .. the 32-bit mcycle wrap)
#
# The 6K profile costs ~7x that per iteration; scale accordingly.
#
# ITERATIONS=1000 (2K) is a good default for the board: ~16 s of run.

ARCH := rv32imac_zicsr_zifencei

# Toolchain: the tree default from common/sw_build.mk (the rv32 buildroot
# cross-compiler, gcc 14.3.0). Override RISCV_PREFIX like any other
# harness; nothing here needs a different compiler.

# Optimisation. CoreMark is a compiler benchmark as much as a core
# benchmark, and published scores are quoted with their flags; these match
# what the comparable published rv32 ports use, so the numbers are read
# against a like build. -mstrict-align matters here beyond speed: this core
# traps on a misaligned load or store, it does not fix them up.
OPT := -O3
EXTRA_LDFLAGS := -Wl,--gc-sections
PERF_CFLAGS := -ffunction-sections -fdata-sections -mstrict-align \
               -mbranch-cost=10 -ffp-contract=off -mno-fdiv

ITERATIONS ?= 1
# TOTAL_DATA_SIZE selects the profile: 2000 is CoreMark's 2K run (the
# default, and the one whose CRCs the source checks against). 6000 is the
# 6K run -- it needs 6 KiB of .bss where the 2K run needs 2 KiB, and the
# D-mem has 8 KiB for .rodata + .data + .bss AND the stack, so check the
# link before assuming it fits.
TOTAL_DATA_SIZE ?= 2000
RUN_TYPE   ?= PERFORMANCE_RUN
# The core clock: the rPLL makes 25 MHz x 10/5 = 50.000 MHz exactly. (The
# design re-closed PnR at 50 MHz on the fetch-rewrite path, 2026-08-27; the
# earlier 40.281 MHz was the pre-rewrite Fmax.) This is what the reported
# seconds and iterations-per-second are computed against; CoreMark/MHz
# comes from ticks alone and does not depend on it.
CLK_HZ     ?= 50000000
# COSIM=1 builds the variant the Spike co-sim runs: it reads no cycle
# counter (see core_portme.c), because a counter value is the one register
# write that can never match an instruction-based golden model.
COSIM ?= 0

# Cycles per iteration, measured on this core. Used only by the banner to
# say how long the run will take before it starts; nothing measured
# depends on it.
CYCLES_PER_ITER ?= 604704

EXTRA_CFLAGS := -I. -Ieembc $(PERF_CFLAGS) \
                -DITERATIONS=$(ITERATIONS) -D$(RUN_TYPE)=1 \
                -DCYCLES_PER_ITER=$(CYCLES_PER_ITER) \
                -DTOTAL_DATA_SIZE=$(TOTAL_DATA_SIZE) \
                -DCLK_HZ=$(CLK_HZ) -DHAS_PRINTF=1 \
                -DCOSIM=$(COSIM) \
                -DCOMPILER_FLAGS='"$(OPT) -march=$(ARCH) -mabi=ilp32 $(PERF_CFLAGS)"'

# Board builds pad the I-mem image to the full declared depth, because
# GowinSynthesis sizes an inferred ROM from its $readmemh content rather
# than from the declared depth -- an image-sized ROM lets a fetch above the
# image alias back into real instructions instead of trapping. Simulation
# does not need it (native_ram is declared 2048 64-bit words either way), so
# the default is off.
IMEM_PAD_WORDS ?= 0

# `all` (from common/sw_build.mk) stays the default goal: the guard rule
# below is defined first, and make would otherwise take it as the default.
.DEFAULT_GOAL := all

# Provenance guard. eembc/ is upstream EEMBC CoreMark vendored verbatim
# (see eembc/UPSTREAM.md); a score from an edited workload is not comparable
# with anyone else's, so an accidental edit has to fail the build rather than
# quietly produce a number. Runs before anything is compiled.
.PHONY: verify-eembc
verify-eembc:
	@cd eembc && md5sum -c --quiet VENDORED.md5 \
	  || { echo "eembc/ differs from upstream CoreMark -- see eembc/UPSTREAM.md"; exit 1; }

vpath %.c eembc

C_SRCS := core_portme.c ee_printf.c \
          core_main.c core_list_join.c core_matrix.c core_state.c core_util.c

include ../common/sw_build.mk

$(OBJS): | verify-eembc
