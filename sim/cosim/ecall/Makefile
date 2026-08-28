# ecall co-sim: build a minimal ecall+mret program, run it on Spike
# (golden) and on the Verilator RTL, diff per-retire (pc, rd, val).
# Mirrors cosim/quicksort/Makefile but builds its own ecall_test.S (not quicksort).
#
#   make cosim     build + run both + diff
#   make clean     remove logs + build

SCRIPT_DIR := $(dir $(realpath $(lastword $(MAKEFILE_LIST))))
COSIM_DIR  := $(SCRIPT_DIR)../
SPIKE      := $(COSIM_DIR)riscv-isa-sim-install/bin/spike

RISCV_PREFIX ?= $(HOME)/_toolchains/riscv32-zilx/out/bin/riscv32-unknown-elf
CC      := $(RISCV_PREFIX)-gcc
OBJCOPY := $(RISCV_PREFIX)-objcopy
OBJDUMP := $(RISCV_PREFIX)-objdump

ARCH := rv32imac_zicsr_zifencei
ABI  := ilp32
# -fno-pie / -no-pie / -Wl,-N: needed when RISCV_PREFIX points at a linux
# (glibc) toolchain such as riscv32-buildroot-linux-gnu rather than a
# bare-metal one. That ld emits a PT_PHDR segment which this flat MEMORY
# layout does not cover ("PHDR segment not covered by LOAD segment"), and
# the compiler defaults to PIE, which turns `la sym` into a GOT load and
# data addressing into PC-relative -- both wrong for a Harvard split that
# needs medlow absolute addressing. Harmless on a bare-metal toolchain.
# The other firmware Makefiles already carry these; this one was missed,
# so the co-sim could not build here at all.
CFLAGS := -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles -ffreestanding \
          -fno-builtin -fomit-frame-pointer -O2 -g -fno-pie
LDFLAGS := -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles -ffreestanding \
           -T link.ld -Wl,--no-relax -Wl,--no-check-sections -no-pie -Wl,-N

BUILD    := build
ELF      := $(BUILD)/program.elf
IMEM_HEX := $(BUILD)/imem.hex
DMEM_HEX := $(BUILD)/dmem.hex

SPIKE_LOG := $(SCRIPT_DIR)spike.log
RTL_LOG   := $(SCRIPT_DIR)rtl.trace
# The sim's stdout, which the run below would otherwise discard. The diff
# does not need it (that reads RTL_LOG), but it carries the stall-cause
# histogram and the CPI decomposition, and throwing those away means the
# one long run this harness already paid for says nothing about
# performance. Read the figures as belonging to the CO-SIM build of the
# firmware, which is not the timed build -- see the notes at the top.
RTL_STDOUT   := $(SCRIPT_DIR)rtl.stdout

SPIKE_MAXINSTR ?= 50000
SPIKE_ISA := rv32imac_zicsr_zifencei
SPIKE_MEM := 0x0:0x1000,0x2000:0xE000

.PHONY: cosim clean

cosim: diff

$(BUILD):
	mkdir -p $(BUILD)

$(ELF): ecall_test.S link.ld | $(BUILD)
	$(CC) $(CFLAGS) -c ecall_test.S -o $(BUILD)/ecall_test.o
	$(CC) $(LDFLAGS) $(BUILD)/ecall_test.o -o $@
	$(OBJCOPY) -O binary -j .text.init -j .text $@ $(BUILD)/imem.bin
	$(OBJCOPY) -O binary -j .rodata -j .data $@ $(BUILD)/dmem.bin
	python3 bin2hex.py --word-width 8 $(BUILD)/imem.bin $(IMEM_HEX)
	python3 bin2hex.py --base 0x2000 $(BUILD)/dmem.bin $(DMEM_HEX)
	$(OBJDUMP) -d $@ > $(BUILD)/program.elf.objdump

spike-run: $(ELF)
	@echo "== running Spike (golden) =="
	@rm -f $(SPIKE_LOG)
	@$(SPIKE) --isa=$(SPIKE_ISA) -m$(SPIKE_MEM) \
	    --instructions=$(SPIKE_MAXINSTR) --log-commits $(ELF) 2> $(SPIKE_LOG) \
	  || true
	@echo "spike: $$(wc -l < $(SPIKE_LOG)) commit lines -> $(SPIKE_LOG)"

rtl-run: $(IMEM_HEX) $(DMEM_HEX)
	@echo "== running RTL sim (RTL_TRACE=$(RTL_LOG)) =="
	@rm -f $(RTL_LOG)
	@RTL_TRACE=$(RTL_LOG) MAX_CYC=20000 \
	  $(MAKE) --no-print-directory -C $(SCRIPT_DIR)../.. run \
	    RUN_ARGS="+IINIT=cosim/ecall/build/imem.hex +DINIT=cosim/ecall/build/dmem.hex" \
	  > $(RTL_STDOUT)
	@test -s $(RTL_LOG) || { echo "rtl: no trace produced"; exit 1; }
	@echo "rtl: $$(wc -l < $(RTL_LOG)) retires -> $(RTL_LOG)"
	@echo "rtl: stdout -> $(RTL_STDOUT)"
	@sed -n "/^retired /,\$$p" $(RTL_STDOUT)

diff: spike-run rtl-run
	@python3 cosim_diff.py --rtl $(RTL_LOG) --spike $(SPIKE_LOG)

clean:
	rm -rf $(BUILD) $(SPIKE_LOG) $(RTL_LOG) $(RTL_STDOUT)