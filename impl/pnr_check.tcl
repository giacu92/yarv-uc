# Gowin PnR check — invoked manually after synth, mirrors synth_check.tcl.
#
# Runs place & route via the modern `run pnr` Tcl command, which uses the
# PnR options saved in the project (.gprj + per-machine .gprj.user) — the
# same config the GUI uses and that produced the clk_core Fmax baseline.
# The canonical options also live in impl/pnr/cmd.do for reference. Note:
# `gw_sh -pnr -do <file>` is NOT a valid flow (-do isn't a `run pnr` flag)
# and the legacy `run_pnr -opt <file>` does not exist in V1.9.11.03, so
# this Tcl wrapper is the working CLI path.
open_project /home/giacomo/gowin_proj/rv32imac_Zicsr_Zifencei/rv32imac_Zicsr_Zifencei.gprj
set_option -top_module top_module
# Force the PnR target frequency. *** 40 MHz rPLL MODE (active): clk_core
# = clk_i * 8/5 (see top_module's rPLL and the SDC generated clock). The
# SDC is the real constraint; this must agree with it so the two never
# disagree about what the design is being asked to do. To fall back to the
# 25 MHz PLL-bypass build: comment the rPLL out, re-comment the SDC
# generated clock, and set this back to 25.000. ***
set_option -global_freq 40.000
run pnr