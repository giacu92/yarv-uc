# =============================================================================
# SDC — Timing constraints for the RV32IMAC core on Tang Nano 20k
#
# Target board:  Sipeed Tang Nano 20k (GW2AR-LV18QN88C8/I7, QFN88)
# Primary clock: 27 MHz onboard oscillator on PIN4
#
# Gowin PnR reads this file when invoked with `-sdc impl/pnr/<name>.sdc`.
# The Gowin SDC subset supports:
#   - create_clock / create_generated_clock
#   - set_input_delay / set_output_delay
#   - set_false_path / set_multicycle_path
# (no set_clock_groups / set_max_delay by default — keep it minimal.)
# =============================================================================

# Primary clock: 27 MHz from the onboard oscillator on PIN4.
# Period = 37.037 ns. 50/50 duty cycle.
create_clock -name clk27 -period 37.037 [get_ports {clk_i}]

# CPU core clock: rPLL CLKOUT drives the clk_core net.
#   fCLKOUT = FCLKIN * FBDIV / IDIV = 27 * 22 / 6 = 99 MHz
#   (IDIV_SEL=5 -> IDIV=6, FBDIV_SEL=21 -> FBDIV=22; ODIV_SEL=8 sets the
#   VCO = 27*22*8/6 = 792 MHz but does NOT divide CLKOUT).
#   Period = 37.037 * 3 / 11 = 10.101 ns.  multiply_by 11 / divide_by 3
#   expresses the 22/6 ratio in smallest integers.
# Gowin auto-derives a clock on the rPLL output (named *.default_gen_clk);
# this explicit constraint takes precedence (a PnR warning is expected and
# harmless — it just names the clock clk_core for the timing reports).
create_generated_clock -name clk_core -source [get_ports {clk_i}] -master_clock clk27 \
    -multiply_by 11 -divide_by 3 [get_nets {clk_core}]

# Async reset: treat rstn_i as asynchronous to clk_i.
# (We do not currently generate / assert rstn_i internally; this is
# documentation for future use.)
set_false_path -from [get_ports {rstn_i}]

# Debug LEDs are not timing-critical (human eye).
set_false_path -to [get_ports {led_o[*]}]

# Master AXI4-Lite port: inputs from the slave (rdata, rvalid, etc.)
# are assumed to be registered by the slave (axi4_lite_ram) and are
# captured on the same clk_i edge. No set_input_delay needed for the
# current single-chip topology (CPU + RAM live in the same FPGA).
