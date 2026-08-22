# Verilator AXI4-Lite RAM compliance test.
#
#   make          build the test binary (obj_dir/Vram_tb)
#   make run      build + run, prints the compliance check results
#   make clean    remove build artefacts
#
# Requires: verilator, g++.

RTL := \
	../../../src/rtl/bus/axi4_lite_if.sv \
	../../../src/rtl/utils/axi4_lite_ram.sv \
	ram_tb.sv

VFLAGS := --cc --exe --build --top-module ram_tb \
	-Wno-WIDTH -Wno-UNUSED -Wno-UNOPTFLAT -Wno-LATCH -Wno-INITIALDLY -Wno-TIMESCALEMOD \
	-I../../../src/rtl/bus -I../../../src/rtl/utils

TOP := obj_dir/Vram_tb

$(TOP): ram_tb.cpp $(RTL)
	verilator $(VFLAGS) ram_tb.cpp $(RTL)

run: $(TOP)
	./$(TOP)

clean:
	rm -rf obj_dir *.vcd *.fst *.log

.PHONY: run clean