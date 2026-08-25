# YARV-uC: Yet Another RISC-V uController

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/giacu92/yarv-uc)

Disclaimer: This project is created by me with the assistance of Claude Code
(Anthropic). I used AI mostly to help me code and verify the core.

> **Status: work in progress.** This is a hobby/learning core, not a
> production soft-IP. The pipeline, memory system, Zicsr + Zifencei, and
> machine-mode trap/exception/interrupt machinery are implemented and
> sim-verified (Verilator + Spike co-sim). All three machine interrupt
> sources are now wired — MSIP, MTIP (CLINT timer), and MEIP (UART IRQ)
> — behind a 1→3 peripheral mux with a DECERR terminator for unmapped
> addresses; see **Roadmap** below for what is still missing. Synthesis
> + PnR are re-confirmed on the build host (2026-08-24, **post-forwarding,
> with the UART + `axi4_lite_xbar_3` in the build**; the UART TX/RX FIFOs
> added 2026-08-25 are *not* in that run, so their Fmax impact is
> unverified):
> the **active build is the 25 MHz PLL-bypass** (`clk_core = clk_i`,
> rPLL removed — the chosen operating point), with a verified-closing
> **35 MHz** rPLL retarget option (knife-edge, +0.040 ns slack) — see
> the timing note in **Status** below. The execute→decode forward path
> is **committed and timing-re-verified** (cosim still PASS; 35 MHz
> closes).

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
  An execute→decode forward path (fwd_rs1/fwd_rs2) injects execute's
  retiring writeback value into the D/E operands when it matches a
  decoded source reg, so distance-1 RAW hazards (ALU / DIV-REM /
  load-use) resolve same-cycle with zero bubbles (bypass, no stall
  interlock). Distance-2+ hazards read the regfile after the write
  committed.
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
  `msip_peri` AXI4-Lite MMIO slave at peri `0x1000_3000` (write
  bit[0] sets/clears mip.MSIP); a machine **timer interrupt**
  (mcause=0x8000_0007) is sourced by a `clint_timer` AXI4-Lite MMIO slave
  at peri `0x1000_1000+` (64-bit free-running `mtime` + 64-bit `mtimecmp`;
  `mtime >= mtimecmp` → `mtip` → `mip.MTIP`, cleared by writing
  `mtimecmp > mtime`). A machine **external interrupt**
  (mcause=0x8000_000B) is sourced today by the UART's level IRQ
  (`uart_irq` → `meip_i` → `mip.MEIP`; MEIP is a single ORed level with
  no cause register, so the ISR must poll to find the source). All three
  sit behind an `axi4_lite_xbar_3` 1→3 peri mux (`UART_BASE` 0x1000_0000
  / `MTIMER_BASE` 0x1000_1000 / `MSIP_PERI_ADDR` 0x1000_3000, all defined
  once in `rv32_pkg`); an unmapped peri address is terminated by a local
  **DECERR** (SLVERR) so the LSU never parks on a missing slave. Priority
  is MEI > MSI > MTI. Interrupts are taken at a retire boundary (the
  suppressed instr re-runs after `mret`) or on a WFI wake
  (`mepc` = wfi+4); the WFI halt clears on a *pending* enabled interrupt,
  not on `take_interrupt`, so a sync trap in the instruction behind `wfi`
  can no longer freeze the pipe. A combinational `trap_unit` (peer of
  execute) resolves entry / `mret` / interrupt redirect and drives the
  CSR trap-write bundle.

Still deferred: **S/U mode** + delegation (machine mode only, no
medeleg/mideleg, no PMP), **instruction-access-fault** /
instruction-address-misaligned traps, an **illegal-CSR-access** trap
(unimplemented CSR addrs still silently read 0 / ignore writes), and a
**PLIC-style interrupt controller** (MEIP is a single ORed level with no
cause register — the ISR must poll). `fence.i` is a nop (Harvard has no
D->I write path — self-modifying code unsupported). Synth + PnR of the
trap + timer path are **re-confirmed** on the build host (2026-08-24,
**post-forwarding, with the UART + `axi4_lite_xbar_3` in the build**):
the 64-bit timer compare (two-stage pipelined) + trap redirect mux
exposed the route-dominated CSR-address fan-out critical path at
~37 MHz actual (pre-forwarding), so the target was lowered 50 → 40 →
**35 MHz** (rPLL `IDIV_SEL=4`/`FBDIV_SEL=6`/`ODIV_SEL=16`, VCO 560 MHz).
PnR closes 35 MHz at **35.049 MHz Actual Fmax, worst setup slack
+0.040 ns, TNS 0** — a **knife-edge** closure (~40 ps margin; may not
repeat run-to-run), slightly better than the pre-forwarding
35.004/+0.004. The critical path shifted post-forwarding to the
**regfile async read → decode forward mux** (the bypass fanning into
the D/E operands, 17 logic levels), so the bypass — not the CSR fan-out
— is now the limiter. The **active build is the 25 MHz PLL-bypass**
(`clk_core = clk_i` direct, rPLL removed, +2.248 ns slack — the chosen
operating point); the 35 MHz rPLL config above is the verified-closing
retarget option (restore the rPLL instance + SDC generated clock +
`global_freq 35.000` to switch). The execute→decode forward path is
**committed and timing-re-verified** (cosim still PASS; 35 MHz closes).
To reclaim a safe 40 MHz, the async CSR read must be pipelined into a
registered 1-cycle read and/or the forward mux registered (invasive
Zicsr / decode-latency change, deferred).

## Roadmap (what is next)

The peripheral/interrupt story is the current active front. **MSIP**
(machine software interrupt, `msip_peri` → `mip.MSIP`), **MTIP**
(machine timer interrupt, `clint_timer` → `mip.MTIP`), and **MEIP**
(machine external interrupt, UART level IRQ → `meip_i` → `mip.MEIP`) are
all wired, behind a 1→3 peri mux (`axi4_lite_xbar_3`, base+size windows
from `rv32_pkg`; unmapped → DECERR). The remaining work, in order:

1. **UART — wired + synthesized, hardware bring-up in progress.** The
   UART (`axi4_lite_uart.sv`, TXDATA/RXDATA/STATUS/CTRL/BAUDDIV MMIO at
   `UART_BASE` 0x1000_0000, 8N1, **16-byte TX and RX FIFOs**, level IRQ →
   MEIP, `rxd_i` double-flopped off the async pin) is wired into
   `top_module.sv` and `sim_top.sv`, **added to the `.gprj`** with
   `axi4_lite_xbar_3.sv`, and **has pin assignments in `.cst`**
   (`uart_txd_o` PIN69, `uart_rxd_i` PIN70, the onboard BL616 USB-UART
   bridge) — synthesized + PnR'd 2026-08-24, *before* the FIFOs, so Fmax
   needs re-confirming. `BAUDDIV` is a programmable RW register (reset
   from `CLK_FREQ_HZ/BAUD_RATE`, reprogrammable at runtime, applied only
   when TX+RX are idle so an in-flight frame is never corrupted).

   The FIFOs were added on 2026-08-25 during board bring-up. With a
   single-byte RX buffer, a full-duplex echo program loses input: echoing
   a byte with a blocking "poll TX_READY, write TXDATA" costs a whole
   frame time (87 µs at 115200), and a terminal that ships a typed line
   in one burst delivers the next byte 87 µs later — so every byte
   arriving during the echo was dropped and the command line reached the
   program empty. On hardware YarvMon looked like it ignored every
   command. Reproduced in simulation (`UART_RX_PACED=0`), fixed by the
   FIFOs, guarded by `sim/hw/uart_tb` (144 checks) and the new
   `sim/sw_uart_echo` oracle.
2. **GPIO.** Direction / output / input registers, per-pin or global
   interrupt. Same MMIO/AXI4-Lite slave template as UART/MSIP.
3. **Simple PLIC-style interrupt controller.** MEIP is a single ORed
   level with no cause register, so with >1 external source the ISR must
   poll to find the source. Revisit once 2+ independent external IRQ
   sources exist (UART + GPIO).

Done (for reference): CLINT-style timer (`clint_timer.sv` — 64-bit
`mtime`/`mtimecmp`, two-stage pipelined `mtime >= mtimecmp` compare →
`mtip` → `mip.MTIP`), the `msip_peri` MMIO slave, the UART MMIO slave
wired as the MEIP source, and the peri-bus 1→3 address-decode mux with
DECERR terminator. All sim-verified (standalone timer oracle
`sim/sw_timer`, MSIP/trap oracle `sim/sw_trap`, WFI-wake arbitration
oracle `sim/sw_wfi_trap`, Spike cosim of an illegal-instruction trap
`sim/cosim/ecall`).

The sim harness now drives the UART in both directions: it types real
8N1 frames into `uart_rxd_i` (double-flopped as on the board) and
captures every transmitted byte, and `sim/sw_uart_echo` verifies MEIP end
to end — `uart_irq_o` → `meip_i` → `mip.MEIP` → `trap_unit` → interrupt
entry, including the `wfi` wake on an external interrupt.

Also still open: a vectored-mode
interrupt co-sim (direct mode is covered), and a safe 40 MHz re-target
(needs the async CSR read pipelined — see the timing note above). S/U
mode, delegation, PMP, instruction-access-fault, and illegal-CSR-access
traps remain deferred.

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
               axi4_lite_uart.sv (UART MMIO slave — 8N1, TX+RX FIFOs, level IRQ -> mip.MEIP),
               axi4_lite_xbar_3.sv (1->3 peri mux, UART/timer/MSIP + DECERR)
src/phys/      pin assignment (.cst) + timing constraints (.sdc)
impl/          Gowin EDA project + synthesis/PnR Tcl + reports
sim/           Verilator functional sim + native/AXI RAM + UART compliance tests
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
against the golden ISA reference), the trap + timer + WFI-wake oracles
(`sim/sw_trap/`, `sim/sw_timer/`, `sim/sw_wfi_trap/`), and the
illegal-trap cosim (`sim/cosim/ecall/`).

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