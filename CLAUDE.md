# CLAUDE.md

Guidance for Claude Code in this repo.

## Project

RV32IMAC + Zicsr + Zifencei RISC-V core for a **Gowin GW2AR-18C** FPGA (`GW2AR-LV18QN88C8/I7`, QFN88) on a Tang Nano 20k board. Clock: **25 MHz single-ended** from an MS5351M generator (CLK0, PIN10, LVCMOS33) — not the stock 27 MHz oscillator.

**Status:** fetch/decode/execute + LSU + Zicsr implemented. **Harvard** memory system — fetch has a dedicated read-only native I-mem, the LSU has a native byte-strobed D-mem, and AXI survives only for peripherals. Loads/stores/Zilx indexed loads and CSR ops (CSRRW/S/C + imm variants) launch/retire via the native D-mem (or peri bridge) with a stall-on-RAW hazard interlock (no bypass). No trap/exception support — misaligned accesses are suppressed, not trapped; ecall/ebreak/mret/wfi/fence.i stay `illegal=1`.

CPU exposes **three** ports (Harvard, default): a native `imem` (fetch, read-only), a native `dmem` (LSU data, byte-strobed), and an AXI4-Lite master `axi_peri` for memory-mapped peripherals. The native→AXI4-Lite conversion for peripherals is done inside the CPU by one `axi4_lite_master_bridge` (peri-only); the board top is pure point-to-point wires (no crossbar). The LSU decodes `addr[PERI_ADDR_BIT]` itself (`0` → native D-mem, `1` → peri bridge → `0x1000_0000+`). A compile-time `VON_NEUMANN` switch (defined) retains the legacy single-AXI-master topology — fetch+LSU share one `bus_axi` via `mem_arbiter`, board top's `axi4_lite_xbar` splits mem vs peri, `axi4_lite_ram` is the shared RAM. Only non-bus CPU output is `dbg_stall_o` → LED0. Per-stage pc/instr/valid taps stay internal (probed via Verilator hierarchy, not ports).

**Key files:**
- `src/rtl/core/top_module.sv` — board top
- `src/rtl/core/rv32imac_zicsr_zifencei.sv` — CPU top
- `src/rtl/utils/native_ram.sv` — Harvard I/D-mem native slave
- `src/rtl/bus/axi4_lite_xbar.sv` — 1→2 AXI4-Lite crossbar (von-Neumann build only)
- `rv32imac_Zicsr_Zifencei.gprj` — Gowin IDE project
- `impl/rv32imac_Zicsr_Zifencei_process_config.json` — synth config
- `impl/gwsynthesis/`, `impl/pnr/` — synth/PnR outputs (PnR gitignored)

## Build flow (Gowin EDA)

IDE-only, no RTL-level Makefile. Toolchain on remote build host `giacomo@192.168.10.36`: `gw_sh` at `/home/giacomo/gowin_ide/IDE/bin/gw_sh` (V1.9.11.03 Education). rsync repo to `~/gowin_proj/rv32imac_Zicsr_Zifencei/` (see `remote-gowin-build-host` memory). Errors/warnings live in `impl/gwsynthesis/rv32imac_Zicsr_Zifencei_syn.rpt.html` (stdout is just a banner).

### Synthesize
```bash
QT_QPA_PLATFORM=offscreen QT_OPENGL=software LIBGL_ALWAYS_SOFTWARE=1 gw_sh impl/synth_check.tcl
```
Gotcha: silently no-ops if `.vg`/report already exist — delete outputs by explicit filename first (zsh glob failure aborts a wildcard `rm`).

### Place & Route
Options in `impl/pnr/cmd.do` (GW2AR-18C, `-bit -tr -ph -timing`, `global_freq 50.000`); device opts in `impl/pnr/device.cfg`. Run via wrapper:
```bash
QT_QPA_PLATFORM=offscreen QT_OPENGL=software LIBGL_ALWAYS_SOFTWARE=1 gw_sh impl/pnr_check.tcl
```
Gotcha: `gw_sh -pnr -do ...` silently no-ops (not a valid flag in V1.9.11.03) — must use the Tcl wrapper (`run pnr` reads the opened project's saved config). Also no-ops if outputs already exist — delete by filename first, keep `cmd.do`/`device.cfg`. Outputs: `.fs`/`.bin`/`.binx`; timing in `.tr.html` ("Max Frequency Summary" → Actual Fmax). Uses `-sdc src/phys/rv32imac_Zicsr_Zifencei.sdc`.

### Constraints (`src/phys/`)
`.cst`: `clk_i`→PIN10 (25MHz LVCMOS33), `rstn_i`→PIN88 (async active-low), `led_o[0]`=stall indicator, `led_o[3:1]`=counter alive.
`.sdc`: `clk25`@25MHz on `clk_i`; generated `clk_core`@50MHz (sole timing-critical clock). PnR closes ~50.15MHz Actual Fmax (~0.06ns slack, ±0.1MHz run-to-run). A/B test proved regfile primitive is NOT the limiter (BSRAM vs `syn_ramstyle="registers"` — identical Fmax); real critical path is route-dominated (~65% route) in execute/ALU/decode. `rstn_i`/`led_o` false-path.

No lint config. Verilator sim in `sim/` (functional), `sim/native_mem_tb/` (native RAM protocol compliance), `sim/ram_tb/` (AXI4-Lite protocol compliance), and `sim/cosim/` (RTL vs Spike golden ISA ref).

## Simulation (Verilator)

`sim/` builds fetch+decode+execute+native I/D-mem+peri bridge (Harvard default), logs fetch/decode/execute activity. Requires `apt-get install verilator`. Built with `--public-flat-rw` (CPU has no per-stage debug ports). `VON_NEUMANN=1` selects the legacy single-AXI-master build (sim Makefile does NOT track `VON_NEUMANN` as a prereq — switching modes needs `make clean`).

- `sim/sim_top.sv` — wrapper mirroring `top_module`; preloads native I-mem/D-mem via `$readmemh(iinit_file,u_imem.mem)` / `$readmemh(dinit_file,u_dmem.mem)`, plusargs `+IINIT=<path>` (default `imem.hex`) / `+DINIT=<path>` (default `dmem.hex`). Exposes a `PROBE_LEN`-word D-mem window as scalar wires for VCD tracing (32 words @ word 0x800 = the quicksort `.data` array at D-mem 0x2000). Von-Neumann `ifdef` path keeps the single-RAM `+INIT=<path>` (default `program.hex`).
- `sim/sim_main.cpp` — drives clk/rst, 3 log passes (fetch/decode/execute-retire+writeback). Reads internal taps (`fe_pc`, `de_pc`, `ex_pc`/`ex_valid`, `wb_en`/`wb_addr`/`wb_data`) via `Vsim_top___024root.h` + `TAP()` macro. wb sampled pre-edge (comb from `de_q`), `ex_valid` post-edge. Writes `sim/sim_top.vcd`. GTKWave mnemonic decode via `sim/gtkwave_alu_op.txt` / `gtkwave_opcode.txt`. Run stops on park detection (8 identical retires) or `MAX_CYC` (default 4000). `STAP()` macro samples `dbg_stall_o` and prints a stall breakdown (RAW bubble / DIV-REM hold / LSU wait %).
- `sim/imem.hex` + `sim/dmem.hex` — hand-crafted Harvard oracle: RAW interlock (ALU-RAW, div-then-dependent, branch-on-dependent), LSU round-trip + load-use, byte/halfword sign/zero extend. Code in `imem.hex` (0x00-0x74, read-only I-mem); `dmem.hex` is an empty placeholder (oracle data runtime-written via stores to D-mem 0x100+).
- `sim/program.hex` — von-Neumann oracle (single image; legacy build only).
- `sim/Makefile` — `make run` (default Harvard oracle); `RUN_ARGS="+IINIT=... +DINIT=..."` for C programs; `VON_NEUMANN=1` for legacy.
- `sim/sw/` — C→two images via `riscv32-esp-elf-gcc` 14.2.0 (`-march=rv32imac -mabi=ilp32 -nostdlib -ffreestanding`, `medlow` absolute addressing, link script splits `.text`→IMEM ORIGIN=0 / `.data`→DMEM ORIGIN=0x2000). Output `imem.hex` + `dmem.hex` (bin2hex `--base 0x2000` lands `.data` at D-mem 0x2000). Default `main.c`: recursive quicksort over 32-int array, returns `0x600D` (sorted) or `0xBAD` (broken). `-march=rv32imac` doesn't emit Zilx — that stays covered by `imem.hex`/`dmem.hex`.

```bash
cd sim && make run                    # Harvard oracle (imem.hex/dmem.hex)
make sw-run                           # build C prog + run (from repo root)
make VON_NEUMANN=1 run                # legacy single-AXI-master build
```
Build artefacts gitignored.

### Native RAM compliance test (`sim/native_mem_tb/`)
Independent BFM master driving `native_ram` directly (a RW D-mem + a read-only I-mem). Checks RVALID registered & held until RREADY (the key fix vs a naive 1-cycle pulse), byte-strobed partial writes, back-to-back writes, single-outstanding (WREADY low while an unread read is held), posted store commits at launch-accept, and read-only ignoring writes.
```bash
cd sim/native_mem_tb && make run     # "N checks, 0 failures"
```

### AXI4-Lite RAM compliance test (`sim/ram_tb/`)
Independent BFM master driving `axi4_lite_ram` directly. `axi4_lite_ram` is now peri-side only in the Harvard build; `ram_tb` still covers it. Checks registered BVALID held under delayed BREADY (the key compliance fix), AW/W ordering, byte strobes, back-to-back writes, single-outstanding, RVALID held under delayed RREADY.
```bash
cd sim/ram_tb && make run     # "N checks, 0 failures"
```

### Co-sim vs Spike (`sim/cosim/`)
Runs the same C-built ELF on Spike (upstream `riscv-isa-sim`, `--log-commits`, built locally once via `build_spike.sh`) and on the Verilator RTL, then `cosim_diff.py` diffs per-retire architectural effects (pc + register write). Spike is the golden ISA ref; Zilx is already upstream (no patch). The RTL sim writes a per-retire trace to `RTL_TRACE` (`sim_main.cpp`), the diff driver skips Spike's boot-ROM stub and parks both sides at the halt self-loop. Harvard co-sim requires `.data` at a non-zero VMA (link.ld `DMEM ORIGIN=0x2000`) so Spike's unified address space holds `.text`@0 and `.data`@0x2000 disjoint — at VMA 0 the LOAD segments clobber each other. The cosim `SPIKE_MEM` (`0x0:0x1000` code, `0x2000:0xE000` data+stack) matches that split.
```bash
make cosim     # build sw + Spike, run both, diff -> "PASS -- matched N retires"
```

## Code formatting (Verible)

Policy in `verible.flags` (4-space indent, 100-col, aligned ports/params/assignments) — edit that file, don't pass CLI overrides.
```bash
make format        # reformat in place
make format-check  # CI: exit 1 if unformatted
make format-diff   # show pending diff
```
Not in apt; static binary on build host at `~/tools/verible` → `~/.local/bin`.

## Architecture

Built bottom-up. Every RTL file: `import rv32_pkg::*;` + `` `resetall `` / `` `default_nettype none `` / `` `timescale 1ns/1ps ``.

### Naming
Ports `_i`/`_o`. Internal signals no prefix; flops `_q`, next-state comb `_d` (a stage's own pipeline reg keeps its stage sigil, e.g. `fe_pc_q`). Instances `u_*`. Stage debug taps prefixed `fe_`/`de_`/`ex_`, stay internal to the CPU (not exported; only `dbg_stall_o` is).

### Files
- **`rv32_pkg.sv`** — `XLEN=32`; `mem_req_t`/`mem_rsp_t` (direction-split AXI-style; `mem_rsp_t` has `wready`/`rvalid`/`rdata`/`bvalid`). `PERI_ADDR_BIT`=28. Decode types: opcode localparams (incl `OPC_AMO` for Zilx), `alu_op_t` (incl `ALU_LX`), `wb_src_t` (incl `WB_CSR`), `csr_op_t`/`csr_addr_t` (MSTATUS/MISA/MIE/MTVEC/MSCRATCH/MEPC/MCAUSE/MTVAL/MIP/MCYCLE/MINSTRET), packed `de_t` D/E struct (adds `csr_wren`/`csr_op`/`csr_addr`).
- **`fetch_stage.sv`** — PC + F/D reg + 1-entry skid buffer (2-deep FIFO), single-outstanding overlap-prefetch. Run-ahead response landing while F/D full goes to skid, freeing the I-mem port (Harvard) / shared bus (von-Neumann). `stall_i` (decode) / `branch_valid_i`+`branch_addr_i` (execute redirect) wired at CPU top.
- **`decode_stage.sv`** — RV32I+M+C+Zilx+Zicsr. Expand-then-decode-uniformly (`c_expand()` turns RVC→32-bit, one decoder for both); hold buffer stashes upper compressed half. Zilx (`OPC_AMO` funct5 10010/11010; 11110 illegal) swaps rs1/rs2, computes `mem_shamt`. Zicsr (`OPC_SYSTEM` funct3≠0): decodes to `csr_op`/`csr_wren`/`csr_addr`, `wb_src=WB_CSR`; imm variants carry zimm in `imm`. `OPC_SYSTEM` funct3=0 (ecall/ebreak/mret/wfi) → illegal (no trap yet). `stall_o` = hold-term | execute stall | RAW hazard; `flush_i` kills D/E on branch. RAW interlock compares `ex_wb_en_i`/`ex_wb_addr_i` against live decode source addrs → bubbles D/E and holds F/D one cycle. `OPC_MISC_MEM` (Zifencei) / unknown → illegal.
- **`reg_file.sv`** — 32×32 BSRAM, async read ×2 / sync write ×1, x0 hardwired. Confirmed NOT the Fmax limiter (A/B vs `registers` style, identical within noise — registers form costs +992FF/+1128LUT for nothing). No runtime reset on `regs` (BSRAM single write port can't clear all 32 words/cycle; forcing it broke timing) — sim zero-inits via `` `ifdef VERILATOR ``; HW relies on BSRAM power-up + write-before-read (arch-legal).
- **`csr_regfile.sv`** — 11-entry Zicsr machine-mode subset (mstatus/misa/mie/mtvec/mscratch/mepc/mcause/mtval/mip + mcycle/minstret). Async read (decode addr) + sync write (execute RMW). FF+LUT mux, NOT BSRAM (sparse non-contiguous address slice). CSRs ARE reset (architected values; `misa`=0x40002105 read-only). Unimplemented addrs read 0 / ignore writes. `mcycle`/`minstret` free-running perf counters, also CSR-writable; branch/jump retire inputs wired but unused (reserved for future `mhpmcounter`).
- **`alu.sv`** — combinational RV32I + single-cycle MUL (DSP) + multi-cycle DIV/REM (32-iter restoring FSM) + Zilx EA (`ALU_LX = a + (b << shamt)`).
- **`execute_stage.sv`** — selects operands, drives DIV/REM + LSU via unified FSM (`EX_IDLE`/`EX_DIV_BUSY`/`EX_MEM_WAIT`), writes back ALU/PC4/load/old-CSR, resolves branches + fetch redirect, drives native LSU port, does the CSR RMW. Loads/stores/Zilx launch in `EX_IDLE`, stall in `EX_MEM_WAIT` until retire (`rvalid`/`bvalid`). **Posted store**: a store retires on launch-accept (`wvalid && wready && we`) and commits same clock edge — native D-mem 1-cyc, peri via the bridge. Loads wait in `EX_MEM_WAIT` until `rvalid` (native D-mem: 1-cyc; peri: multi-cycle). `mem_rsp_i.bvalid` is 0 from native RAM (no B channel); the bridge asserts `bvalid` on its B handshake (unused by the posted-store path but present). LSU steers `addr[PERI_ADDR_BIT]` itself: `0` → native D-mem, `1` → peri bridge. CSR: `csr_new` = RW:src / RS:`old|src` / RC:`old&~src`; write gated on retire predicate AND (RS/RC) `src!=0`. Load alignment: shift by `addr[1:0]`, sign/zero-extend per size. Misaligned access suppressed, not trapped, no trap. **No bypass path** — hazards resolved only by the decode-side stall-on-RAW interlock.
- **`rv32imac_zicsr_zifencei.sv`** — CPU top wiring fetch+reg_file+csr_regfile+decode+execute. Three ports (Harvard default): native `imem`/`dmem` + AXI4-Lite `axi_peri`; the peri `axi4_lite_master_bridge` lives inside the CPU. `VON_NEUMANN` collapses to one `bus_axi` master (fetch+LSU share `mem_arbiter`). Only non-bus output: `dbg_stall_o`.
- **`top_module.sv`** — board top. 25MHz `clk_i`→rPLL→`clk_core`=50MHz, single clock domain (no CDC). Harvard: native `u_imem` (read-only) on `CPU.imem`, native `u_dmem` (byte-strobed) on `CPU.dmem`, peri tieoff on `axi_bus_peri`. `VON_NEUMANN`: `bus_axi`→`axi4_lite_xbar`→mem (`axi4_lite_ram`) / peri. `led_o[0]`=stall, `led_o[3:1]`=free-running counter.
- **`native_ram.sv`** (utils) — Harvard native `mem_req_t`/`mem_rsp_t` slave, `READ_ONLY` param (1=I-mem, 0=D-mem), byte-strobed D-mem write. Mirrors `axi4_lite_ram`'s handshake: `wready = !rvalid_q || (rvalid_q && rready)` (accept when no unread response held, or while draining), `rvalid` registered & held until `rready` (not a 1-cycle pulse), `bvalid=0` (native RAM has no B channel — LSU uses posted store). No addr latch: read-launch latches `rdata_q` at the accept cycle.
- **`axi4_lite_master_bridge.sv`** — `mem_req_t`/`mem_rsp_t`↔AXI4-Lite, single FSM, single outstanding. `rsp_o.bvalid` asserted on B handshake (store retire). Now peri-only (inside the CPU in the Harvard build; the sole CPU→bus bridge in von-Neumann).
- **`axi4_lite_xbar.sv`** — 1→2 crossbar, routes by `addr[SEL_BIT]` (default bit 28). Per-direction target latch, single-outstanding pass-through, no comb loop. Von-Neumann build only (Harvard has no AXI mem split).
- **`mem_arbiter.sv`** — fetch(low-pri)/LSU(high-pri)→1 shared bridge. Re-arbitrates every free cycle by priority (NOT auto-relaunch previous owner) — stops fetch's near-constant `wvalid` from starving the LSU. Von-Neumann build only (Harvard gives fetch its own I-mem port).
- **`axi4_lite_ram.sv`** — AXI4-Lite slave, single-beat, protocol-compliant (verified by `ram_tb`). BVALID registered & held until B handshake (the fix vs a naive combinational version). Single-outstanding, byte-strobed via BSRAM byte enables. Von-Neumann mem slave / Harvard peri-side (kept on disk, reusable).

### Fetch behaviour
2-deep FIFO (F/D head + 1-entry skid tail). Issues (`wvalid`) only when FIFO has room; accepts responses (`rready`) whenever there's room — response lands in skid if F/D is full. Harvard: fetch owns the I-mem port uncontended, so the skid's job is just F/D-head-stalls overlap, not bus-arbitration safety. Von-Neumann: the skid frees the shared bus for the LSU (avoids a starvation deadlock). ~2 cyc/instr steady state (single-outstanding native I-mem). Skid gave 15-20% cycle-count improvement over a no-skid gate fix (measured on oracle + Zilx quicksort). Redirect kills F/D+skid, marks in-flight discarded, sets new `pc_q`. Compressed: fetch always reads 32-bit words; decode handles expansion/odd-half alignment.

### Decode behaviour
Source priority: spanning stitch > compressed hold > odd-half target > fresh low half. **RVC spanning** (32-bit instr split across a word boundary) is handled: low half stashed, stitched with next word's upper half when it arrives (one bubble, `span_wait`). Odd-half branch targets that are 32-bit instrs stitch the same way. `decoded_valid` excludes wait states so neither a spurious valid nor a false RAW trigger occurs. Deferred (`illegal=1`): Zifencei fence/fence.i, `OPC_SYSTEM` funct3=0, atomics, unknown. Zicsr ops decode and retire fully.

### Hazard interlock (stall-on-RAW, in decode_stage, no bypass)
`raw_haz` fires when execute retires a writeback (`ex_wb_en_i`) matching a live decode source addr, gated on `decoded_valid` (covers hold-buffer RVC consumers too). On hit: bubble D/E (`de_next='0`, no re-run of execute) + hold F/D one cycle, so decode re-reads regs after the write commits. Covers ALU-RAW, div-done-then-use, branch-on-dependent, and load-use (load's extra `EX_MEM_WAIT` naturally delays the consumer; its `wb_en` pulse triggers the bubble). `~flush_i` skips the stall on a taken JAL/JALR. No comb loop (depends only on registered sources).

**Known limitations:**
- No bypass path — every dependent op pays a 1-cycle bubble.
- No trap/exception machinery. Misaligned accesses suppressed, not trapped. Cross-word sub-word accesses unhandled.
- Harvard: I-mem holds `.text`/`.text.init` only (fetch port, read-only); `.rodata`/`.data`/`.bss`/stack live in D-mem (LSU port). `.data` is linked at DMEM ORIGIN 0x2000 (not 0) so the von-Neumann co-sim golden model (Spike) can hold `.text`@0 and `.data`@0x2000 disjoint in its single address space — at VMA 0 they'd clobber. `medlow` absolute addressing required (not `medany` — PC-relative `.text`→`.data` offsets would land in I-mem, not D-mem). `fence.i` / self-modifying code is unsupported (no D→I write path) — already illegal/deferred, accepted as a Harvard limitation.
- Peripheral bus is address-decoded but **no slave instantiated yet** — a peri access (`addr[PERI_ADDR_BIT]` set) stalls the LSU forever (tied-off peri side).

### Open work
- Harvard I/D-mem split done (fetch on dedicated read-only I-mem; LSU on native byte-strobed D-mem; AXI peri-only). Perf: quicksort 4711 cyc / IPC ~0.46 / 9.5% stall (Harvard) vs 5863 / 0.37 / 16% (von-Neumann) — −16% cycles, +19% IPC, stall nearly halved (dedicated I-mem removes fetch/LSU contention). Co-sim vs Spike (`make cosim`) passes: the whole quicksort matches the golden ISA ref retire-for-retire (2165 matched).
- I-mem `INIT_FILE` must point at firmware for any meaningful synthesis (a read-only RAM with empty init folds to constant 0 → the whole pipeline sweeps as dead code). `top_module.sv` `u_imem` currently loads `sim/imem.hex` (the oracle) as the timing-closure / bring-up firmware; a real product bitstream re-points it at the application firmware.
- LSU done (loads/stores/Zilx retire via native D-mem + peri bridge; load-use covered by RAW interlock; posted store for both D-mem and peri).
- Need a real UART/GPIO slave on `axi_bus_peri` (decode path — `addr[PERI_ADDR_BIT]` steer — is already in place).
- Synth + PnR on the remote build host to confirm Harvard synthesizes (new `native_ram.sv` Gowin-clean — follow EX3990/EX3900/BSRAM rules in memory) and PnR closes ≥50MHz. Native I/D-mem paths should be *shorter* than the old AXI round-trip; the execute/ALU/decode route-dominated limiter is unaffected. Re-measure Actual Fmax.
- Zicsr subset retires (see file list above); Zifencei + `OPC_SYSTEM` funct3=0 still deferred. No CSR field semantics yet (mstatus MIE/MPIE, mip/mie bits, mtvec MODE, mcause codes) — needed before trap entry/return (mret, ecall/ebreak).
- No trap/exception machinery at all — add before relying on unaligned-tolerant code.
- RVC spanning is handled (see Decode behaviour); remaining cost is the 1-cycle `span_wait` bubble per spanning instr (would need a wider F/D to avoid).
- I-mem is single-outstanding (~2 cyc/instr); a pipelined 1-cyc/instr I-mem (BSRAM supports pipelined reads; needs backpressure skid) is a later fetch-throughput optimization, out of scope.
- `cmd.do` targets 50MHz; PnR closes ~50.15MHz (regfile primitive ruled out as limiter — route-dominated execute/ALU/decode path is the next target for headroom).
- `.gprj.user` is per-machine IDE state (gitignored); canonical file list is the `.gprj`.