# Gowin synth check — invoked manually after RTL changes.
# NOTE: gw_sh silently no-ops if the .vg / .log already exist
# (see CLAUDE.md "Gowin CLI quirks"). Delete them first.
open_project /home/giacomo/gowin_proj/rv32imac_Zicsr_Zifencei/rv32imac_Zicsr_Zifencei.gprj
set_option -top_module top_module
run syn
