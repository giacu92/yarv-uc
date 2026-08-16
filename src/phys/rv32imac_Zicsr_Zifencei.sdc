# =============================================================================
# SDC — Timing constraints for the RV32IMAC core on Tang Nano 20k
#
# Target board:  Sipeed Tang Nano 20k (GW2AR-LV18QN88C8/I7, QFN88)
# Primary clock: 25 MHz differential reference (MS5351M clock generator,
#   crystal-fed) on PIN10 (P) / PIN11 (N), Bank 6.
#
# Gowin PnR reads this file (cmd.do passes `-sdc .../rv32imac_Zicsr_Zifencei.sdc`).
# The Gowin SDC subset supports:
#   - create_clock / create_generated_clock
#   - set_input_delay / set_output_delay
#   - set_false_path / set_multicycle_path
# (no set_clock_groups / set_max_delay by default — keep it minimal.)
# =============================================================================

# Primary clock: 25 MHz differential input on the positive pin clk_p_i
# (the negative pin clk_n_i is its complement; the clock is single-ended
# inside the FPGA after the TLVDS_IBUF). Period = 40 ns. 50/50 duty cycle.
create_clock -name clk25 -period 40 [get_ports {clk_p_i}]

# CPU core clock: rPLL CLKOUT drives the clk_core net.
#   fCLKOUT = FCLKIN * FBDIV / IDIV = 25 * 20 / 5 = 100 MHz
#   (IDIV_SEL=4 -> IDIV=5, FBDIV_SEL=19 -> FBDIV=20; ODIV_SEL=8 sets the
#   VCO = 25*20*8/5 = 800 MHz but does NOT divide CLKOUT).
#   Period = 40 / 4 = 10 ns.  multiply_by 4 / divide_by 1 expresses the
#   20/5 ratio in smallest integers.
# Gowin auto-derives a clock on the rPLL output (named *.default_gen_clk);
# this explicit constraint takes precedence (a PnR warning is expected and
# harmless — it just names the clock clk_core for the timing reports).
create_generated_clock -name clk_core -source [get_ports {clk_p_i}] -master_clock clk25 -multiply_by 4 -divide_by 1 [get_nets {clk_core}]

# Async reset: treat rstn_i as asynchronous to the fabric clocks.
# (We do not currently generate / assert rstn_i internally; this is
# documentation for future use.)
set_false_path -from [get_ports {rstn_i}]

# Debug LEDs are not timing-critical (human eye).
set_false_path -to [get_ports {led_o[*]}]

# Single clock domain: the CPU, both AXI4-Lite bridges, the buses and
# the axi4_lite_ram slave all run on clk_core (100 MHz, generated above).
# clk_p_i (25 MHz, clk25) only feeds the rPLL — there are no user-logic
# paths on clk25, so there is no clock-domain crossing to cut. Slave
# outputs (rdata, rvalid, etc.) are registered in axi4_lite_ram and
# captured on the same clk_core edge; no set_input_delay is needed for
# this single-chip topology.
