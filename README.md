# YARV-uC: Yet Another RISC-V uController

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/giacu92/yarv-uc)

An **RV32IMAC + Zicsr + Zifencei** soft-processor core targeting a **Gowin
GW2AR-18C** FPGA (QFN88) on a Tang Nano 20k board. Hobby/learning project,
built with Claude Code assistance. Implemented and sim-verified (Verilator +
Spike co-sim) and **brought up on silicon**.

A 25 MHz MS5351M reference feeds an on-chip rPLL that drives the fabric at
**50 MHz** (`clk_core = 25 × 10/5`). Synthesis + PnR re-close at **50 MHz** on
the 64-bit fetch-rewrite design (the pre-rewrite design closed at 40.281 MHz).

## Core

In-order **3-stage pipeline — Fetch / Decode / Execute (F/D/E)** with a
**Harvard** memory system: a read-only I-mem for fetch, a byte-strobed D-mem
for the LSU, and AXI4-Lite kept only for peripherals.

- **Fetch** — 64-bit, 2-outstanding fetch over a native read-only I-mem port
  with a depth-8 (32-bit-word) instruction buffer. One 8-byte access delivers
  two 32-bit words; 2 outstanding keeps the BSRAM issuing through decode
  stalls (DIV/REM, mem-wait). The buffer head feeds decode exactly as the
  old F/D word did, so decode is unmodified. Branch redirect kills the
  buffer + the ≤2 in-flight reads (drain FSM).
- **Decode** — expand-then-decode: RVC (C) expands to 32-bit equivalents,
  then one uniform decoder handles RV32I + M + C + Zilx + Zicsr. Odd-half
  branch targets and word-spanning instructions are stitched. An
  execute→decode forward path resolves distance-1 RAW hazards (ALU /
  DIV-REM / load-use) same-cycle, zero bubble.
- **Execute + LSU** — ALU (RV32I + single-cycle MUL via DSP + multi-cycle
  DIV/REM + Zilx effective address), branch resolve with redirect, and a
  unified LSU FSM for loads/stores/Zilx. The LSU steers
  `addr[PERI_ADDR_BIT]` internally: `0` → native D-mem, `1` → AXI4-Lite
  peripheral bridge. Misaligned accesses trap (suppressed, not launched).
- **CSR file (Zicsr)** — machine-mode subset (mstatus/misa/mie/mtvec/
  mscratch/mepc/mcause/mtval/mip) plus `mcycle`/`minstret`. CSRRW/S/C
  retire with `rd ← old CSR`; field semantics enforced; a dedicated
  trap-write port writes mepc/mcause/mtval/mstatus atomically on entry.
- **Traps / exceptions / interrupts (M-mode)** — precise sync traps at
  commit: illegal (2), ecall-M (11), ebreak (3), load/store-misaligned
  (4/6), instruction access fault (1). `mret` returns; `wfi` halts until a
  pending enabled interrupt; `fence`/`fence.i` are nops. `mtvec` direct +
  vectored. Three interrupt sources — **MSIP** (`msip_peri` MMIO @0x1000_3000),
  **MTIP** (`clint_timer` @0x1000_1000+, 64-bit mtime/mtimecmp), **MEIP**
  (UART level IRQ) — behind a 1→3 peripheral mux with a DECERR terminator
  for unmapped addresses. Priority MEI > MSI > MTI. A trapping instruction
  is not retired.

The CPU exposes three ports: native `imem` (RO), native `dmem`
(byte-strobed), and AXI4-Lite `axi_peri`. Native→AXI conversion lives
inside the CPU; the board top is pure point-to-point wiring.

## Performance

| Benchmark | Result |
|---|---|
| CoreMark | **1.88 CoreMark/MHz**, IPC 0.561 (531 025 cycles/iteration, 2K, -O3) |
| Quicksort (256 words) | IPC 0.534, 29 675 retires in 55 617 cycles (print-free) |
| CoreMark co-sim | PASS — 332 803 retires matched vs Spike |
| Quicksort co-sim | PASS — 29 632 retires matched vs Spike |

CoreMark runs on **verbatim upstream EEMBC sources** (commit 1f483d5,
provenance hashed in `eembc/UPSTREAM.md`; `make verify-eembc` fails the
build on any edit). CRCs match the official 2K performance-seed values
(`list 0xe714` / `matrix 0x1fd7` / `state 0x8e3a`); a 2000-iteration run
gives `crcfinal` 0x4983. Built `-O3 -mstrict-align` (the core traps on
misalignment, no fixup). At 50 MHz a rules-valid run is `ITERATIONS`
814..6979 (≥10 s, under the 32-bit `mcycle` wrap; the minimum scales with
the clock, the wrap maximum is cycle-based).

The 64-bit/2-outstanding fetch rewrite removed the pre-rewrite fetch
bottleneck (~2.2 → ~1.8 cycles/instr); remaining IPC levers are the RVC
spanning bubble (a wider F/D), earlier branch redirect (branch target in
decode), and prediction. The LSU request register stage costs one cycle
per access; the registered CSR read is free (hides in the fetch bubble).

## Repository layout

```
src/rtl/pkg/   rv32_pkg.sv          types, opcodes, de_t D/E control struct
src/rtl/core/  pipeline stages + CPU top + reg file + ALU + trap unit + board top
src/rtl/bus/   AXI4-Lite interface + master bridge + peripheral crossbar
src/rtl/utils/ native_ram (Harvard I/D-mem), msip_peri, clint_timer,
               axi4_lite_uart (TX+RX FIFOs, level IRQ), axi4_lite_xbar_3
src/phys/      pin assignment (.cst) + timing constraints (.sdc)
impl/          Gowin EDA project + synthesis/PnR Tcl + reports
sim/           Verilator sim + RAM/UART compliance tests + Spike co-sim
sim/sw/        firmware tree: quicksort, CoreMark, isa/intr/peri oracles
verible.flags  SystemVerilog formatting policy
Makefile       format / sim / sw targets
CLAUDE.md      detailed architecture + build guidance (authoritative)
```

## Quick start

### Simulate (Verilator, local)

```
sudo apt-get install -y verilator
make run        # hand-crafted imem.hex/dmem.hex oracle
make sw-run     # build the C program + run the sim loading it
```

Each run prints a retire/IPC/stall summary. See `sim/README.md` for logs,
VCD/GTKWave, the RAM and UART compliance tests, the Spike co-sim, and the
trap/timer/WFI oracles.

### Synthesize / place & route (Gowin EDA, remote host)

The Gowin toolchain runs on the build host (`gw_sh`), not in this WSL env.
rsync the repo there and run:

```
QT_QPA_PLATFORM=offscreen QT_OPENGL=software LIBGL_ALWAYS_SOFTWARE=1 \
  gw_sh impl/synth_check.tcl        # synthesize
QT_QPA_PLATFORM=offscreen QT_OPENGL=software LIBGL_ALWAYS_SOFTWARE=1 \
  gw_sh impl/pnr_check.tcl          # place & route -> .fs/.bin
```

See `CLAUDE.md` for the full remote-build workflow and Gowin CLI quirks.

## Roadmap

Done: Harvard split, LSU + forwarding, Zicsr, M-mode traps + all three
interrupt sources, UART with FIFOs, silicon bring-up, 40 MHz closure
(pre-rewrite), CoreMark, 64-bit/2-outstanding fetch + instruction buffer,
50 MHz PnR re-closure on the fetch-rewrite design.

Remaining, in order:

1. **Cache over the in-package 8 MiB SDRAM** — write-back set-associative
   I/D cache behind the native interfaces; buys capacity (programs > 16 KiB),
   not speed.
2. **GPIO** — direction/output/input registers + interrupt.
3. **PLIC-style interrupt controller** — MEIP is one ORed level with no
   cause register; an ISR must poll with >1 external source.
4. **Illegal-CSR-access trap** — unimplemented CSRs currently read 0 / ignore
   writes silently.
5. **Vectored-mode interrupt co-sim** — direct mode only is co-simulated.
6. **RVC spanning bubble** — one cycle per 32-bit instruction straddling a
   word boundary; needs a wider F/D.
7. **Co-sim MMIO gap** — the diff stops at the first UART access (Spike has
   no UART/CLINT/MSIP slave).

Deferred by choice: S/U mode + delegation, PMP, cross-word sub-word accesses.

## Known limitations

- Machine mode only (no S/U, no medeleg/mideleg, no PMP).
- MEIP is a single ORed level (no PLIC — ISR polls for the source).
- Unimplemented CSR addrs silently read 0 / ignore writes (no illegal-CSR trap).
- `fence.i` is a nop (Harvard has no D→I write path — no self-modifying code).
- Forward path is distance-1 only (correct: in-order, ≤1 writeback/cycle).

## Formatting & docs

SystemVerilog is formatted with Verible (`make format` / `format-check` /
`format-diff`) using `verible.flags`. `CLAUDE.md` is the authoritative
architecture/build reference — read it for anything beyond this overview.