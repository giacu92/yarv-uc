# Build the YarvMon monitor into a pair of $readmemh images for the Harvard
# Verilator sim + the board (this is the default product firmware:
# top_module.sv INIT_FILE points at build/imem.hex).
#
#   make          build build/imem.hex + build/dmem.hex (.elf/.bin/.objdump)
#   make show     disassemble build/program.elf
#   make clean    remove build/
#
# Output: build/imem.hex (code, -> I-mem) + build/dmem.hex (data, -> D-mem)
# Load them in the sim (from sim/):
#   make run RUN_ARGS="+IINIT=sw-yarvmon/build/imem.hex +DINIT=sw-yarvmon/build/dmem.hex"

# --- Toolchain -----------------------------------------------------------
# Default: buildroot glibc rv32 toolchain (gcc 14.3.0). Override
# RISCV_PREFIX to point at another rv32-capable toolchain (e.g.
# riscv64-unknown-elf, riscv-none-elf) if you have one on PATH.
RISCV_PREFIX ?= $(HOME)/_toolchains/riscv32-ilp32d--glibc--stable-2025.08-1/bin/riscv32-buildroot-linux-gnu

CC      := $(RISCV_PREFIX)-gcc
OBJCOPY := $(RISCV_PREFIX)-objcopy
OBJDUMP := $(RISCV_PREFIX)-objdump

# rv32imac = the core's implemented integer subset (I + M + A + C). The
# core also implements Zicsr + Zifencei + machine-mode traps, but plain C
# (-march=rv32imac, no zicsr in the arch string) emits only integer code
# (no CSR / fence / atomics); the trap oracle (sim/sw/intr/trap) builds with
# rv32imac_zicsr_zifencei when it needs those. Zilx indexed loads are
# implemented (retire via the LSU) but have no assembler mnemonics, so
# yarvmon.c hand-encodes them with .insn.
ARCH := rv32imac
ABI  := ilp32

# -fno-pie: a linux/glibc toolchain (riscv32-buildroot-linux-gnu) defaults
# to PIE, which makes gas expand `la sym` into a GOT load (auipc + lw from
# .got) and gcc emit PC-relative data addressing. Both are wrong here: the
# GOT does not exist in a flat two-image layout, and link.ld requires
# medlow ABSOLUTE addressing (lui + addi) so a data address computed in
# .text lands in D-mem instead of I-mem. Without this, mtvec ends up loaded
# from an uninitialised .got word.
CFLAGS := -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles -ffreestanding \
          -fno-builtin -fno-stack-protector -fomit-frame-pointer -O2 -Wall -g -fno-pie \
          -I../sw/common
# -no-pie -Wl,-N: needed when RISCV_PREFIX points at a *linux* (glibc)
# toolchain such as riscv32-buildroot-linux-gnu instead of a bare-metal
# one. That ld defaults to emitting a PT_PHDR segment, which link.ld's
# flat MEMORY layout does not cover ("PHDR segment not covered by LOAD
# segment"); -no-pie plus -N (omagic, single writable non-demand-paged
# LOAD) drops it. Harmless on a bare-metal toolchain.
LDFLAGS := -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles -ffreestanding \
           -T link.ld -Wl,--no-relax -Wl,--no-check-sections -no-pie -Wl,-N

BUILD := build
ELF     := $(BUILD)/program.elf
IMEM_BIN := $(BUILD)/imem.bin
DMEM_BIN := $(BUILD)/dmem.bin
IMEM_HEX := $(BUILD)/imem.hex
DMEM_HEX := $(BUILD)/dmem.hex
OBJD    := $(BUILD)/program.elf.objdump

# start.o first so _start (.text.init) is the first thing linked -> IMEM 0x0.
OBJS := $(BUILD)/start.o $(BUILD)/yarvmon.o

.PHONY: all clean show
all: $(IMEM_HEX) $(DMEM_HEX) $(OBJD)

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/start.o: start.S | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/yarvmon.o: yarvmon.c | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(ELF): $(OBJS) link.ld
	$(CC) $(LDFLAGS) $(OBJS) -o $@

# Instruction image: .text.init + .text -> IMEM (VMA 0). Fetch's read-only port.
$(IMEM_BIN): $(ELF)
	$(OBJCOPY) -O binary -j .text.init -j .text $< $@

# Data image: .rodata + .data -> DMEM (VMA 0x2000). .bss is NOBITS (no file
# content) and placed last, so it does not punch a gap in this binary.
# objcopy -j starts the binary at the lowest kept-section VMA (0x2000, the
# DMEM ORIGIN), so bin2hex --base 0x2000 emits @0x800 and the words land at
# D-mem 0x2000 (where the program addresses them), not word 0.
$(DMEM_BIN): $(ELF)
	$(OBJCOPY) -O binary -j .rodata -j .data $< $@

# Padded to IMEM_PAD_WORDS so the inferred ROM is built that deep:
# GowinSynthesis sizes a read-only array from its $readmemh content, not from
# the declared depth, so an image-sized ROM lets every fetch above the image
# alias back into real instructions -- a wrong redirect then runs silently
# instead of faulting. This is the board's default firmware, so it matters
# here as much as in the bring-up programs.
#
# The filler is ebreak, not zero: zero traps too, but a run of zero words is
# indistinguishable from "no initial value" and may be dropped again, and
# breakpoint (mcause=3) identifies a wander into the padding as opposed to
# illegal-instruction (mcause=2) from genuine garbage.
IMEM_PAD_WORDS ?= 4096   # 16 KiB, the full declared I-mem depth
IMEM_PAD_VALUE ?= 0x00100073

$(IMEM_HEX): $(IMEM_BIN) bin2hex.py
	python3 bin2hex.py --pad-words $(IMEM_PAD_WORDS) --pad-value $(IMEM_PAD_VALUE) $< $@

$(DMEM_HEX): $(DMEM_BIN) bin2hex.py
	python3 bin2hex.py --base 0x2000 $< $@

$(OBJD): $(ELF)
	$(OBJDUMP) -d $< > $@

show: $(ELF)
	$(OBJDUMP) -d $<

clean:
	rm -rf $(BUILD)