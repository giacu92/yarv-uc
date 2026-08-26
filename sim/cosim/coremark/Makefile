# CoreMark co-sim: run the same ELF on Spike (golden ISA reference) and on
# the Verilator RTL, then diff per-retire architectural effects (pc +
# register write). Mirrors cosim/quicksort/Makefile.
#
#   make cosim        full pipeline: build sw + Spike, run both, diff
#   make spike-build  build the local Spike (once; see ../build_spike.sh)
#   make spike-run    run Spike -> spike.log
#   make rtl-run      run the Verilator sim -> rtl.trace
#   make diff         diff spike.log vs rtl.trace
#   make clean        remove logs (keeps the Spike build)
#
# This is the longest co-sim in the tree: one CoreMark iteration is ~657 k
# retires against quicksort's ~30 k, and it exercises the whole datapath
# (linked lists, a matrix kernel with mul, a state machine over strings)
# rather than one sort loop. Expect a couple of minutes and ~100 MB of logs.
#
# Two things make the run co-simulable:
#
#  - COSIM=1 in the firmware build, so the port reads no cycle counter. A
#    counter value is the one register write an instruction-based golden
#    model can never reproduce (see sw/coremark/core_portme.c). It also
#    suppresses the banner, whose first UART write would end the diff
#    before any benchmark work had been done.
#  - OPT=-O2 rather than the -O3 the board image is built with. Spike is
#    one unified address space, so .text has to end below the .data VMA
#    (0x2000) -- on the RTL the two live in different memories and may
#    overlap freely, which is why an -O3 .text of 10648 bytes runs on the
#    board and silently executes .rodata under Spike. The diff checks the
#    core against the ISA, not the optimisation flags, so the -O2 image
#    covers what it is meant to cover. Lifting this needs a co-sim link
#    layout with the data above the code, not a bigger cap.
#  - The relocated Spike boot ROM. Upstream puts a 4 KiB ROM at
#    DEFAULT_RSTVEC = 0x1000, leaving a hole no -m region may cover, which
#    capped a co-simulated .text at 4 KiB -- fine for quicksort, too small
#    for CoreMark's 7.2 KiB. ../build_spike.sh now relocates that ROM to
#    0x200000, so the images map exactly where the hardware has them.
#
# Like every co-sim here, the diff ends at the first UART access: Spike has
# no UART slave and traps. CoreMark does all its printing after the last
# iteration, so the entire benchmark is compared before that point.

SCRIPT_DIR := $(dir $(realpath $(lastword $(MAKEFILE_LIST))))
SPIKE      := $(SCRIPT_DIR)../riscv-isa-sim-install/bin/spike
SW_DIR     := $(SCRIPT_DIR)../../sw/coremark
ELF        := $(SW_DIR)/build/program.elf
IMEM_HEX   := $(SW_DIR)/build/imem.hex
DMEM_HEX   := $(SW_DIR)/build/dmem.hex
SPIKE_LOG  := $(SCRIPT_DIR)spike.log
RTL_LOG    := $(SCRIPT_DIR)rtl.trace

ITERATIONS ?= 1
COSIM_OPT  ?= -O2

# Bound both runs. One iteration retires ~657 k instructions on the RTL at
# IPC ~0.48 (~1.37 M cycles); the caps clear that plus Spike's boot stub and
# leave room for the post-run printing up to the first UART store, where the
# diff stops. Raise both together if ITERATIONS is raised.
SPIKE_MAXINSTR ?= 900000
RTL_MAX_CYC    ?= 3000000

# zicsr/zifencei: Spike's boot stub reads mhartid, and the firmware is built
# for that arch string even though the co-sim variant emits no CSR access.
SPIKE_ISA := rv32imac_zicsr_zifencei
# Memory: 8 KiB at 0x0 (.text -- 7.2 KiB, the I-mem image) plus 8 KiB at
# 0x2000 (.rodata/.data/.bss + stack, sp = 0x4000 growing down). Together
# they are the 16 KiB D-mem's data half and the I-mem, mapped where the
# hardware has them. Spike's boot ROM no longer sits between them.
SPIKE_MEM := 0x0:0x2000,0x2000:0x2000

TC_ARGS := $(if $(RISCV_PREFIX),RISCV_PREFIX=$(RISCV_PREFIX))

.PHONY: cosim spike-build spike-run rtl-run diff clean sw-cosim-build

cosim: diff

spike-build:
	@bash $(SCRIPT_DIR)../build_spike.sh

# Built unconditionally: the artefacts are shared with `make -C sim/sw`,
# which builds the timed (COSIM=0) variant.
sw-cosim-build:
	@$(MAKE) -C $(SW_DIR) clean
	@$(MAKE) -C $(SW_DIR) COSIM=1 OPT=$(COSIM_OPT) ITERATIONS=$(ITERATIONS) $(TC_ARGS)
	@$(MAKE) --no-print-directory check-text-fits

# Fail loudly on the one build that cannot be co-simulated. Without this
# the run reports a register mismatch a couple of thousand retires in,
# which reads as a core bug and is not one.
.PHONY: check-text-fits
check-text-fits:
	@sz=$$(stat -c %s $(SW_DIR)/build/imem.bin); \
	 if [ $$sz -gt 8192 ]; then \
	   echo "cosim: .text is $$sz bytes, past the 0x2000 .data VMA."; \
	   echo "cosim: Spike is one address space -- the image would execute its own .rodata."; \
	   echo "cosim: build the co-sim variant smaller (COSIM_OPT), or move the data above the code."; \
	   exit 1; \
	 fi

$(ELF) $(IMEM_HEX) $(DMEM_HEX): sw-cosim-build

spike-run: $(ELF) spike-build
	@echo "== running Spike (golden) =="
	@rm -f $(SPIKE_LOG)
	@$(SPIKE) --isa=$(SPIKE_ISA) -m$(SPIKE_MEM) \
	    --instructions=$(SPIKE_MAXINSTR) --log-commits $(ELF) 2> $(SPIKE_LOG) \
	  || true
	@echo "spike: $$(wc -l < $(SPIKE_LOG)) commit lines -> $(SPIKE_LOG)"

rtl-run: $(IMEM_HEX) $(DMEM_HEX)
	@echo "== running RTL sim (RTL_TRACE=$(RTL_LOG)) =="
	@rm -f $(RTL_LOG)
	@RTL_TRACE=$(RTL_LOG) MAX_CYC=$(RTL_MAX_CYC) NO_VCD=1 \
	  $(MAKE) -C $(SCRIPT_DIR)../.. run \
	    RUN_ARGS="+IINIT=sw/coremark/build/imem.hex +DINIT=sw/coremark/build/dmem.hex" \
	  >/dev/null
	@test -s $(RTL_LOG) || { echo "rtl: no trace produced (RTL_TRACE unset?)"; exit 1; }
	@echo "rtl: $$(wc -l < $(RTL_LOG)) retires -> $(RTL_LOG)"

diff: spike-run rtl-run
	@python3 $(SCRIPT_DIR)../cosim_diff.py --rtl $(RTL_LOG) --spike $(SPIKE_LOG)

clean:
	rm -f $(SPIKE_LOG) $(RTL_LOG)
