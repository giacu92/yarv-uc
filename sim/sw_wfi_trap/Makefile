# Build the WFI-wake arbitration oracle (pure assembly) into a pair of
# $readmemh images for the Harvard Verilator sim.
#
#   make          build build/imem.hex + build/dmem.hex
#   make show      disassemble build/program.elf
#   make clean     remove build/
#
# Run in the sim (from sim/):
#   make run RUN_ARGS="+IINIT=sw_wfi_trap/build/imem.hex +DINIT=sw_wfi_trap/build/dmem.hex"
#
# -march=rv32imac_zicsr_zifencei so the toolchain emits CSR / mret / wfi /
# fence.i. The core implements all of these (Zicsr + Zifencei).

ESP_TC      ?= $(HOME)/esphome/config/.esphome/platformio/packages/toolchain-riscv32-esp/bin
RISCV_PREFIX ?= $(ESP_TC)/riscv32-esp-elf

CC      := $(RISCV_PREFIX)-gcc
OBJCOPY := $(RISCV_PREFIX)-objcopy
OBJDUMP := $(RISCV_PREFIX)-objdump

ARCH := rv32imac_zicsr_zifencei
ABI  := ilp32

CFLAGS := -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles -ffreestanding \
          -fno-builtin -fno-stack-protector -fomit-frame-pointer -O2 -Wall -g
LDFLAGS := -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles -ffreestanding \
           -T link.ld -Wl,--no-relax -Wl,--no-check-sections

BUILD    := build
ELF      := $(BUILD)/program.elf
IMEM_BIN := $(BUILD)/imem.bin
DMEM_BIN := $(BUILD)/dmem.bin
IMEM_HEX := $(BUILD)/imem.hex
DMEM_HEX := $(BUILD)/dmem.hex
OBJD     := $(BUILD)/program.elf.objdump

.PHONY: all clean show
all: $(IMEM_HEX) $(DMEM_HEX) $(OBJD)

$(BUILD):
	mkdir -p $(BUILD)

$(ELF): wfi_trap_test.S link.ld | $(BUILD)
	$(CC) $(CFLAGS) -c wfi_trap_test.S -o $(BUILD)/wfi_trap_test.o
	$(CC) $(LDFLAGS) $(BUILD)/wfi_trap_test.o -o $@

$(IMEM_BIN): $(ELF)
	$(OBJCOPY) -O binary -j .text.init -j .text $< $@
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