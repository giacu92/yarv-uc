# Build the timer-interrupt oracle (pure assembly) into a pair of
# $readmemh images for the Harvard Verilator sim.
#
#   make          build build/imem.hex + build/dmem.hex
#   make show      disassemble build/program.elf
#   make clean     remove build/
#
# Run in the sim (from sim/):
#   make run RUN_ARGS="+IINIT=sw_timer/build/imem.hex +DINIT=sw_timer/build/dmem.hex"
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

# -fno-pie: a linux/glibc toolchain (riscv32-buildroot-linux-gnu) defaults
# to PIE, which makes gas expand `la sym` into a GOT load (auipc + lw from
# .got) and gcc emit PC-relative data addressing. Both are wrong here: the
# GOT does not exist in a flat two-image layout, and link.ld requires
# medlow ABSOLUTE addressing (lui + addi) so a data address computed in
# .text lands in D-mem instead of I-mem. Without this, mtvec ends up loaded
# from an uninitialised .got word.
CFLAGS := -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles -ffreestanding \
          -fno-builtin -fno-stack-protector -fomit-frame-pointer -O2 -Wall -g -fno-pie
# -no-pie -Wl,-N: needed when RISCV_PREFIX points at a *linux* (glibc)
# toolchain such as riscv32-buildroot-linux-gnu instead of a bare-metal
# one. That ld defaults to emitting a PT_PHDR segment, which link.ld's
# flat MEMORY layout does not cover ("PHDR segment not covered by LOAD
# segment"); -no-pie plus -N (omagic) drops it. Harmless on a bare-metal
# toolchain.
LDFLAGS := -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles -ffreestanding \
           -T link.ld -Wl,--no-relax -Wl,--no-check-sections -no-pie -Wl,-N

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

$(ELF): timer_test.S link.ld | $(BUILD)
	$(CC) $(CFLAGS) -c timer_test.S -o $(BUILD)/timer_test.o
	$(CC) $(LDFLAGS) $(BUILD)/timer_test.o -o $@

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