# Build a C program into a $readmemh program.hex for the Verilator sim,
# using the prebuilt bare-metal RISC-V toolchain (riscv32-esp-elf-gcc,
# found under the PlatformIO/esphome cache -- no install needed).
#
#   make          build build/program.hex (and .elf / .bin / .objdump)
#   make show     disassemble build/program.elf
#   make clean    remove build/
#
# Output: build/program.hex
# Load it in the sim (from sim/):  make run RUN_ARGS="+INIT=sw/build/program.hex"

# --- Toolchain -----------------------------------------------------------
# The bare-metal RISC-V GCC that PlatformIO dropped under the esphome
# cache. Override RISCV_PREFIX to point at another rv32-capable toolchain
# (e.g. riscv64-unknown-elf, riscv-none-elf) if you have one on PATH.
ESP_TC      ?= $(HOME)/esphome/config/.esphome/platformio/packages/toolchain-riscv32-esp/bin
RISCV_PREFIX ?= $(ESP_TC)/riscv32-esp-elf

CC      := $(RISCV_PREFIX)-gcc
OBJCOPY := $(RISCV_PREFIX)-objcopy
OBJDUMP := $(RISCV_PREFIX)-objdump

# rv32imac = the core's implemented ISA subset (I + M + A + C). The core
# defers Zicsr / Zifencei / real-AMO to illegal for now, so plain integer
# C is what actually executes; the compiler will not emit CSR / fence /
# atomics for this code.
ARCH := rv32imac
ABI  := ilp32

CFLAGS := -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles -ffreestanding \
          -fno-builtin -fno-stack-protector -fomit-frame-pointer -O2 -Wall -g
LDFLAGS := -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles -ffreestanding \
           -T link.ld -Wl,--no-relax

BUILD := build
ELF   := $(BUILD)/program.elf
BIN   := $(BUILD)/program.bin
HEX   := $(BUILD)/program.hex
OBJD  := $(BUILD)/program.elf.objdump

# start.o first so _start (.text.init) is the first thing linked -> 0x0.
OBJS := $(BUILD)/start.o $(BUILD)/main.o

.PHONY: all clean show
all: $(HEX) $(OBJD)

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/start.o: start.S | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/main.o: main.c | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(ELF): $(OBJS) link.ld
	$(CC) $(LDFLAGS) $(OBJS) -o $@

$(BIN): $(ELF)
	$(OBJCOPY) -O binary $< $@

$(HEX): $(BIN) bin2hex.py
	python3 bin2hex.py $< $@

$(OBJD): $(ELF)
	$(OBJDUMP) -d $< > $@

show: $(ELF)
	$(OBJDUMP) -d $<

clean:
	rm -rf $(BUILD)