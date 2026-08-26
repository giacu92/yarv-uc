# Shared build logic for Harvard firmware images.
#
# Included by every harness Makefile under sim/sw/{quicksort,isa,intr,peri}.
# The harness sets a few variables (below) and then `include`s this file; this
# defines the toolchain, flags, and the build rules that turn C / assembly into
# a pair of $readmemh images (build/imem.hex -> I-mem, build/dmem.hex -> D-mem).
#
# COMMON_DIR is derived from this file's own path, so it is correct regardless
# of how deep the harness that includes it sits.
#
# Harness-set variables (all optional unless noted):
#   ARCH            : -march string (default rv32imac_zicsr_zifencei).
#                     Plain-integer programs (quicksort, yarvmon) override to
#                     rv32imac; anything that emits CSR / mret / wfi / fence.i
#                     keeps the default.
#   C_SRCS          : C source filenames in the harness dir (empty for pure asm).
#   S_SRCS          : standalone assembly filenames with their own _start
#                     (empty for C programs, which link the common start.S).
#   START_S         : start.S path (default $(COMMON_DIR)/start.S).
#   LINK_LD         : link script (default $(COMMON_DIR)/link.ld).
#   IMEM_PAD_WORDS  : 0 = no padding (default); 4096 = pad the I-mem image to the
#                     full declared depth with IMEM_PAD_VALUE (ebreak). Board-fw
#                     images pad so GowinSynthesis sizes the inferred ROM from
#                     $readmemh content at the right depth.
#   IMEM_PAD_VALUE  : filler word (default 0x00100073 = ebreak).
#   OPT             : optimisation level (default -O2). CoreMark raises it.
#   EXTRA_CFLAGS    : extra -D flags, e.g. -DPRINT_ARRAY=$(PRINT_ARRAY).
#   EXTRA_LDFLAGS   : extra link flags, e.g. -Wl,--gc-sections.
#
# Targets: make (all) -> imem.hex + dmem.hex + objdump; make show; make clean.

COMMON_DIR := $(patsubst %/,%,$(dir $(realpath $(lastword $(MAKEFILE_LIST)))))

# --- Toolchain -----------------------------------------------------------
# Default is the buildroot glibc toolchain (riscv32-buildroot-linux-gnu) -- a
# *linux* toolchain, hence the -fno-pie / -no-pie / -Wl,-N flags below are
# mandatory (its ld emits a PT_PHDR segment this flat MEMORY layout does not
# cover, and it defaults to PIE). Override RISCV_PREFIX to point at another
# rv32-capable toolchain (e.g. the PlatformIO/esphome bare-metal
# riscv32-esp-elf, riscv64-unknown-elf, riscv-none-elf) if preferred.
RISCV_PREFIX ?= $(HOME)/_toolchains/riscv32-ilp32d--glibc--stable-2025.08-1/bin/riscv32-buildroot-linux-gnu

CC      := $(RISCV_PREFIX)-gcc
OBJCOPY := $(RISCV_PREFIX)-objcopy
OBJDUMP := $(RISCV_PREFIX)-objdump

ARCH ?= rv32imac_zicsr_zifencei
ABI  := ilp32

# -fno-pie: a linux/glibc toolchain (riscv32-buildroot-linux-gnu) defaults to PIE,
# which makes gas expand `la sym` into a GOT load (auipc + lw from .got) and gcc
# emit PC-relative data addressing. Both break the Harvard two-image layout:
# the GOT does not exist there, and link.ld requires medlow ABSOLUTE (lui + addi)
# so a data address computed in .text lands in D-mem. Without this, mtvec ends up
# loaded from an uninitialised .got word and the box reboot-loops.
#
# -no-pie -Wl,-N: the same linux ld emits a PT_PHDR segment this flat MEMORY
# layout does not cover ("PHDR segment not covered by LOAD segment"); -no-pie
# plus -N (omagic, single writable non-demand-paged LOAD) drops it. Harmless on
# a bare-metal toolchain.
#
# -I$(COMMON_DIR): lets C sources write `#include "uart.h"` against the shared
# header regardless of where the harness lives.
START_S ?= $(COMMON_DIR)/start.S
LINK_LD ?= $(COMMON_DIR)/link.ld
BIN2HEX := $(COMMON_DIR)/bin2hex.py

OPT ?= -O2

CFLAGS := -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles -ffreestanding \
          -fno-builtin -fno-stack-protector -fomit-frame-pointer $(OPT) -Wall -g -fno-pie \
          -I$(COMMON_DIR) $(EXTRA_CFLAGS)
LDFLAGS := -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles -ffreestanding \
           -T $(LINK_LD) -Wl,--no-relax -Wl,--no-check-sections -no-pie -Wl,-N \
           $(EXTRA_LDFLAGS)

BUILD    := build
ELF      := $(BUILD)/program.elf
IMEM_BIN := $(BUILD)/imem.bin
DMEM_BIN := $(BUILD)/dmem.bin
IMEM_HEX := $(BUILD)/imem.hex
DMEM_HEX := $(BUILD)/dmem.hex
OBJD     := $(BUILD)/program.elf.objdump

IMEM_PAD_WORDS ?= 0
IMEM_PAD_VALUE ?= 0x00100073

# Object list: C programs link the common start.o first (so _start / .text.init
# is the first thing linked -> IMEM 0x0); standalone .S programs carry their own
# _start and link alone.
ifeq ($(strip $(C_SRCS)),)
OBJS := $(patsubst %.S,$(BUILD)/%.o,$(S_SRCS))
else
OBJS := $(BUILD)/start.o $(patsubst %.c,$(BUILD)/%.o,$(C_SRCS))
endif

# Rebuild on a flag change, not only on a source change. Several harnesses
# are built more than one way from the same directory (quicksort with and
# without PRINT_ARRAY, coremark with and without COSIM), and make sees only
# timestamps: after a co-sim build, a plain `make` finds every object newer
# than its source and reports success while leaving the co-sim variant in
# place. The stamp file records the varying part of the flags and is
# rewritten only when it changes, so the objects depend on the
# configuration as well as on the sources.
CFG_STAMP := $(BUILD)/.config
CFG_TEXT  := $(ARCH) $(OPT) $(EXTRA_CFLAGS) $(EXTRA_LDFLAGS) $(RISCV_PREFIX)
# The stamp is written with make's $(file ...) rather than through a shell
# echo: EXTRA_CFLAGS routinely carries quotes and spaces (-DCOMPILER_FLAGS='...'),
# and passing that through sh mangles it. The shell only ever sees `cmp`.
$(shell mkdir -p $(BUILD))
$(file >$(CFG_STAMP).new,$(CFG_TEXT))
$(shell cmp -s $(CFG_STAMP).new $(CFG_STAMP) || cp $(CFG_STAMP).new $(CFG_STAMP); rm -f $(CFG_STAMP).new)

.PHONY: all clean show
all: $(IMEM_HEX) $(DMEM_HEX) $(OBJD)

$(BUILD):
	mkdir -p $(BUILD)

$(OBJS): $(CFG_STAMP)

$(BUILD)/start.o: $(START_S) | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/%.o: %.c | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/%.o: %.S | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(ELF): $(OBJS) $(LINK_LD)
	$(CC) $(LDFLAGS) $(OBJS) -o $@

# Instruction image: .text.init + .text -> IMEM (VMA 0). Fetch's read-only port.
$(IMEM_BIN): $(ELF)
	$(OBJCOPY) -O binary -j .text.init -j .text $< $@

# Data image: .rodata + .data -> DMEM (VMA 0x2000). .bss is NOBITS (no file
# content) and placed last, so it does not punch a gap. objcopy -j starts the
# binary at the lowest kept-section VMA (0x2000, the DMEM ORIGIN), so bin2hex
# --base 0x2000 emits @0x800 and the words land at D-mem 0x2000.
$(DMEM_BIN): $(ELF)
	$(OBJCOPY) -O binary -j .rodata -j .data $< $@

ifeq ($(IMEM_PAD_WORDS),0)
$(IMEM_HEX): $(IMEM_BIN) $(BIN2HEX)
	python3 $(BIN2HEX) $< $@
else
# Padded so the inferred ROM is built that deep: GowinSynthesis sizes a
# read-only array from its $readmemh content, not from the declared depth, so an
# image-sized ROM lets every fetch above the image alias back into real
# instructions -- a wrong redirect then runs silently instead of faulting. The
# filler is ebreak, not zero: a run of zero words reads as "no init" and may be
# dropped again, and breakpoint (mcause=3) distinguishes a wander into the
# padding from illegal-instruction (mcause=2) on genuine garbage.
$(IMEM_HEX): $(IMEM_BIN) $(BIN2HEX)
	python3 $(BIN2HEX) --pad-words $(IMEM_PAD_WORDS) --pad-value $(IMEM_PAD_VALUE) $< $@
endif

$(DMEM_HEX): $(DMEM_BIN) $(BIN2HEX)
	python3 $(BIN2HEX) --base 0x2000 $< $@

$(OBJD): $(ELF)
	$(OBJDUMP) -d $< > $@

show: $(ELF)
	$(OBJDUMP) -d $<

clean:
	rm -rf $(BUILD)