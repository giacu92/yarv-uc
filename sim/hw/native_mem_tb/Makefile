# Verilator native mem_req_t / mem_rsp_t RAM compliance test.
#
#   make          build the test binary (obj_dir/Vnative_mem_tb)
#   make run      build + run, prints the compliance check results
#   make clean    remove build artefacts
#
# Requires: verilator, g++.

RTL := \
	../../../src/rtl/pkg/rv32_pkg.sv \
	../../../src/rtl/utils/native_ram.sv \
	native_mem_tb.sv

VFLAGS := --cc --exe --build --top-module native_mem_tb \
	-Wno-WIDTH -Wno-UNUSED -Wno-UNOPTFLAT -Wno-LATCH -Wno-INITIALDLY -Wno-TIMESCALEMOD \
	-I../../../src/rtl/pkg -I../../../src/rtl/utils

TOP := obj_dir/Vnative_mem_tb

$(TOP): native_mem_tb.cpp $(RTL)
	verilator $(VFLAGS) native_mem_tb.cpp $(RTL)

run: $(TOP)
	./$(TOP)

clean:
	rm -rf obj_dir *.vcd *.fst *.log

.PHONY: run clean