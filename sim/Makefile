# Verilator simulation for the RV32 fetch + decode subsystem.
#
#   make          build the sim binary (obj_dir/Vsim_top)
#   make run      build + run, prints the fetch + decode logs
#   make wave     open the VCD in gtkwave (if installed)
#   make clean    remove build artefacts + waveforms
#
# Requires: verilator, make, g++. Install on Debian/Ubuntu:
#   sudo apt-get install -y verilator

# RTL sources (relative to this sim/ dir). axi4_lite_xbar is the peri-bus
# 1->2 mux (msip_peri vs clint_timer, addr[12] decode). axi4_lite_ram is
# not instantiated by sim_top (Harvard uses native_ram); it is exercised by
# the standalone sim/hw/ram_tb build, which has its own VSRC.
RTL := \
	../src/rtl/pkg/rv32_pkg.sv \
	../src/rtl/bus/axi4_lite_if.sv \
	../src/rtl/bus/axi4_lite_master_bridge.sv \
	../src/rtl/bus/axi4_lite_xbar.sv \
	../src/rtl/bus/axi4_lite_xbar_3.sv \
	../src/rtl/core/fetch_stage.sv \
	../src/rtl/core/reg_file.sv \
	../src/rtl/core/csr_regfile.sv \
	../src/rtl/core/align_stage.sv \
	../src/rtl/core/decode_stage.sv \
	../src/rtl/core/trap_unit.sv \
	../src/rtl/core/alu.sv \
	../src/rtl/core/branch_predictor.sv \
	../src/rtl/core/execute_stage.sv \
	../src/rtl/core/rv32imac_zicsr_zifencei.sv \
	../src/rtl/utils/native_ram.sv \
	../src/rtl/utils/msip_peri.sv \
	../src/rtl/utils/clint_timer.sv \
	../src/rtl/utils/axi4_lite_uart.sv \
	sim_top.sv

# Harvard topology: native u_imem (read-only) + u_dmem (byte-strobed) on
# dedicated CPU ports, AXI only for peripherals (msip_peri + clint_timer
# behind the peri xbar).
# Extra Verilator parameter overrides, e.g. board-accurate UART timing:
#   make VPARAMS="-GUART_CLK_HZ=25000000 -GUART_BAUD=115200"
# (pair it with UART_BIT_CYCLES=217 at run time, and rm -rf obj_dir first --
# a VPARAMS change is not tracked by the build dependencies).
VPARAMS ?=

VFLAGS := --cc --exe --build --top-module sim_top $(VPARAMS) \
	-Wno-WIDTH -Wno-UNUSED -Wno-UNOPTFLAT -Wno-LATCH -Wno-INITIALDLY -Wno-TIMESCALEMOD \
	--public-flat-rw \
	--trace \
	-I../src/rtl/pkg -I../src/rtl/core -I../src/rtl/bus -I../src/rtl/utils

HEX_PREREQ := imem.hex dmem.hex

TOP := obj_dir/Vsim_top

# Extra args for the sim binary.
#   RUN_ARGS="+IINIT=sw/quicksort/build/imem.hex +DINIT=sw/quicksort/build/dmem.hex"
# With no RUN_ARGS the sim loads the defaults baked into sim_top
# (imem.hex/dmem.hex).
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