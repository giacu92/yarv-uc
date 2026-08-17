# YARV-uC: Yet Another RISC-V uController

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/giacu92/yarv-uc)



A RV32IMAC + Zicsr + Zifencei RISC-V processor core targeting a **Gowin
GW2AR-18C** FPGA (`GW2AR-LV18QN88C8/I7`, QFN88) on a Tang Nano 20k-based
board. The board is clocked by a 25 MHz single-ended reference from an
MS5351M clock generator (CLK0 on PIN10, LVCMOS33); an on-chip rPLL
multiplies it up to a 50 MHz `clk_core` that drives the whole fabric.

The core is a work-in-progress in-order pipeline. Implemented so far:

- **Fetch** — single-outstanding overlap-prefetch of 32-bit words over a
  native memory interface, with branch redirect + in-flight flush.
- **Decode** — expand-then-decode-uniformly: RVC (C) instructions are
  expanded to their 32-bit RV32I equivalents, then one uniform decoder
  handles RV32I + M + C + Zilx indexed loads. Odd-half (upper-half)
  branch targets and 32-bit instructions spanning a fetch-word boundary
  (stitched from two consecutive words) are handled.
- **Execute (DRAFT)** — ALU (base RV32I + single-cycle MUL via DSP +
  multi-cycle DIV/REM + Zilx effective address), reg-file writeback
  (ALU/PC4), and branch resolve with fetch redirect.

Not yet present: the **LSU** (loads/stores/Zilx compute their effective
address but do not launch or retire), the **forwarding / hazard unit**
(RAW-dependent sequences read stale values), and the **CSR file**
(Zicsr) / **fence** (Zifencei) — those opcodes decode to `illegal=1`.

The CPU exits two AXI4-Lite masters (`imem_axi`, `peri_axi`); the native
`mem_req_t`/`mem_rsp_t` → AXI4-Lite conversion is done inside the CPU by
one `axi4_lite_master_bridge` per master port, so the rest of the system
sees a plain AXI4-Lite master.

## Repository layout

```
src/rtl/pkg/   rv32_pkg.sv          — types, opcodes, de_t D/E control struct
src/rtl/core/  pipeline stages + CPU top + reg file + ALU
src/rtl/bus/   AXI4-Lite interface + master bridge
src/rtl/utils/ axi4_lite_ram.sv     — AXI4-Lite slave RAM (imem)
src/phys/      pin assignment (.cst) + timing constraints (.sdc)
impl/          Gowin EDA project + synthesis/PnR Tcl + reports
sim/           Verilator functional sim + AXI4-Lite RAM compliance test
sim/sw/        C → program.hex flow (prebuilt rv32imac toolchain)
verible.flags  SystemVerilog formatting policy (Verible --flagfile)
Makefile       format / sim / sw targets
CLAUDE.md      detailed architecture + build guidance (read this)
```

## Quick start

### Simulate (Verilator, local)

Requires Verilator (`sudo apt-get install -y verilator`).

```
make run        # hand-crafted program.hex oracle (fetch/decode/retire logs)
make sw-run     # build the C program + run the sim loading it
```

See `sim/README.md` for the logs, VCD/GTKWave, and the AXI4-Lite RAM
compliance test (`sim/ram_tb/`).

### Synthesize / place & route (Gowin EDA, remote host)

The Gowin toolchain is **not** in this WSL env; it runs on the build host
(`gw_sh` at `/home/giacomo/gowin_ide/IDE/bin/gw_sh`). rsync the repo
there and run:

```
QT_QPA_PLATFORM=offscreen QT_OPENGL=software LIBGL_ALWAYS_SOFTWARE=1 \
  gw_sh impl/synth_check.tcl        # synthesize
QT_QPA_PLATFORM=offscreen QT_OPENGL=software LIBGL_ALWAYS_SOFTWARE=1 \
  gw_sh -pnr -do impl/pnr/cmd.do    # place & route -> .fs/.bin
```

`impl/synth_check.tcl` opens the `.gprj`, sets `top_module`, and runs
`syn`; read `impl/gwsynthesis/rv32imac_Zicsr_Zifencei_syn.rpt.html` for
errors/warnings (`gw_sh` prints only a banner to stdout). See `CLAUDE.md`
for the full remote-build workflow and the Gowin CLI quirks.

## Formatting

SystemVerilog is formatted with Verible (`make format` / `format-check` /
`format-diff`) using the policy in `verible.flags`.

## Documentation

`CLAUDE.md` is the authoritative source for the architecture, per-stage
behaviour, build flow, and known limitations — read it for anything beyond
this overview.