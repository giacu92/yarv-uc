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

# ----------------------------------------------------------------------
# regress — run every self-checking test and report pass/fail
# ----------------------------------------------------------------------
#
#   make regress                                run every test
#   make regress VPARAMS="-GLSU_LIVE_LOAD=0"    ... against an A/B config
#
# Needs the firmware built: `make -C sw` builds all of it. A test whose images
# are missing is reported SKIP, not FAIL, so a partial tree still runs.
#
# Three kinds of check, because the tests genuinely differ in how they report:
#
#   probe@<addr>=<hex>  Read a D-mem word back out of the RTL (PROBE, see
#                       sim_main.cpp) and compare. This is the exact result.
#                       Do NOT substitute a grep of the retire trace: the `li`
#                       that materialises 0x600D retires whether or not the
#                       store after it ever ran, so a trace grep passes a test
#                       that died between the two.
#   trace:<reg>=<hex>   Last writeback of that register in the retire trace.
#                       For quicksort, whose main() RETURNS 0x600D in a0 and
#                       never stores it -- start.S just parks. Its real
#                       verification is `make cosim`, which compares every one
#                       of 29293 retires against Spike; this is a smoke check
#                       plus a cycle number.
#   park                Clean park + WFI-halt invariant only. The hand-crafted
#                       Harvard oracle has no marker at all -- it is a
#                       load/store and RAW round-trip covered by the cosim.
#
# Every test also fails on a WFI-HALT FAIL regardless of its marker.
#
# uart_echo is special-cased at the end: it needs UART_RX stimulus, and its
# pass condition is the "GOOD" its firmware transmits, not a memory word.
REGRESS_TESTS := \
	quicksort:quicksort:200000:trace:x10=600d \
	bp_pred:isa/bp_pred:20000:probe@0x2000=600d \
	mul_ops:isa/mul_ops:20000:probe@0x2000=600d \
	div_ops:isa/div_ops:20000:probe@0x2000=600d \
	rvc_scramble:isa/rvc_scramble:20000:probe@0x2000=600d \
	span_target:isa/span_target:20000:probe@0x2000=600d \
	ifault:isa/ifault:20000:probe@0x2000=600d \
	isa_probe:isa/isa_probe:200000:park \
	trap:intr/trap:20000:probe@0x2000=600d \
	wfi_trap:intr/wfi_trap:20000:probe@0x2000=600d \
	timer:intr/timer:20000:probe@0x2000=600d

regress: $(TOP)
	@fail=0; skip=0; pass=0; \
	printf '%-15s %-6s %s\n' TEST RESULT DETAIL; \
	for t in $(REGRESS_TESTS); do \
	    name=$$(echo "$$t" | cut -d: -f1); \
	    dir=$$(echo  "$$t" | cut -d: -f2); \
	    maxc=$$(echo "$$t" | cut -d: -f3); \
	    check=$$(echo "$$t" | cut -d: -f4-); \
	    if [ ! -f "sw/$$dir/build/imem.hex" ]; then \
	        printf '%-15s %-6s %s\n' "$$name" SKIP "no build/ -- run: make -C sw/$$dir"; \
	        skip=$$((skip+1)); continue; \
	    fi; \
	    probe=; want=; reg=; \
	    case "$$check" in \
	      probe@*) probe=$$(echo "$$check" | sed 's/^probe@\([^=]*\)=.*/\1/'); \
	               want=$$(echo "$$check" | sed 's/.*=//');; \
	      trace:*) reg=$$(echo  "$$check" | sed 's/^trace:\([^=]*\)=.*/\1/'); \
	               want=$$(echo "$$check" | sed 's/.*=//');; \
	    esac; \
	    out=$$(PROBE=$$probe NO_VCD=1 MAX_CYC=$$maxc RTL_TRACE=.regress.trace ./$(TOP) \
	           +IINIT=sw/$$dir/build/imem.hex +DINIT=sw/$$dir/build/dmem.hex 2>&1); \
	    cyc=$$(echo "$$out" | sed -n 's/^retired [0-9]* instructions in \([0-9]*\) cycles.*/\1/p'); \
	    bad=; \
	    echo "$$out" | grep -q 'WFI-HALT FAIL' && bad="WFI-HALT FAIL"; \
	    echo "$$out" | grep -q 'parked at' || bad="$$bad no clean park"; \
	    got=; \
	    if [ -n "$$probe" ]; then \
	        got=$$(echo "$$out" | sed -n 's/^probe\[.*\] = 0x0*\([0-9a-fA-F]*\)$$/\1/p' | tail -1); \
	    elif [ -n "$$reg" ]; then \
	        got=$$(sed -n "s/^0x[0-9a-f]* $$reg 0x0*\([0-9a-f]*\)$$/\1/p" .regress.trace | tail -1); \
	    fi; \
	    if [ -n "$$want" ] && [ "$$got" != "$$want" ]; then \
	        bad="$$bad marker=0x$${got:-none} want=0x$$want"; \
	    fi; \
	    if [ -z "$$bad" ]; then \
	        printf '%-15s %-6s %s\n' "$$name" PASS "$$cyc cyc"; pass=$$((pass+1)); \
	    else \
	        printf '%-15s %-6s %s\n' "$$name" FAIL "$$cyc cyc --$$bad"; fail=$$((fail+1)); \
	    fi; \
	done; \
	rm -f .regress.trace; \
	if [ -f sw/peri/uart_echo/build/imem.hex ]; then \
	    out=$$(UART_RX='abcdefgh' NO_VCD=1 MAX_CYC=400000 ./$(TOP) \
	           +IINIT=sw/peri/uart_echo/build/imem.hex \
	           +DINIT=sw/peri/uart_echo/build/dmem.hex 2>&1); \
	    cyc=$$(echo "$$out" | sed -n 's/^retired [0-9]* instructions in \([0-9]*\) cycles.*/\1/p'); \
	    if tr -d '\n\r' < sim_uart_tx.txt | grep -q 'GOOD$$'; then \
	        printf '%-15s %-6s %s\n' uart_echo PASS "$$cyc cyc, TX ends GOOD"; pass=$$((pass+1)); \
	    else \
	        printf '%-15s %-6s %s\n' uart_echo FAIL "TX does not end GOOD"; fail=$$((fail+1)); \
	    fi; \
	else \
	    printf '%-15s %-6s %s\n' uart_echo SKIP "no build/"; skip=$$((skip+1)); \
	fi; \
	out=$$(NO_VCD=1 MAX_CYC=4000 ./$(TOP) 2>&1); \
	if echo "$$out" | grep -q 'WFI-halt check: OK' && echo "$$out" | grep -q 'parked at'; then \
	    printf '%-15s %-6s %s\n' harvard_oracle PASS "parks clean"; pass=$$((pass+1)); \
	else \
	    printf '%-15s %-6s %s\n' harvard_oracle FAIL "no clean park"; fail=$$((fail+1)); \
	fi; \
	echo; echo "$$pass passed, $$fail failed, $$skip skipped"; \
	[ $$fail -eq 0 ]

wave: sim_top.vcd
	gtkwave sim_top.vcd

clean:
	rm -rf obj_dir *.vcd *.fst *.log

.PHONY: run regress wave clean