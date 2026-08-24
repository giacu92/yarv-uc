# CLAUDE.md

Guidance for Claude Code in this repo.

## Project

RV32IMAC + Zicsr + Zifencei RISC-V core for a **Gowin GW2AR-18C** FPGA (QFN88) on a Tang Nano 20k. Clock: 25 MHz single-ended from an MS5351M generator (CLK0, PIN10, LVCMOS33) — not the stock 27 MHz oscillator. On-chip rPLL multiplies to `clk_core = 35 MHz` (25×7/5, VCO 560 MHz). Closure is knife-edge (+0.004 ns slack); fallback is **25 MHz PLL-bypass** (`clk_core = clk_i`).

**Status:** fetch/decode/execute + LSU + Zicsr + trap/exception/interrupt implemented. **Harvard** memory system — dedicated read-only I-mem for fetch, native byte-strobed D-mem for LSU, AXI4-Lite only for peripherals. Loads/stores/Zilx/CSR ops retire via native D-mem (or peri bridge) with an **execute→decode forward path** (distance-1 RAW resolved same-cycle, zero bubble; no stall-on-RAW interlock).

**Machine-mode traps:** precise sync traps at execute commit — illegal instr (mcause=2), ecall-M (11), ebreak (3), load/store addr-misaligned (4/6, mtval=bad EA); `mret` returns; `wfi`=halt-until-pending-interrupt; `fence`/`fence.i`=nop. `mtvec` direct+vectored; mepc/mcause/mtval on entry. Software interrupt (mcause=0x8000_0003) via `msip_peri` AXI4-Lite slave @0x1000_3000. Timer interrupt (mcause=0x8000_0007) via `clint_timer` (64-bit mtime/mtimecmp @0x1000_1000+). External interrupt (mcause=0x8000_000B) = OR of peripheral IRQs (UART today) → `meip_i`. Priority MEI>MSI>MTI. A trapping instruction is not retired (matches spec + Spike). Sim-verified (oracle + Spike cosim).

**Timing (2026-08-22 re-confirm, pre-forwarding):** trap+timer path does not close 40 MHz — CLINT 64-bit compare + trap redirect mux exposed route-dominated CSR-address fan-out (~37 MHz actual Fmax) as critical path. Target backed off to **35 MHz** via rPLL (IDIV_SEL=4/FBDIV_SEL=6/ODIV_SEL=16). PnR: 35.004 MHz Fmax, +0.004 ns slack, TNS 0 — essentially zero margin, may not repeat run-to-run. Fallback: **25 MHz PLL-bypass** (+2.248 ns slack; rPLL can't reach ≥500 MHz VCO at 25 MHz in, since 25×16=400<500). Fix for a safe 40 MHz later: pipeline the async CSR read into a registered 1-cycle read (deferred, invasive Zicsr change). Legacy `VON_NEUMANN` build dropped — Harvard only.

CPU exposes 3 ports: native `imem` (RO), native `dmem` (byte-strobed), AXI4-Lite master `axi_peri`. Native→AXI conversion for peripherals done inside CPU by `axi4_lite_master_bridge`; board top is pure point-to-point wiring (no crossbar). LSU decodes `addr[PERI_ADDR_BIT]` itself (0→native D-mem, 1→peri bridge→0x1000_0000+). Only non-bus CPU output: `dbg_stall_o`→LED0.

**Key files:**
- `src/rtl/core/top_module.sv` — board top
- `src/rtl/core/rv32imac_zicsr_zifencei.sv` — CPU top
- `src/rtl/core/trap_unit.sv` — exception/interrupt entry + mret
- `src/rtl/utils/native_ram.sv` — Harvard I/D-mem native slave
- `src/rtl/utils/msip_peri.sv` — AXI4-Lite MSIP MMIO slave
- `src/rtl/utils/clint_timer.sv` — AXI4-Lite CLINT timer slave (64-bit mtime/mtimecmp)
- `src/rtl/utils/axi4_lite_uart.sv` — AXI4-Lite UART slave, IRQ→mip.MEIP
- `src/rtl/bus/axi4_lite_xbar.sv` — 1→2 crossbar (unused, kept for reuse)
- `src/rtl/bus/axi4_lite_xbar_3.sv` — 1→3 peri crossbar (UART/timer/MSIP + DECERR for unmapped)
- `rv32imac_Zicsr_Zifencei.gprj` — Gowin IDE project
- `impl/rv32imac_Zicsr_Zifencei_process_config.json` — synth config
- `impl/gwsynthesis/`, `impl/pnr/` — synth/PnR outputs (PnR gitignored)

## Build flow (Gowin EDA)

IDE-only, no RTL Makefile. Toolchain on remote host `giacomo@192.168.10.36`: `gw_sh` at `/home/giacomo/gowin_ide/IDE/bin/gw_sh` (V1.9.11.03 Education). rsync repo to `~/gowin_proj/rv32imac_Zicsr_Zifencei/`. Errors/warnings in `impl/gwsynthesis/rv32imac_Zicsr_Zifencei_syn.rpt.html`.

### Synthesize
```bash
QT_QPA_PLATFORM=offscreen QT_OPENGL=software LIBGL_ALWAYS_SOFTWARE=1 gw_sh impl/synth_check.tcl
```
Gotcha: no-ops if `.vg`/report already exist — delete outputs by explicit filename first.

### Place & Route
Options in `impl/pnr/cmd.do` (GW2AR-18C, `-bit -tr -ph -timing`, `global_freq 35.000`); device opts in `impl/pnr/device.cfg`.
```bash
QT_QPA_PLATFORM=offscreen QT_OPENGL=software LIBGL_ALWAYS_SOFTWARE=1 gw_sh impl/pnr_check.tcl
```
Gotcha: `gw_sh -pnr -do ...` no-ops (invalid flag in this version) — use the Tcl wrapper. Also no-ops if outputs exist — delete by filename first. Outputs: `.fs`/`.bin`/`.binx`; timing in `.tr.html` ("Max Frequency Summary"). **SDC**: `src/phys/rv32imac_Zicsr_Zifencei.sdc` must be listed as a `<File type="file.sdc">` in the `.gprj` (not just referenced from `cmd.do`) or PnR falls back to unconstrained 100 MHz. `pnr_check.tcl` also forces `-global_freq 35.000`; the SDC's `create_generated_clock -multiply_by 7 -divide_by 5` on `clk_core` is the real constraint.

### Constraints (`src/phys/`)
`.cst`: `clk_i`→PIN10 (25MHz LVCMOS33), `rstn_i`→PIN88 (async active-low), `led_o[0]`=stall, `led_o[3:1]`=counter.
`.sdc`: `clk25`@25MHz on `clk_i`, generated clock `clk_core`@35MHz (`multiply_by 7/divide_by 5`, the rPLL CLKOUT) — this is the constraint covering the fabric. History: target went 50→40→25(bypass)→35(rPLL) MHz, forced back by the trap+timer critical path (see Status). A/B test proved the regfile primitive (BSRAM vs `registers` style) is NOT the Fmax limiter — real critical path is route-dominated (~65% route), the CSR-address fan-out. `rstn_i`/`led_o` false-path.

No lint config. Verilator sim in `sim/` (functional), `sim/hw/native_mem_tb/` (native RAM compliance), `sim/hw/ram_tb/` (AXI4-Lite compliance), `sim/cosim/quicksort/` (RTL vs Spike).

## Simulation (Verilator)

Builds fetch+decode+execute+native I/D-mem+peri bridge (Harvard only now). `--public-flat-rw` build (no per-stage debug ports).

- `sim/sim_top.sv` — wrapper preloading native I/D-mem via `$readmemh`, plusargs `+IINIT=` (default `imem.hex`) / `+DINIT=` (default `dmem.hex`). Exposes a `PROBE_LEN`-word D-mem window for VCD tracing. Wires peri bus through `axi4_lite_xbar_3`→uart+timer+msip. UART `rxd_i` tied idle-high (no RX stimulus — `uart_getc()`-blocking programs can't advance).
- `sim/sim_main.cpp` — drives clk/rst, logs fetch/decode/execute-retire+writeback via internal taps. Writes `sim/sim_top.vcd`. Stops on park detection (8 identical retires) or `MAX_CYC` (default 4000). `STAP()` prints a stall breakdown (RAW/DIV-REM/LSU-wait %). Checks the WFI-halt invariant on every run (see WFI oracle below) — prints `WFI-halt check: OK` or fails with `WFI-HALT FAIL`.
- `sim/imem.hex` + `sim/dmem.hex` — hand-crafted Harvard oracle: RAW hazards (now resolved by forwarding, not stall), LSU round-trip + load-use, byte/halfword sign/zero extend.
- `sim/program.hex` — legacy von-Neumann oracle, unused (file kept).
- `sim/Makefile` — `make run` (default oracle); `RUN_ARGS="+IINIT=... +DINIT=..."` for C programs.
- `sim/sw/` — C→two images via `riscv32-esp-elf-gcc` 14.2.0 (`-march=rv32imac -mabi=ilp32 -nostdlib -ffreestanding`, `medlow`, link script splits `.text`→IMEM ORIGIN=0 / `.data`→DMEM ORIGIN=0x2000). Default `main.c`: recursive quicksort, returns `0x600D` (pass) / `0xBAD` (fail).

```bash
cd sim && make run                    # Harvard oracle
make sw-run                           # build C prog + run (from repo root)
```
Build artefacts gitignored.

### Native RAM compliance (`sim/hw/native_mem_tb/`)
BFM master driving `native_ram` directly. Checks RVALID registered & held until RREADY, byte-strobed partial writes, back-to-back writes, single-outstanding, posted-store commit at launch-accept, read-only ignoring writes.
```bash
cd sim/hw/native_mem_tb && make run     # "N checks, 0 failures"
```

### AXI4-Lite RAM compliance (`sim/hw/ram_tb/`)
BFM master driving `axi4_lite_ram` (peri-side only in Harvard build). Checks registered BVALID held under delayed BREADY, AW/W ordering, byte strobes, back-to-back writes, single-outstanding, RVALID held under delayed RREADY.
```bash
cd sim/hw/ram_tb && make run
```

### Co-sim vs Spike (`sim/cosim/quicksort/`)
Runs the same C ELF on Spike (`--log-commits`, built via `build_spike.sh`) and Verilator RTL; `cosim_diff.py` diffs per-retire pc + register write. Harvard requires `.data` at non-zero VMA (`DMEM ORIGIN=0x2000`) so Spike's unified space holds `.text`@0/`.data`@0x2000 disjoint. `SPIKE_MEM`: `0x0:0x1000` code, `0x2000:0xE000` data+stack.
```bash
make cosim     # -> "PASS -- matched N retires"
```

### Trap oracle + illegal-trap cosim (`sim/sw_trap/`, `sim/cosim/ecall/`)
`trap_test.S` (built `-march=rv32imac_zicsr_zifencei`): standalone M-mode program exercising ecall/load-misaligned/illegal/MSIP+WFI; self-checks, writes `0x600D`/`0xBAD` at D-mem 0x2000.
```bash
cd sw_trap && make
cd .. && make run RUN_ARGS="+IINIT=sw_trap/build/imem.hex +DINIT=sw_trap/build/dmem.hex"
```
`sim/cosim/ecall/`: Spike cosim of a sync trap (illegal instr `.word 0x0000007f`), shared `cosim_diff.py`. ecall itself isn't Spike-comparable (Spike hijacks M-mode ecall as htif exit; MSIP has no Spike slave).
```bash
cd cosim/ecall && make cosim   # -> "PASS -- matched 17 retires"
```

### WFI-wake arbitration oracle (`sim/sw_wfi_trap/`)
Regression for a WFI-halt deadlock: `wfi_halt_q` must clear on `int_pending`, not `take_interrupt` (which loses priority to a sync trap) — otherwise a faulting instr behind `wfi` left the halt flag set, trap entry cleared `mstatus.MIE`, dropping `int_pending` and freezing the pipe unrecoverably. `wfi_trap_test.S` arms `mtimecmp=400`, runs a 32-cycle `div` to fill the pipe, then `wfi` + an illegal instr. On wake the illegal trap wins arbitration first (marker @0x2040), then the pending timer interrupt is taken (marker @0x2044). `gen_hex.py` hand-encodes the program (no toolchain needed).
```bash
cd sw_wfi_trap && python3 gen_hex.py
cd .. && make run RUN_ARGS="+IINIT=sw_wfi_trap/build/imem.hex +DINIT=sw_wfi_trap/build/dmem.hex"
```

### Timer oracle (`sim/sw_timer/`)
`timer_test.S`: arms `mtimecmp=200`, `wfi`s, wakes on MTIP (mcause=0x8000_0007), handler stores marker=7 @0x2040, clears MTIP (`mtimecmp=0xFFFFFFFF_FFFFFFFF`). Not Spike-comparable (no CLINT slave in Spike) — standalone oracle only.
```bash
cd sw_timer && make
cd .. && make run RUN_ARGS="+IINIT=sw_timer/build/imem.hex +DINIT=sw_timer/build/dmem.hex"
```

## Code formatting (Verible)

Policy in `verible.flags` (4-space indent, 100-col, aligned ports/params/assignments) — edit that file, not CLI overrides.
```bash
make format        # reformat in place
make format-check  # CI: exit 1 if unformatted
make format-diff
```
Not in apt; static binary on build host at `~/tools/verible` → `~/.local/bin`.

## Architecture

Built bottom-up. Every RTL file: `import rv32_pkg::*;` + `` `resetall `` / `` `default_nettype none `` / `` `timescale 1ns/1ps ``.

### Naming
Ports `_i`/`_o`. Flops `_q`, next-state comb `_d`. Instances `u_*`. Stage debug taps `fe_`/`de_`/`ex_`, internal only (`dbg_stall_o` is the sole exported one).

### Files
- **`rv32_pkg.sv`** — `XLEN=32`; `mem_req_t`/`mem_rsp_t`. `PERI_ADDR_BIT`=28; peri windows `UART_BASE/SIZE`=0x1000_0000/4K, `MTIMER_BASE/SIZE`=0x1000_1000/8K, `MSIP_PERI_ADDR/SIZE`=0x1000_3000/4K. Decode types: opcodes (incl `OPC_AMO`), `alu_op_t` (incl `ALU_LX`), `wb_src_t` (incl `WB_CSR`), `csr_op_t`/`csr_addr_t` (MSTATUS/MISA/MIE/MTVEC/MSCRATCH/MEPC/MCAUSE/MTVAL/MIP/MCYCLE/MINSTRET), `sys_op_t`, `MCAUSE_*` codes, `MSTATUS_*` bit positions/masks, `MTVEC_DIRECT/VECTORED`. Packed `de_t` D/E struct.
- **`fetch_stage.sv`** — PC + F/D reg + 1-entry skid (2-deep FIFO), single-outstanding overlap-prefetch. `stall_i` (decode) / `branch_valid_i`+`branch_addr_i` (execute redirect incl. trap/mret/interrupt).
- **`decode_stage.sv`** — RV32I+M+C+Zilx+Zicsr. Expand-then-decode (`c_expand()` RVC→32-bit, one decoder). Hold buffer for upper compressed half. Zilx (`OPC_AMO` funct5 10010/11010; 11110 illegal) swaps rs1/rs2, computes `mem_shamt`. Zicsr (`OPC_SYSTEM` funct3≠0) decodes csr_op/csr_wren/csr_addr, `wb_src=WB_CSR`. `OPC_SYSTEM` funct3=0: ecall/ebreak/mret/wfi → `sys_op` (legal). `OPC_MISC_MEM`: fence/fence.i → `sys_op` (legal nop). Unknown → `dec_illegal=1`, `MCAUSE_ILLEGAL`. `stall_o` = hold-term | execute stall | WFI-halt — **no RAW term** (forwarding resolves it). **Execute→decode forwarding**: `fwd_rs1`/`fwd_rs2` inject `ex_wb_data_i` into `de_d.rs1_data`/`rs2_data` when `ex_wb_en_i` & addr matches — distance-1 RAW zero-bubble. Legacy `raw_haz` interlock disabled.
- **`reg_file.sv`** — 32×32 BSRAM, async read×2/sync write×1, x0 hardwired. Confirmed NOT the Fmax limiter (A/B vs `registers` style, identical). No runtime reset (BSRAM single write port); sim zero-inits via `` `ifdef VERILATOR ``; HW relies on BSRAM power-up + write-before-read.
- **`csr_regfile.sv`** — 11-entry Zicsr M-mode subset. Async read (decode addr) + sync write (execute RMW). FF+LUT mux (sparse, not BSRAM). CSRs reset to architected values (`misa`=0x40002105 RO). Unimplemented addrs read 0/ignore writes. `mcycle`/`minstret` free-running. Trap-write bundle ports (priority over RMW) + `msip_i`/`mtip_i`/`meip_i` (mip bits) + comb taps `mtvec_o`/`mepc_o`/`mstatus_o`/`mip_o`/`mie_o` for the trap unit. `mstatus` RMW forces MPP=2'b11 (WARL, M-only); `mtvec` RMW masks MODE.
- **`alu.sv`** — combinational RV32I + single-cycle MUL (DSP) + multi-cycle DIV/REM (32-iter restoring FSM) + Zilx EA (`a + (b<<shamt)`).
- **`trap_unit.sv`** — combinational exception/interrupt entry + mret, peer of execute at CPU top. Consumes CSR taps + execute triggers (sync_trap/mret/take_interrupt, cause/tval/pc); produces fetch redirect (mtvec BASE, BASE+4*code vectored, or mepc for mret) + CSR trap-write bundle. `int_pending_o = mstatus.MIE & (MSIP&MSIE | MTIP&MTIE)`; `int_cause_o` selects MSI>MTI (MEI not wired here). mstatus: entry MPIE←MIE/MIE←0/MPP←00; mret MIE←MPIE/MPIE←1/MPP←00.
- **`execute_stage.sv`** — selects operands, drives DIV/REM + LSU via unified FSM (`EX_IDLE`/`EX_DIV_BUSY`/`EX_MEM_WAIT`), writes back ALU/PC4/load/old-CSR, resolves branches+redirect, drives native LSU, CSR RMW. **Posted store**: retires on launch-accept, commits same edge. Loads wait in `EX_MEM_WAIT` until `rvalid`. LSU steers `addr[PERI_ADDR_BIT]`. CSR: `csr_new`=RW:src / RS:`old|src` / RC:`old&~src`. Load alignment: shift by `addr[1:0]`, sign/zero-extend. **Trap machinery**: `freeze = stall_i | wfi_stall`; sync traps fire in `EX_IDLE` (never launch on misaligned) — `sync_trap_req` exports to trap unit, normal wb/mem/csr/branch suppressed; `mret` retires + redirects to mepc; `take_interrupt` suppresses next instr at retire boundary or on WFI wake (mepc=wfi+size); WFI retires once then halts until `int_pending`. Trapping instr not retired (matches spec+Spike). Exports `ex_wb_en_o`/`ex_wb_addr_o`/`ex_wb_data_o` to decode same-cycle, feeding the forward path.
- **`rv32imac_zicsr_zifencei.sv`** — CPU top: fetch+reg_file+csr_regfile+decode+execute+trap_unit. 3 ports (native imem/dmem + AXI4-Lite `axi_peri`; peri bridge lives inside CPU). Plus `msip_i`/`mtip_i`. `trap_unit` combinational peer of execute. Only non-bus output: `dbg_stall_o`.
- **`top_module.sv`** — board top. `clk_core=35 MHz` via on-chip rPLL (single clock domain, no CDC); reset sync gated on `pll_lock`. Fallback: drop rPLL, `clk_core=clk_i=25 MHz`. Harvard: native `u_imem`(RO)/`u_dmem` on CPU ports; `axi_bus_peri`→`axi4_lite_xbar_3`→UART+timer+MSIP; their irq/mtip/msip feed CPU inputs. `CLK_CORE_HZ=35_000_000` feeds UART's `CLK_FREQ_HZ` (must track PLL). `uart_rxd_i` double-flopped before the UART (async pin, single fabric domain). `led_o[0]`=stall, `led_o[3:1]`=counter.
- **`native_ram.sv`** — Harvard native slave, `READ_ONLY` param. Mirrors `axi4_lite_ram` handshake (`wready` gating, RVALID held until RREADY, `bvalid=0`, no addr latch — read-launch latches `rdata_q` at accept).
- **`msip_peri.sv`** — AXI4-Lite MMIO, 1-bit MSIP reg @`MSIP_PERI_ADDR`. Write bit[0] sets/clears mip.MSIP. Protocol mirrors `axi4_lite_ram`.
- **`clint_timer.sv`** — AXI4-Lite CLINT (`MTIMER_BASE`, 8 KiB). 64-bit free-running `mtime` (RO) + 64-bit `mtimecmp` (RW, resets all-ones), 4×32-bit words (lo/hi @ +0/+4, +8/+0xC). `mtip_o = mtime>=mtimecmp`. **Two-stage pipelined compare** (stage-1: parallel `ge_hi`/`eq_hi`/`ge_lo`; stage-2: `ge_hi | (eq_hi & ge_lo)`) to cut the 64-bit carry chain off the timing path — `mtip_o` delayed 2 cycles (harmless, level IRQ). Software must arm `mtimecmp` hi=all-ones → lo → real hi (else spurious MTIP in the gap). `mtime` writes ignored.
- **`axi4_lite_master_bridge.sv`** — `mem_req_t`/`mem_rsp_t`↔AXI4-Lite, single FSM, single outstanding. `bvalid` on B handshake. Peri-only now (inside CPU).
- **`axi4_lite_xbar.sv`** — 1→2 crossbar by `addr[SEL_BIT]` (default 28). Unused now, kept for reuse.
- **`axi4_lite_xbar_3.sv`** — 1→3 crossbar, 3 compile-time BASE/SIZE windows. Unmapped peri address → local **DECERR terminator** (was previously left with ready low, parking the LSU forever).
- **`mem_arbiter.sv`** — deleted (was fetch/LSU arbiter for dropped VON_NEUMANN build).
- **`axi4_lite_ram.sv`** — AXI4-Lite slave, single-beat, protocol-compliant (`ram_tb`). BVALID registered & held until B handshake. Single-outstanding, byte-strobed via BSRAM byte enables. Von-Neumann mem slave / Harvard peri-side (kept, reusable).

### Fetch behaviour
2-deep FIFO (F/D head + 1-entry skid). Issues only when FIFO has room; accepts responses whenever there's room (lands in skid if F/D full). Harvard: fetch owns the I-mem port uncontended — skid just overlaps F/D-head-stalls. ~2 cyc/instr steady state (single-outstanding). Skid gave 15-20% cycle-count improvement over no-skid (measured on oracle+Zilx quicksort). Redirect kills F/D+skid, sets new `pc_q`. Compressed: fetch always reads 32-bit words; decode handles expansion/odd-half alignment.

### Decode behaviour
Source priority: spanning stitch > compressed hold > odd-half target > fresh low half. RVC spanning (32-bit instr split across word boundary) handled: low half stashed, stitched with next word's upper half (1 bubble, `span_wait`). `decoded_valid` excludes wait states. Deferred/traps in execute: unknown opcode (`MCAUSE_ILLEGAL`), `OPC_AMO` funct5 11110/sfence.vma (no VM). Legal (decode to `sys_op`, retire in execute): ecall/ebreak/mret/wfi/fence/fence.i. Zicsr decodes and retires fully.

### Hazard resolution (execute→decode forwarding)
`fwd_rs1`/`fwd_rs2` fire when execute retires a writeback to a register the decoding instr reads (x0 excluded): inject `ex_wb_data_i` into D/E operands instead of the stale async regfile read — zero bubble. Covers ALU-RAW, div-done-then-use, branch-on-dependent, load-use (the load's `EX_MEM_WAIT` holds the consumer in decode via `stall_i`; the load's `wb_en` pulse on `rvalid` drives the forward). Distance-2+ hazards: harmless, regfile async read returns the already-committed value. Legacy `raw_haz` bubble interlock **disabled**.

**Known limitations:**
- Forward path is distance-1 only (single in-order retire slot); correct because execute retires ≤1 writeback/cycle in order.
- M-mode only (no S/U, no medeleg/mideleg, no PMP). No instruction-access-fault/instruction-address-misaligned traps. Cross-word sub-word accesses unhandled. Timer + external interrupt sourced; MEIP is a single ORed level (only UART today, no PLIC — ISR must poll to find source). Unimplemented CSR addrs still silently read 0/ignore writes (no illegal-instruction trap).
- WFI halts forever if no enabled interrupt ever arrives (legal). `fence.i`/`fence` are nops (Harvard has no D→I write path — no self-modifying code).
- Harvard: I-mem holds `.text`/`.text.init` only; `.rodata`/`.data`/`.bss`/stack live in D-mem. `.data` linked at DMEM ORIGIN 0x2000 (not 0) so Spike co-sim can hold `.text`@0/`.data`@0x2000 disjoint. Requires `medlow` absolute addressing.

### Open work
- Harvard split done. Perf: quicksort 4711 cyc / IPC~0.46 / 9.5% stall (Harvard) vs 5863/0.37/16% (von-Neumann) — −16% cycles. Cosim vs Spike passes (2165 matched retires).
- **Forward path (bypass)** committed (`8cae7e2`); cosim unchanged (quicksort 2165 matched, ecall 17 matched). **Synth/PnR NOT yet re-run with forwarding** — 2026-08-22 re-confirm predates it; must re-verify 35 MHz closure on the build host before committing (forwarding fans into the same route-dominated CSR-fan-out path).
- I-mem `INIT_FILE` must point at real firmware for meaningful synthesis (empty init folds the pipeline to dead code). `top_module.sv` `u_imem` currently loads `sim/imem.hex` (oracle) for bring-up.
- LSU done (loads/stores/Zilx via native D-mem+peri bridge; load-use covered by forwarding; posted store both paths).
- **Peripherals/interrupts — active front.** All 3 interrupt sources wired: MSIP, MTIP (CLINT), MEIP (UART). Done: CLINT timer, `axi4_lite_xbar_3` peri mux w/ DECERR, UART wired into `top_module`/`sim_top` w/ double-flopped `rxd_i`. Remaining, in order: (4) add UART to `.gprj` + assign pins in `.cst` (currently sim/RTL only, not in Gowin project); (5) GPIO (dir/out/in, IRQ, same MMIO template); (6) PLIC-style interrupt controller (MEIP has no cause register — ISR must poll); (7) RX stimulus in sim harness (`rxd_i` tied idle-high — blocks `uart_getc()`-based tests).
- **Trap/exception/interrupt machinery done** (M-mode): sync traps, mret, wfi, fence/fence.i nops, mstatus semantics, mtvec direct+vectored, MSIP+MTIP sources, MEI>MSI>MTI priority. Verified: `sw_trap` oracle, `sw_timer` oracle, Spike cosim of illegal-trap (`cosim/ecall`, PASS 17 matched — ecall itself not Spike-comparable), `sw_wfi_trap` arbitration oracle (toolchain-free). Quicksort cosim unchanged. Remaining: S/U-mode+delegation, instruction-access-fault, illegal-CSR-access trap, PLIC, vectored-mode interrupt cosim.
- **Synth+PnR of trap path: re-confirmed 2026-08-22** (remote host back online), pre-forwarding. Does not close 40 MHz (route-dominated CSR fan-out, ~37 MHz actual). Target 35 MHz via rPLL: closes 35.004 MHz Fmax, +0.004 ns slack, TNS 0 — knife-edge. 25 MHz PLL-bypass fallback (+2.248 ns). 40 MHz reclaim needs pipelined async CSR read (deferred). **Forwarding re-verify pending.**
- RVC spanning handled; remaining cost is 1-cycle `span_wait` bubble per spanning instr (needs wider F/D to remove).
- I-mem single-outstanding (~2 cyc/instr); pipelined 1-cyc/instr I-mem is a later fetch-throughput optimization, out of scope.
- `cmd.do` targets 35 MHz (history 50→40→25 bypass→35 rPLL, forced by trap+timer critical path). Future 40 MHz retarget needs the async CSR read pipelined.
- `.gprj.user` is per-machine IDE state (gitignored); canonical file list is the `.gprj`.