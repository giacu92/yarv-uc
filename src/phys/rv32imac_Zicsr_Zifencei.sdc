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
# 50/50 duty cycle. clk_core is clk_i directly (no rPLL — see top_module),
# so this single clock constrains the whole fabric.
create_clock -name clk25 -period 40 [get_ports {clk_i}]

# Async reset: treat rstn_i as asynchronous to the fabric clocks.
# (We do not currently generate / assert rstn_i internally; this is
# documentation for future use.)
set_false_path -from [get_ports {rstn_i}]

# Debug LEDs are not timing-critical (human eye).
set_false_path -to [get_ports {led_o[*]}]

# Single clock domain: the CPU, both AXI4-Lite bridges, the buses and
# the axi4_lite_ram slave all run on clk_core (= clk_i, 25 MHz, clk25
# above). There are no user-logic paths on a separate clock, so there is
# no clock-domain crossing to cut. Slave outputs (rdata, rvalid, etc.)
# are registered in axi4_lite_ram and captured on the same clk_core edge;
# no set_input_delay is needed for this single-chip topology.
