# Dhrystone 2.1 -> Harvard imem.hex + dmem.hex.
#
#   make                       build build/imem.hex + build/dmem.hex
#   make DHRY_ITERS=500000     a run long enough for Dhrystone's own 2 s
#                              minimum on the board (default 2000, upstream's
#                              own, which is what a simulation can afford)
#   make IMEM_PAD_WORDS=2048   pad the I-mem image for a board build
#                              (16 KiB / 8 = 2048 64-bit words)
#   make clean
#
# Run in the sim (from sim/), no waveform, generous cycle bound:
#   NO_VCD=1 MAX_CYC=20000000 make run \
#     RUN_ARGS="+IINIT=sw/dhrystone/build/imem.hex +DINIT=sw/dhrystone/build/dmem.hex"
#
# sifive/ holds the unmodified SiFive benchmark-dhrystone tree (see
# sifive/UPSTREAM.md); dhry_portme.c, stdio.h and dhry_link.ld here, plus
# ../common/ee_printf.c, are this core's port.
#
# ARCH keeps zicsr: the port reads mcycle for the timing.
#
# NOT CO-SIMULATED, unlike quicksort and CoreMark. Arr_2_Glob is 10 000
# bytes of .bss, so the data image needs the whole 16 KiB D-mem and
# dhry_link.ld puts DMEM ORIGIN at 0 -- which is also where .text has to
# live, because the core boots at 0. Spike is von-Neumann and cannot hold
# both. See dhry_link.ld.

ARCH := rv32imac_zicsr_zifencei

# The dialect pin is not a stylistic choice. Dhrystone 2.1 is 1988 C: K&R
# parameter lists (`Proc_1 (Ptr_Val_Par) REG Rec_Pointer Ptr_Val_Par; {`)
# and an implicit-int `main ()`. gcc 15 defaults to C23, where K&R
# definitions are gone entirely, so the standard has to be named rather
# than left to the compiler. gnu17 and not gnu89: the shared common/uart.h
# this port includes is C99 (declarations in `for` initialisers), and gnu17
# still accepts K&R definitions -- it only warns.
#
# gcc 14 turned -Wimplicit-int and -Wimplicit-function-declaration into
# errors by default. Both are downgraded here, in both spellings, because
# which one bites depends on the compiler version: -Wno-implicit turns the
# warnings off, -Wno-error=... covers a version that treats them as
# permerrors regardless.
#
# -DTIME selects the time(2) branch of dhry.h's clock selection (the
# alternative, times(2), wants <sys/times.h>). -DNOENUM makes Enumeration a
# plain int. Both come from upstream's own Makefile, as do -fno-common and
# -falign-functions=4.
#
# -mstrict-align is not optional here or in the CoreMark port: this core
# traps on a misaligned load or store, it does not fix one up.
#
# -Dfloat=long removes the only floating point in the program. dhry_1.c has
# exactly seven uses of `float`, all of them in the report block after the
# timer stops (lines 71 and 279-286): two variables, Microseconds and
# Dhrystones_Per_Second, and the casts in the two expressions that compute
# them. Nothing in the measurement loop is touched, so the score is not
# affected -- and upstream already prints both values through an `(int)`
# cast (SiFive commented out the `%6.1f` forms), so the fractional part was
# being discarded before this.
#
# It is needed because the alternative is not available: this core has no
# FPU, the ABI is ilp32 (soft float), and the buildroot toolchain's libgcc
# is built ilp32d as its only multilib -- it contains no __floatsisf /
# __divsf3 / __fixsfsi to link against, and linking a hard-float libgcc
# into an ilp32 image would be an ABI mismatch even if it did. Integer
# arithmetic also makes the two printed numbers exact rather than
# float-rounded.
OPT := -O3
PERF_CFLAGS := -std=gnu17 -mstrict-align -fno-common -falign-functions=4 \
               -fno-builtin-printf \
               -Wno-implicit -Wno-error=implicit-int \
               -Wno-error=implicit-function-declaration \
               -Wno-old-style-definition -Wno-return-type

# Number of runs through the benchmark. 2000 is upstream's own default and
# is what a simulation run can afford (~1.5 M cycles).
#
# Dhrystone's run rule is its own Too_Small_Time: under 2 seconds and
# dhry_1.c prints "Measured time too small to obtain meaningful results"
# instead of a rate. At 50 MHz and the 686 cycles per iteration measured
# here that means DHRY_ITERS >= 145772, and the 32-bit mcycle (there is no
# mcycleh) caps the other end at about 6.26 M iterations = 86 s. So a
# board run that reports on its own terms wants something like
# DHRY_ITERS=500000 (~7 s). A short run still prints the port summary
# below it, which is computed from cycles and needs no minimum.
DHRY_ITERS ?= 2000
# The core clock: the rPLL makes 25 MHz x 10/5 = 50.000 MHz exactly. Only
# the "Dhrystones / sec", "DMIPS" and "Total time" lines depend on it;
# DMIPS/MHz comes from cycles alone and does not.
CLK_HZ ?= 50000000

# Cycles per iteration, measured on this core. Used only by the banner to
# say how long the run will take before it starts; nothing measured
# depends on it.
CYCLES_PER_ITER ?= 686

# -I. puts this directory ahead of the system include path, which is how
# stdio.h here shadows the toolchain's for dhry.h's `#include <stdio.h>`.
EXTRA_CFLAGS := -I. -Isifive $(PERF_CFLAGS) \
                -Dfloat=long \
                -DTIME -DNOENUM \
                -DDHRY_ITERS=$(DHRY_ITERS) \
                -DCYCLES_PER_ITER=$(CYCLES_PER_ITER) \
                -DCLK_HZ=$(CLK_HZ)

# No soft-float helpers exist for this build, so the report must not ask
# for any -- see -Dfloat=long in EXTRA_CFLAGS above.
EXTRA_LDLIBS :=

# This harness links its own script: the workload needs the whole 16 KiB
# D-mem, not the 8 KiB above 0x2000 that common/link.ld leaves. DMEM_BASE
# must track its DMEM ORIGIN or the data image loads at the wrong offset.
LINK_LD   := dhry_link.ld
DMEM_BASE := 0x0

# Board builds pad the I-mem image to the full declared depth, because
# GowinSynthesis sizes an inferred ROM from its $readmemh content rather
# than from the declared depth. Simulation does not need it.
IMEM_PAD_WORDS ?= 0

# `all` (from common/sw_build.mk) stays the default goal: the guard rule
# below is defined first, and make would otherwise take it as the default.
.DEFAULT_GOAL := all

# Provenance guard, same reason as the CoreMark port's: strcpy and strcmp
# run inside Dhrystone's measurement loop and the loop body is the
# benchmark, so a score from an edited tree is not comparable with anyone
# else's. An accidental edit fails the build instead of quietly producing a
# number. Runs before anything is compiled.
.PHONY: verify-sifive
verify-sifive:
	@cd sifive && md5sum -c --quiet VENDORED.md5 \
	  || { echo "sifive/ differs from upstream benchmark-dhrystone -- see sifive/UPSTREAM.md"; exit 1; }

# sifive/ holds the vendored workload; ../common holds ee_printf.c, shared
# with the CoreMark port.
vpath %.c sifive ../common
vpath %.S sifive

C_SRCS := dhry_portme.c ee_printf.c dhry_1.c dhry_2.c
S_SRCS := strcmp.S

include ../common/sw_build.mk

$(OBJS): | verify-sifive

# Rename the benchmark's entry point so dhry_portme.c can supply the real
# main() and print a port summary after Dhrystone's own report -- start.S
# calls main once and then spins, and Dhrystone has no finalisation hook of
# its own. The vendored file is not edited; only its translation unit sees
# the define.
#
# It is scoped to this one object on purpose, NOT put in EXTRA_CFLAGS. gcc
# runs .S files through the C preprocessor too, so a global -Dmain=... also
# rewrites common/start.S's `call main` into `call dhry_main` -- the port's
# main() is then never reached, and the only symptom is a missing banner
# and a missing summary around an otherwise perfect Dhrystone report.
$(BUILD)/dhry_1.o: CFLAGS += -Dmain=dhry_main
