# Verilator simulation for the RV32 fetch + decode subsystem.
#
#   make          build the sim binary (obj_dir/Vsim_top)
#   make run      build + run, prints the fetch + decode logs
#   make wave     open the VCD in gtkwave (if installed)
#   make clean    remove build artefacts + waveforms
#
# Requires: verilator, make, g++. Install on Debian/Ubuntu:
#   sudo apt-get install -y verilator

# RTL sources (relative to this sim/ dir).
RTL := \
	../src/rtl/pkg/rv32_pkg.sv \
	../src/rtl/bus/axi4_lite_if.sv \
	../src/rtl/bus/axi4_lite_master_bridge.sv \
	../src/rtl/core/fetch_stage.sv \
	../src/rtl/core/reg_file.sv \
	../src/rtl/core/decode_stage.sv \
	../src/rtl/core/alu.sv \
	../src/rtl/core/execute_stage.sv \
	../src/rtl/core/rv32imac_zicsr_zifencei.sv \
	../src/rtl/utils/axi4_lite_ram.sv \
	sim_top.sv

VFLAGS := --cc --exe --build --top-module sim_top \
	-Wno-WIDTH -Wno-UNUSED -Wno-UNOPTFLAT -Wno-LATCH -Wno-INITIALDLY -Wno-TIMESCALEMOD \
	--trace \
	-I../src/rtl/pkg -I../src/rtl/core -I../src/rtl/bus -I../src/rtl/utils

TOP := obj_dir/Vsim_top

$(TOP): sim_main.cpp $(RTL) program.hex
	verilator $(VFLAGS) sim_main.cpp $(RTL)

run: $(TOP)
	./$(TOP)

wave: sim_top.vcd
	gtkwave sim_top.vcd

clean:
	rm -rf obj_dir *.vcd *.fst *.log

.PHONY: run wave clean