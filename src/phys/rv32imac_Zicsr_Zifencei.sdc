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
# *** 65 MHz rPLL MODE (active, TIMING PROBE): clk_core = clk_i * 13 / 5 =
# 65 MHz exactly, period 15.385 ns. Must agree with top_module's rPLL
# (IDIV_SEL=4 / FBDIV_SEL=12 / ODIV_SEL=16) and with global_freq in
# pnr_check.tcl / impl/pnr/cmd.do — if these three disagree the reports are
# constrained to something the design does not run at.
#
# This is a deliberately unreachable target, the second of two probe points.
# The design closes at 50 MHz (+0.013 ns worst setup slack) and its longest
# path measures 20.10-20.13 ns. The 100 MHz probe (10 ns) reported a 20.130 ns
# worst path = Fmax ~49.7 MHz, i.e. asking for 2x made the longest path
# slightly worse than the 50 MHz run's 19.952 ns — PnR was not holding back,
# there is no hidden margin. 65 MHz is ~30% out of reach instead of 100%, to
# check the path ranking is stable rather than an artefact of extreme
# over-constraint. Expect negative slack and a bitstream that does not run.
#   Back to the shipping 50 MHz build: -multiply_by 10 below, FBDIV_SEL=9 /
#   ODIV_SEL=16 + CLK_CORE_HZ=50_000_000 in top_module, global_freq 50.000.
#   Back to the 25 MHz PLL-bypass build: comment the rPLL out in top_module,
#   comment the line below out (clk_core then inherits clk25's 40 ns), and
#   set global_freq back to 25.000. ***
# Gowin auto-derives a clock on the rPLL output (named *.default_gen_clk);
# this explicit constraint takes precedence (a PnR warning is expected and
# harmless — it just names the clock clk_core for the timing reports).
create_generated_clock -name clk_core -source [get_ports {clk_i}] -master_clock clk25 -multiply_by 13 -divide_by 5 [get_nets {clk_core}]

# Async reset: treat rst_i (board reset button S1, active-high on this
# board) as asynchronous to the fabric clocks.
set_false_path -from [get_ports {rst_i}]

# UART RX pin: driven by a far-end transmitter with its own oscillator, so
# it is asynchronous to clk_core by definition. top_module double-flops it
# before the UART's sampler, which is the synchronizer that makes the
# crossing safe; there is no launch clock to relate it to, so cut it.
set_false_path -from [get_ports {uart_rxd_i}]

# Debug LEDs are not timing-critical (human eye).
set_false_path -to [get_ports {led_o[*]}]

# Single clock domain: the CPU, both AXI4-Lite bridges, the buses and
# the peripheral slaves all run on clk_core (65 MHz, generated above).
# clk_i (25 MHz, clk25) only feeds the rPLL — there are no user-logic
# paths on clk25, so there is no clock-domain crossing to cut. Slave
# outputs (rdata, rvalid, etc.) are registered in axi4_lite_ram and
# captured on the same clk_core edge; no set_input_delay is needed for
# this single-chip topology.
