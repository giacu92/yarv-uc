# YARV-uC: Yet Another RISC-V uController

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/giacu92/yarv-uc)

Disclaimer: This project is created by me with the assistance of Claude Code
(Anthropic). I used AI mostly to help me code and verify the core.

> **Status: work in progress.** This is a hobby/learning core, not a
> production soft-IP. The pipeline, memory system, Zicsr + Zifencei, and
> machine-mode trap/exception/interrupt machinery are implemented and
> sim-verified (Verilator + Spike co-sim), but several peripherals and
> interrupt sources are still missing — see **Roadmap** below. Synthesis
> + PnR are re-confirmed on the build host (2026-08-22): the core closes
> **35 MHz** (knife-edge, +0.004 ns slack) with a comfortable **25 MHz**
> PLL-bypass fallback — see the timing note in **Status** below.

An RV32IMAC + Zicsr + Zifencei RISC-V processor core targeting a **Gowin
GW2AR-18C** FPGA (`GW2AR-LV18QN88C8/I7`, QFN88) on a Tang Nano 20k-based
board. The board is clocked by a 25 MHz single-ended reference from an
MS5351M clock generator (CLK0 on PIN10, LVCMOS33); an on-chip rPLL
multiplies it up to a 35 MHz `clk_core` that drives the whole fabric.

The core is an **in-order, 3-stage pipeline — Fetch / Decode / Execute
(F/D/E)** — with a **Harvard** memory system: a dedicated
read-only I-mem for fetch and a byte-strobed D-mem for the LSU, with AXI
kept only for peripherals. Implemented so far:

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
  AXI4-Lite bridge → peripheral bus. Misaligned accesses raise a
  load/store-address-misaligned trap (suppressed, not launched).
- **CSR file (Zicsr)** — machine-mode CSR subset (mstatus/misa/mie/
  mtvec/mscratch/mepc/mcause/mtval/mip) plus `mcycle`/`minstret`
  performance counters, with a read-modify-write in execute: CSRRW/S/C +
  immediate variants retire, `rd` <- old CSR. `misa` read-only;
  unimplemented CSRs read 0 / ignore writes. `mcycle` ticks every cycle,
  `minstret` per retired instruction (both writable via CSR RMW). CSR
  **field semantics** are enforced (mstatus MIE/MPIE/MPP on trap
  entry/`mret`, mip.MSIP/MTIP/MEIP hardwiring, mtvec MODE masking);
  the file has a dedicated trap-write port bundle (mepc/mcause/mtval/
  mstatus) so a trap entry can atomically write four CSRs in one cycle
  alongside the single RMW port.
- **Traps / exceptions / interrupts (machine mode)** — precise
  synchronous traps taken at the execute commit point: illegal
  instruction (mcause=2, mtval=instr), ecall-M (11), ebreak (3),
  load/store-address-misaligned (4/6, mtval=bad EA). `mret` returns
  (mstatus MIE<-MPIE, MPIE<-1); `wfi` halts until a pending enabled
  interrupt; `fence`/`fence.i` are nops. `mtvec` direct + vectored
  modes; mepc/mcause/mtval written on entry. A trapping instruction is
  **not** retired (matches the RISC-V spec + Spike). A machine
  **software interrupt** (mcause=0x8000_0003) is injected by an
  `msip_peri` AXI4-Lite MMIO slave at peri base `0x1000_0000` (write
  bit[0] sets/clears mip.MSIP); a machine **timer interrupt**
  (mcause=0x8000_0007) is sourced by a `clint_timer` AXI4-Lite MMIO slave
  at peri `0x1000_1000+` (64-bit free-running `mtime` + 64-bit `mtimecmp`;
  `mtime >= mtimecmp` → `mtip` → `mip.MTIP`, cleared by writing
  `mtimecmp > mtime`). Both sit behind a reused `axi4_lite_xbar` 1→2
  peri mux (`addr[12]`: MSIP vs timer). Interrupts are taken at a retire
  boundary (the suppressed instr re-runs after `mret`) or on a WFI wake
  (`mepc` = wfi+4). `int_cause` selects MSI > MTI priority (MEI not
  wired). A combinational `trap_unit` (peer of execute) resolves entry /
  `mret` / interrupt redirect and drives the CSR trap-write bundle.

Still deferred: **S/U mode** + delegation (machine mode only, no
medeleg/mideleg, no PMP), **instruction-access-fault** /
instruction-address-misaligned traps, and the **external interrupt**
(`mip.MEIP` — MSIP and MTIP are wired; MEIP has no source yet).
`fence.i` is a nop (Harvard has no D->I write path — self-modifying code
unsupported). Synth + PnR of the trap + timer path are **re-confirmed**
on the build host (2026-08-22): the 64-bit timer compare (two-stage
pipelined) + trap redirect mux exposed the route-dominated CSR-address
fan-out critical path at ~37 MHz actual, so the target was lowered
50 → 40 → **35 MHz** (rPLL `IDIV_SEL=4`/`FBDIV_SEL=6`/`ODIV_SEL=16`,
VCO 560 MHz). PnR closes 35 MHz at 35.004 MHz Actual Fmax, worst setup
slack +0.004 ns, TNS 0 — a **knife-edge** closure (essentially zero
margin; may not repeat run-to-run). The comfortable fallback is the
**25 MHz PLL-bypass** (`clk_core = clk_i` direct, +2.248 ns slack). To
reclaim a safe 40 MHz, the async CSR read must be pipelined into a
registered 1-cycle read (an invasive Zicsr read-latency change, deferred).

## Roadmap (what is next)

The peripheral/interrupt story is the current active front. **MSIP**
(machine software interrupt, `msip_peri` → `mip.MSIP`) and **MTIP**
(machine timer interrupt, `clint_timer` → `mip.MTIP`) are both wired,
behind a 1→2 peri mux (`axi4_lite_xbar`, `addr[12]` decode). `mip.MEIP`
still has no source. The remaining work, in order:

1. **Wire the UART in.** An AXI4-Lite UART slave (`axi4_lite_uart.sv`)
   already exists — 8N1, single-buffer TX/RX, a 5-register MMIO map
   (TXDATA/RXDATA/STATUS/CTRL/BAUDDIV), level-sensitive interrupt. It is
   not yet wired into `top_module.sv` and not yet simulated or
   synthesized. Needs a generalized 1→N peri mux (the current 1→2 covers
   MSIP + timer; a 3rd slave needs the wider mux).
2. **GPIO.** Direction / output / input registers, per-pin or global
   interrupt. Same MMIO/AXI4-Lite slave template as UART/MSIP.
3. **Simple PLIC-style interrupt controller.** Deprioritized: with only
   MSIP + MTIP + UART, direct `mie`/`mip` routing is still manageable
   without an arbiter. Revisit once 3+ independent IRQ sources exist
   (UART + GPIO + timer).

Done (for reference): CLINT-style timer (`clint_timer.sv` — 64-bit
`mtime`/`mtimecmp`, two-stage pipelined `mtime >= mtimecmp` compare →
`mtip` → `mip.MTIP`) and the peri-bus 1→2 address-decode mux (reused
`axi4_lite_xbar`, `addr[12]`: MSIP vs timer). Both sim-verified (standalone
timer oracle `sim/sw_timer`, MSIP/trap oracle `sim/sw_trap`, Spike cosim
of an illegal-instruction trap `sim/cosim/ecall`).

Also still open: the external interrupt (MEIP source — UART IRQ will be
the first), a vectored-mode interrupt co-sim (direct mode is covered),
and a safe 40 MHz re-target (needs the async CSR read pipelined — see
the timing note above). S/U mode, delegation, PMP, and
instruction-access-fault traps remain deferred.

The CPU exposes **three** ports (Harvard): a native `imem` (fetch,
read-only), a native `dmem` (LSU data, byte-strobed), and an AXI4-Lite
master `axi_peri` for memory-mapped peripherals. The native
`mem_req_t`/`mem_rsp_t` → AXI4-Lite conversion for peripherals is done
inside the CPU by one `axi4_lite_master_bridge` (peri-only); the board
top is pure point-to-point wires — no crossbar. The LSU decodes
`addr[PERI_ADDR_BIT]` itself (`0` → D-mem at low addresses, `1` → peri at
`0x1000_0000+`).

## Repository layout

```
src/rtl/pkg/   rv32_pkg.sv          — types, opcodes, de_t D/E control struct
src/rtl/core/  pipeline stages + CPU top + reg file + ALU + trap unit + board top
src/rtl/bus/   AXI4-Lite interface + master bridge + crossbar (peri mux)
src/rtl/utils/ native_ram.sv (Harvard I/D-mem), axi4_lite_ram.sv (AXI slave, sim),
               msip_peri.sv (MSIP MMIO slave — machine software interrupt),
               clint_timer.sv (CLINT timer MMIO slave — machine timer interrupt),
               axi4_lite_uart.sv (UART MMIO slave — exists, not yet wired in)
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
cycles -> **IPC ~0.46** (9.5% of cycles stalled); the dedicated I-mem
removes fetch/LSU bus contention (the dropped legacy von-Neumann build
was 5863 cycles / IPC ~0.37).

See `sim/README.md` for the logs, VCD/GTKWave, the native-RAM
(`sim/hw/native_mem_tb/`) and AXI4-Lite RAM (`sim/hw/ram_tb/`) compliance
tests, the RTL-vs-Spike co-sim (`make cosim` — retire-for-retire match
against the golden ISA reference), and the trap oracle + illegal-trap
cosim (`sim/sw_trap/`, `sim/cosim/ecall/`).

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