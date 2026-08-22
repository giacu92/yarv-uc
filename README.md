# YARV-uC: Yet Another RISC-V uController

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/giacu92/yarv-uc)

Disclaimer: This project is created by me with the assistance of Claude Code
(Anthropic). I used AI mostly to help me code and verify the core.

> **Status: work in progress.** This is a hobby/learning core, not a
> production soft-IP. The pipeline, memory system, Zicsr + Zifencei, and
> machine-mode trap/exception/interrupt machinery are implemented and
> sim-verified (Verilator + Spike co-sim), but several peripherals and
> interrupt sources are still missing — see **Roadmap** below. Synthesis
> + PnR of the most recent (trap) changes have not been re-confirmed on
> the build host yet.

An RV32IMAC + Zicsr + Zifencei RISC-V processor core targeting a **Gowin
GW2AR-18C** FPGA (`GW2AR-LV18QN88C8/I7`, QFN88) on a Tang Nano 20k-based
board. The board is clocked by a 25 MHz single-ended reference from an
MS5351M clock generator (CLK0 on PIN10, LVCMOS33); an on-chip rPLL
multiplies it up to a 40 MHz `clk_core` that drives the whole fabric.

The core is an **in-order, 3-stage pipeline — Fetch / Decode / Execute
(F/D/E)** — with a **Harvard** memory system: a dedicated
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
  bit[0] sets/clears mip.MSIP); taken at a retire boundary or on a WFI
  wake. A combinational `trap_unit` (peer of execute) resolves entry /
  `mret` / interrupt redirect and drives the CSR trap-write bundle.

Still deferred: **S/U mode** + delegation (machine mode only, no
medeleg/mideleg, no PMP), **instruction-access-fault** /
instruction-address-misaligned traps, and **timer / external
interrupts** (`mtime` / mip.MTIP, mip.MEIP — only the MSIP software
interrupt is wired so far; `mip.MTIP`/`MEIP` hardwired 0). `fence.i` is
a nop (Harvard has no D->I write path — self-modifying code unsupported).
Synth + PnR of the trap path are **not yet re-confirmed** — the last
confirmed closure (pre-trap) was Harvard clean + 40 MHz PnR; rerun
`synth_check.tcl` + `pnr_check.tcl` on the build host once it is back.

## Roadmap (what is next)

The peripheral/interrupt story is the current active front. Only the
**MSIP** software interrupt (`msip_peri`, MMIO bit[0] → `mip.MSIP`) is
wired today; `mip.MTIP`/`MEIP` are hardwired 0 and the peri bus has a
single slave. The planned work, in order:

1. **CLINT-style timer (`mtime`/`mtimecmp` → MTIP).** A 64-bit `mtime`
   + 64-bit `mtimecmp` exposed as two 32-bit MMIO register pairs.
   Atomic 64-bit reads on RV32 use the standard software pattern (read
   high, read low, re-read high, retry on rollover — no special hardware
   needed). The `mtime >= mtimecmp` compare is done inside the peripheral,
   which outputs a single level bit into `csr_regfile.sv` the same way
   `msip_o` already drives `mip[3]`. Reuses `msip_peri.sv`'s AXI4-Lite
   slave skeleton as a base.
2. **Multi-slave address-decode mux on the peri bus.** `axi_bus_peri`
   currently has only `msip_peri` as a slave and accepts any address
   unconditionally. A small 1→N AXI4-Lite mux inside the peri domain
   (same pattern as the existing 1→2 `axi4_lite_xbar` for the mem/peri
   split, just one level down) is needed before a second slave can land.
   This is the actual blocker for UART / timer / GPIO coexistence.
3. **Wire the UART in.** An AXI4-Lite UART slave (`axi4_lite_uart.sv`)
   already exists — 8N1, single-buffer TX/RX, a 5-register MMIO map
   (TXDATA/RXDATA/STATUS/CTRL/BAUDDIV), level-sensitive interrupt. It is
   not yet wired into `top_module.sv` (blocked on item 2) and not yet
   simulated or synthesized.
4. **GPIO.** Direction / output / input registers, per-pin or global
   interrupt. Same MMIO/AXI4-Lite slave template as UART/MSIP.
5. **Simple PLIC-style interrupt controller.** Deprioritized: with only
   MSIP + (future) MTIP + UART, direct `mie`/`mip` routing is still
   manageable without an arbiter. Revisit once 3+ independent IRQ
   sources exist (UART + GPIO + timer).

Also still open: timer/external interrupts (covered by item 1 + future
MEIP source), a vectored-mode interrupt co-sim (direct mode is covered),
and re-confirming 40 MHz synth + PnR closure with the trap path on the
build host. S/U mode, delegation, PMP, and instruction-access-fault traps
remain deferred.

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
src/rtl/core/  pipeline stages + CPU top + reg file + ALU + trap unit + board top
src/rtl/bus/   AXI4-Lite interface + master bridge + arbiter + crossbar
src/rtl/utils/ axi4_lite_ram.sv (AXI slave), native_ram.sv (Harvard I/D-mem),
               msip_peri.sv (MSIP MMIO slave — machine software interrupt),
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
cycles -> **IPC ~0.46** (9.5% of cycles stalled), down from 5863 cycles /
IPC ~0.37 on the legacy von-Neumann build — the dedicated I-mem removes
fetch/LSU bus contention. The legacy build is selected with
`make VON_NEUMANN=1 run` (+ `+INIT=` for the single-image oracle).

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