# =============================================================================
# SDC — Timing constraints for the RV32IMAC core on Tang Nano 20k
#
# Target board:  Sipeed Tang Nano 20k (GW2AR-LV18QN88C8/I7, QFN88)
# Primary clock: 25 MHz single-ended reference from the MS5351M clock
#   generator (crystal-fed; CLK0 on PIN10, LVCMOS33).
#
# Gowin PnR reads this file (cmd.do passes `-sdc .../rv32imac_Zicsr_Zifencei.sdc`).
# The Gowin SDC subset supports:
#   - create_clock / create_generated_clock
#   - set_input_delay / set_output_delay
#   - set_false_path / set_multicycle_path
# (no set_clock_groups / set_max_delay by default — keep it minimal.)
# =============================================================================

# Primary clock: 25 MHz single-ended input on clk_i (PIN10). Period = 40 ns.
# 50/50 duty cycle.
create_clock -name clk25 -period 40 [get_ports {clk_i}]

# CPU core clock.
# *** 25 MHz PLL-BYPASS MODE (active): clk_core = clk_i (no rPLL), so it
# inherits the 25 MHz clk25 constraint above (40 ns). The generated-clock
# constraint used for the 35 MHz rPLL build is commented out below. To
# retarget 35 MHz: restore top_module's rPLL instance AND uncomment the
# create_generated_clock here (and set pnr_check.tcl / cmd.do global_freq
# back to 35.000). ***
# Gowin auto-derives a clock on the rPLL output (named *.default_gen_clk);
# this explicit constraint takes precedence (a PnR warning is expected and
# harmless — it just names the clock clk_core for the timing reports).
# create_generated_clock -name clk_core -source [get_ports {clk_i}] -master_clock clk25 -multiply_by 7 -divide_by 5 [get_nets {clk_core}]

# Async reset: treat rst_i (board reset button S1, active-high on this
# board) as asynchronous to the fabric clocks.
set_false_path -from [get_ports {rst_i}]

# Debug LEDs are not timing-critical (human eye).
set_false_path -to [get_ports {led_o[*]}]

# Single clock domain: the CPU, both AXI4-Lite bridges, the buses and
# the axi4_lite_ram slave all run on clk_core (35 MHz, generated above).
# clk_i (25 MHz, clk25) only feeds the rPLL — there are no user-logic
# paths on clk25, so there is no clock-domain crossing to cut. Slave
# outputs (rdata, rvalid, etc.) are registered in axi4_lite_ram and
# captured on the same clk_core edge; no set_input_delay is needed for
# this single-chip topology.
