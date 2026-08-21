# Verilator simulation for the RV32 fetch + decode subsystem.
#
#   make          build the sim binary (obj_dir/Vsim_top)
#   make run      build + run, prints the fetch + decode logs
#   make wave     open the VCD in gtkwave (if installed)
#   make clean    remove build artefacts + waveforms
#
# Requires: verilator, make, g++. Install on Debian/Ubuntu:
#   sudo apt-get install -y verilator

# RTL sources (relative to this sim/ dir). mem_arbiter / axi4_lite_xbar /
# axi4_lite_ram are only instantiated under VON_NEUMANN; they stay on the
# list so both builds compile from the same sources (unused modules are
# harmless to Verilator).
RTL := \
	../src/rtl/pkg/rv32_pkg.sv \
	../src/rtl/bus/axi4_lite_if.sv \
	../src/rtl/bus/axi4_lite_master_bridge.sv \
	../src/rtl/bus/mem_arbiter.sv \
	../src/rtl/bus/axi4_lite_xbar.sv \
	../src/rtl/core/fetch_stage.sv \
	../src/rtl/core/reg_file.sv \
	../src/rtl/core/csr_regfile.sv \
	../src/rtl/core/decode_stage.sv \
	../src/rtl/core/trap_unit.sv \
	../src/rtl/core/alu.sv \
	../src/rtl/core/execute_stage.sv \
	../src/rtl/core/rv32imac_zicsr_zifencei.sv \
	../src/rtl/utils/axi4_lite_ram.sv \
	../src/rtl/utils/native_ram.sv \
	../src/rtl/utils/msip_peri.sv \
	sim_top.sv

# Build topology: VON_NEUMANN=1 selects the legacy von-Neumann/AXI build
# (fetch+LSU share one AXI master through mem_arbiter + axi4_lite_xbar).
# Default (0/empty) is Harvard: native u_imem (read-only) + u_dmem
# (byte-strobed) on dedicated CPU ports, AXI only for peripherals.
VON_NEUMANN ?=

VFLAGS := --cc --exe --build --top-module sim_top \
	-Wno-WIDTH -Wno-UNUSED -Wno-UNOPTFLAT -Wno-LATCH -Wno-INITIALDLY -Wno-TIMESCALEMOD \
	--public-flat-rw \
	--trace \
	-I../src/rtl/pkg -I../src/rtl/core -I../src/rtl/bus -I../src/rtl/utils

ifeq ($(VON_NEUMANN),1)
VFLAGS += +define+VON_NEUMANN
HEX_PREREQ := program.hex
else
HEX_PREREQ := imem.hex dmem.hex
endif

TOP := obj_dir/Vsim_top

# Extra args for the sim binary.
#   Harvard (default): RUN_ARGS="+IINIT=sw/build/imem.hex +DINIT=sw/build/dmem.hex"
#   Von-Neumann:       RUN_ARGS="+INIT=sw/build/program.hex"  (and VON_NEUMANN=1)
# With no RUN_ARGS the sim loads the defaults baked into sim_top
# (imem.hex/dmem.hex for Harvard, program.hex for von-Neumann).
RUN_ARGS ?=

$(TOP): sim_main.cpp $(RTL) $(HEX_PREREQ)
	verilator $(VFLAGS) sim_main.cpp $(RTL)

run: $(TOP)
	./$(TOP) $(RUN_ARGS)

wave: sim_top.vcd
	gtkwave sim_top.vcd

clean:
	rm -rf obj_dir *.vcd *.fst *.log

.PHONY: run wave clean