# YARV-uC: Yet Another RISC-V uController

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/giacu92/yarv-uc)

Disclaimer: This project is created by me with the assistance of Claude Code (Anthropic).
I used mostly AI for help me coding and verification of the core.

A RV32IMAC + Zicsr + Zifencei RISC-V processor core targeting a **Gowin
GW2AR-18C** FPGA (`GW2AR-LV18QN88C8/I7`, QFN88) on a Tang Nano 20k-based
board. The board is clocked by a 25 MHz single-ended reference from an
MS5351M clock generator (CLK0 on PIN10, LVCMOS33); an on-chip rPLL
multiplies it up to a 50 MHz `clk_core` that drives the whole fabric.

The core is a work-in-progress **in-order, 3-stage pipeline — Fetch /
Decode / Execute (F/D/E)** — with a **Harvard** memory system: a dedicated
read-only I-mem for fetch and a byte-strobed D-mem for the LSU, with AXI
kept only for peripherals. A compile-time `VON_NEUMANN` switch retains the
legacy single-AXI-master topology (fetch+LSU share one port through a
`mem_arbiter` + crossbar) as a fallback. Implemented so far:

- **Fetch** — single-outstanding overlap-prefetch of 32-bit words over a
  native memory interface, with a 1-entry skid buffer (2-deep FIFO: F/D
  head + skid tail) so run-ahead responses free the bus instead of
  deadlocking, branch redirect + in-flight flush. Dedicated read-only
  I-mem (no contention with the LSU).
- **Decode** — expand-then-decode-uniformly: RVC (C) instructions are
  expanded to their 32-bit RV32I equivalents, then one uniform decoder
  handles RV32I + M + C + Zilx indexed loads + Zicsr CSR ops. Odd-half
  (upper-half) branch targets and 32-bit instructions spanning a
  fetch-word boundary (stitched from two consecutive words) are handled.
  A stall-on-RAW interlock bubbles the D/E register one cycle when
  decode's live sources match execute's retiring writeback, so dependent
  ops re-read the regfile after the producer commits (no bypass path).
- **Execute + LSU** — ALU (base RV32I + single-cycle MUL via DSP +
  multi-cycle DIV/REM + Zilx effective address), reg-file writeback
  (ALU/PC4/load/**old-CSR**), branch resolve with fetch redirect, and a
  unified LSU FSM that launches loads/stores/Zilx and retires them on the
  read response / posted-store launch-accept. The LSU steers
  `addr[PERI_ADDR_BIT]` internally: `0` → native D-mem, `1` → the on-die
  AXI4-Lite bridge → peripheral bus. Misaligned accesses are suppressed
  (not launched, not trapped).
- **CSR file (Zicsr)** — machine-mode CSR subset (mstatus/misa/mie/
  mtvec/mscratch/mepc/mcause/mtval/mip) plus `mcycle`/`minstret`
  performance counters, with a read-modify-write in execute: CSRRW/S/C +
  immediate variants retire, `rd` <- old CSR. `misa` read-only;
  unimplemented CSRs read 0 / ignore writes. `mcycle` ticks every cycle,
  `minstret` per retired instruction (both writable via CSR RMW).

Still deferred: **traps/exceptions** (misaligned access suppressed, not
trapped; ecall/ebreak/mret/wfi/fence.i decode to `illegal=1`), **CSR
field semantics** (mstatus MIE/MPIE, mip/mie bits, mtvec MODE, mcause
codes — CSRs are plain whole-word read/write), and a **real MMIO
slave** on the peripheral bus (the board-top crossbar routes peri
addresses, but the peri slave side is tied off, so a peri access stalls
the LSU until a UART/GPIO slave is dropped in).

The CPU exposes **three** ports (Harvard): a native `imem` (fetch,
read-only), a native `dmem` (LSU data, byte-strobed), and an AXI4-Lite
master `axi_peri` for memory-mapped peripherals. The native
`mem_req_t`/`mem_rsp_t` → AXI4-Lite conversion for peripherals is done
inside the CPU by one `axi4_lite_master_bridge` (peri-only); the board
top is pure point-to-point wires — no crossbar. The LSU decodes
`addr[PERI_ADDR_BIT]` itself (`0` → D-mem at low addresses, `1` → peri at
`0x1000_0000+`).

The legacy **von-Neumann** build (`VON_NEUMANN` defined) collapses the CPU
to one `bus_axi` master: fetch+LSU share a `mem_arbiter` (LSU priority) →
the bridge, and the board top's `axi4_lite_xbar` splits mem vs peri.

## Repository layout

```
src/rtl/pkg/   rv32_pkg.sv          — types, opcodes, de_t D/E control struct
src/rtl/core/  pipeline stages + CPU top + reg file + ALU + board top
src/rtl/bus/   AXI4-Lite interface + master bridge + arbiter + crossbar
src/rtl/utils/ axi4_lite_ram.sv (AXI slave), native_ram.sv (Harvard I/D-mem)
src/phys/      pin assignment (.cst) + timing constraints (.sdc)
impl/          Gowin EDA project + synthesis/PnR Tcl + reports
sim/           Verilator functional sim + native & AXI RAM compliance tests
sim/sw/        C → imem.hex + dmem.hex flow (prebuilt rv32imac toolchain)
verible.flags  SystemVerilog formatting policy (Verible --flagfile)
Makefile       format / sim / sw targets
CLAUDE.md      detailed architecture + build guidance (read this)
```

## Quick start

### Simulate (Verilator, local)

Requires Verilator (`sudo apt-get install -y verilator`).

```
make run        # hand-crafted imem.hex/dmem.hex oracle (fetch/decode/retire logs)
make sw-run     # build the C program + run the sim loading it (Harvard)
```

Each run prints a retire/IPC/stall summary. On the Harvard build the
recursive quicksort (`make sw-run`) retires 2172 instructions in 4711
cycles -> **IPC ~0.46** (9.5% of cycles stalled), down from 5863 cycles /
IPC ~0.37 on the legacy von-Neumann build — the dedicated I-mem removes
fetch/LSU bus contention. The legacy build is selected with
`make VON_NEUMANN=1 run` (+ `+INIT=` for the single-image oracle).

See `sim/README.md` for the logs, VCD/GTKWave, the native-RAM
(`sim/native_mem_tb/`) and AXI4-Lite RAM (`sim/ram_tb/`) compliance tests,
and the RTL-vs-Spike co-sim (`make cosim` — retire-for-retire match
against the golden ISA reference).

### Synthesize / place & route (Gowin EDA, remote host)

The Gowin toolchain is **not** in this WSL env; it runs on the build host
(`gw_sh` at `/home/giacomo/gowin_ide/IDE/bin/gw_sh`). rsync the repo
there and run:

```
QT_QPA_PLATFORM=offscreen QT_OPENGL=software LIBGL_ALWAYS_SOFTWARE=1 \
  gw_sh impl/synth_check.tcl        # synthesize
QT_QPA_PLATFORM=offscreen QT_OPENGL=software LIBGL_ALWAYS_SOFTWARE=1 \
  gw_sh impl/pnr_check.tcl          # place & route -> .fs/.bin
```

`impl/synth_check.tcl` opens the `.gprj`, sets `top_module`, and runs
`syn`; read `impl/gwsynthesis/rv32imac_Zicsr_Zifencei_syn.rpt.html` for
errors/warnings (`gw_sh` prints only a banner to stdout). PnR runs via
the `impl/pnr_check.tcl` wrapper (open_project + `run pnr`, which reads
PnR options from the saved project) — the legacy `gw_sh -pnr -do <file>`
form silently no-ops in this Gowin version. See `CLAUDE.md` for the full
remote-build workflow and the Gowin CLI quirks.

## Formatting

SystemVerilog is formatted with Verible (`make format` / `format-check` /
`format-diff`) using the policy in `verible.flags`.

## Documentation

`CLAUDE.md` is the authoritative source for the architecture, per-stage
behaviour, build flow, and known limitations — read it for anything beyond
this overview.