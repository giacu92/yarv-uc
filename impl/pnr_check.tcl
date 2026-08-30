# Gowin PnR check — invoked manually after synth, mirrors synth_check.tcl.
#
# Runs place & route via the modern `run pnr` Tcl command, which uses the
# PnR options saved in the project (.gprj + per-machine .gprj.user) — the
# same config the GUI uses and that produced the clk_core Fmax baseline.
# impl/pnr/cmd.do is an OUTPUT, not an input: `run pnr` overwrites it with
# a dump of the options it actually used, so editing it changes nothing and
# the edit is lost on the next run. Every option has to be set here, with
# set_option, before `run pnr` -- that is why -global_freq lives in this
# file. Note also: `gw_sh -pnr -do <file>` is NOT a valid flow (-do isn't a
# `run pnr` flag) and the legacy `run_pnr -opt <file>` does not exist in
# V1.9.11.03, so this Tcl wrapper is the working CLI path.
open_project /home/giacomo/gowin_proj/rv32imac_Zicsr_Zifencei/rv32imac_Zicsr_Zifencei.gprj
set_option -top_module top_module
# Force the PnR target frequency. *** 50 MHz rPLL MODE (active): clk_core
# = clk_i * 10/5 (see top_module's rPLL and the SDC generated clock). The
# SDC is the real constraint; this must agree with it so the two never
# disagree about what the design is being asked to do. To fall back to the
# 25 MHz PLL-bypass build: comment the rPLL out, re-comment the SDC
# generated clock, and set this back to 25.000. ***
set_option -global_freq 50.000

# Placer/router algorithm. Both default to 0, which optimises compile speed
# / congestion rather than timing -- this design cannot afford that: its
# failing paths are routing-dominated (a 2026-08-31 report showed 3.36 ns of
# pure routing inside one 6.1 ns segment), and two runs of near-identical
# RTL moved the same path by ~0.7 ns, placement noise comparable to the
# entire gap being closed. Both settings below cost only PnR wall-clock.
#
# These are algorithm SELECTORS, not effort levels -- the numbers do not
# mean "more effort" and they do not mean the same thing on both options:
#   -place_option  0 = default, compilation-speed priority
#                  1 = routability priority
#                  2 = timing priority              <- what we want
#   -route_option  0 = default, routes by congestion
#                  1 = routes by timing             <- what we want
#                  2 = faster routing (compile speed, NOT quality)
# So the timing-priority pair is 2 / 1, not 2 / 2.
set_option -place_option 2
set_option -route_option 1

run pnr