# Build a C program into a pair of $readmemh images for the Harvard
# Verilator sim, using the prebuilt bare-metal RISC-V toolchain
# (riscv32-esp-elf-gcc, found under the PlatformIO/esphome cache -- no
# install needed).
#
#   make          build build/imem.hex + build/dmem.hex (.elf/.bin/.objdump)
#   make show     disassemble build/program.elf
#   make clean    remove build/
#
# Output: build/imem.hex (code, -> I-mem) + build/dmem.hex (data, -> D-mem)
# Load them in the sim (from sim/):
#   make run RUN_ARGS="+IINIT=sw/build/imem.hex +DINIT=sw/build/dmem.hex"

# --- Toolchain -----------------------------------------------------------
# The bare-metal RISC-V GCC that PlatformIO dropped under the esphome
# cache. Override RISCV_PREFIX to point at another rv32-capable toolchain
# (e.g. riscv64-unknown-elf, riscv-none-elf) if you have one on PATH.
ESP_TC      ?= $(HOME)/esphome/config/.esphome/platformio/packages/toolchain-riscv32-esp/bin
RISCV_PREFIX ?= $(ESP_TC)/riscv32-esp-elf

CC      := $(RISCV_PREFIX)-gcc
OBJCOPY := $(RISCV_PREFIX)-objcopy
OBJDUMP := $(RISCV_PREFIX)-objdump

# rv32imac = the core's implemented integer subset (I + M + A + C). The
# core also implements Zicsr + Zifencei + machine-mode traps, but plain C
# (-march=rv32imac, no zicsr in the arch string) emits only integer code
# (no CSR / fence / atomics); the trap oracle (sim/sw_trap) builds with
# rv32imac_zicsr_zifencei when it needs those. Zilx indexed loads are
# implemented (retire via the LSU) but have no assembler mnemonics, so
# main.c hand-encodes them with .insn.
ARCH := rv32imac
ABI  := ilp32

CFLAGS := -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles -ffreestanding \
          -fno-builtin -fno-stack-protector -fomit-frame-pointer -O2 -Wall -g
LDFLAGS := -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles -ffreestanding \
           -T link.ld -Wl,--no-relax -Wl,--no-check-sections

BUILD := build
ELF     := $(BUILD)/program.elf
IMEM_BIN := $(BUILD)/imem.bin
DMEM_BIN := $(BUILD)/dmem.bin
IMEM_HEX := $(BUILD)/imem.hex
DMEM_HEX := $(BUILD)/dmem.hex
OBJD    := $(BUILD)/program.elf.objdump

# start.o first so _start (.text.init) is the first thing linked -> IMEM 0x0.
OBJS := $(BUILD)/start.o $(BUILD)/main.o

.PHONY: all clean show
all: $(IMEM_HEX) $(DMEM_HEX) $(OBJD)

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/start.o: start.S | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/main.o: main.c | $(BUILD)
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

$(IMEM_HEX): $(IMEM_BIN) bin2hex.py
	python3 bin2hex.py $< $@

$(DMEM_HEX): $(DMEM_BIN) bin2hex.py
	python3 bin2hex.py --base 0x2000 $< $@

$(OBJD): $(ELF)
	$(OBJDUMP) -d $< > $@

show: $(ELF)
	$(OBJDUMP) -d $<

clean:
	rm -rf $(BUILD)