# Co-sim harness: run the same C-built ELF on Spike (golden ISA ref) and on
# the Verilator RTL sim, then diff per-retire architectural effects (pc +
# register write). See cosim_diff.py / build_spike.sh.
#
#   make cosim        full pipeline: build sw + Spike, run both, diff
#   make spike-build  build the local Spike (once; see build_spike.sh for deps)
#   make spike-run    run Spike -> spike.log
#   make rtl-run      run the Verilator sim -> rtl.trace (loads the sw hex)
#   make diff        diff spike.log vs rtl.trace
#   make clean        remove logs (keeps the Spike build)
#
# Spike is upstream riscv-isa-sim (built with --enable-commitlog); Zilx is
# already implemented upstream as the "zilx" ISA extension -- no patch.
#
# NOTE: the RTL sim must build. If decode_stage.sv has uncommitted WIP that
# breaks the build, fix it first -- cosim cannot run without a building sim.

SCRIPT_DIR := $(dir $(realpath $(lastword $(MAKEFILE_LIST))))
SPIKE      := $(SCRIPT_DIR)riscv-isa-sim-install/bin/spike
ELF        := $(SCRIPT_DIR)../sw/build/program.elf
# Harvard: the C build emits a code image (-> I-mem) and a data image
# (-> D-mem), not a single program.hex. The RTL sim loads both.
IMEM_HEX   := $(SCRIPT_DIR)../sw/build/imem.hex
DMEM_HEX   := $(SCRIPT_DIR)../sw/build/dmem.hex
SPIKE_LOG  := $(SCRIPT_DIR)spike.log
RTL_LOG    := $(SCRIPT_DIR)rtl.trace

# Bound the Spike run. Spike spins forever on the halt self-loop. Stop it
# with Spike's own --instructions cap: Spike exits cleanly after N commits
# (<1s), no pipe/zombie. We do NOT wrap in `timeout` -- on WSL `timeout`
# fails to reap a dead spike child, leaving `make` hung at this recipe even
# though spike.log is complete. `--instructions` makes the cap reliable on
# its own; `|| true` covers a spike crash. The program is a few thousand
# retires; the rest is the spinning `j`, park-truncated by the diff driver.
SPIKE_MAXINSTR ?= 50000

# zicsr/zifencei: needed only for Spike's boot-ROM stub (csrr mhartid). The
# program emits no csr/fence; the RTL defers them (illegal=1) but never sees
# them because the stub is skipped by the diff driver. zilx: the indexed
# loads (same encoding as this core).
SPIKE_ISA := rv32imac_zicsr_zifencei_zilx
# Memory: 4 KiB at 0x0 (code + .data, below the 0x1000 boot ROM) + 56 KiB at
# 0x2000 (stack; sp=0x10000 grows down). The 0x1000 boot-ROM gap avoids any
# overlap between DRAM and the boot-ROM device.
SPIKE_MEM := 0x0:0x1000,0x2000:0xE000

.PHONY: cosim spike-build spike-run rtl-run diff clean

cosim: diff

spike-build:
	@bash $(SCRIPT_DIR)build_spike.sh

# Build the C program (ELF for Spike, imem/dmem hex for the RTL) if missing.
$(ELF) $(IMEM_HEX) $(DMEM_HEX):
	@$(MAKE) -C $(SCRIPT_DIR)../.. sw

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
	@RTL_TRACE=$(RTL_LOG) MAX_CYC=20000 \
	  $(MAKE) -C $(SCRIPT_DIR).. run \
	    RUN_ARGS="+IINIT=sw/build/imem.hex +DINIT=sw/build/dmem.hex" \
	  >/dev/null
	@test -s $(RTL_LOG) || { echo "rtl: no trace produced (RTL_TRACE unset? sim_main.cpp edit missing?)"; exit 1; }
	@echo "rtl: $$(wc -l < $(RTL_LOG)) retires -> $(RTL_LOG)"

diff: spike-run rtl-run
	@python3 $(SCRIPT_DIR)cosim_diff.py --rtl $(RTL_LOG) --spike $(SPIKE_LOG)

clean:
	rm -f $(SPIKE_LOG) $(RTL_LOG)