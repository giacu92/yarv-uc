# CLAUDE.md

Guidance for Claude Code in this repo.

## Project

RV32IMAC + Zicsr + Zifencei RISC-V core for a **Gowin GW2AR-18C** FPGA (`GW2AR-LV18QN88C8/I7`, QFN88) on a Tang Nano 20k board. Clock: **25 MHz single-ended** from an MS5351M generator (CLK0, PIN10, LVCMOS33) — not the stock 27 MHz oscillator.

**Status:** fetch/decode/execute + LSU + Zicsr implemented. Loads/stores/Zilx indexed loads and CSR ops (CSRRW/S/C + imm variants) launch/retire via the shared imem bus and a stall-on-RAW hazard interlock (no bypass). No trap/exception support — misaligned accesses are suppressed, not trapped; ecall/ebreak/mret/wfi/fence.i stay `illegal=1`.

CPU exposes one AXI4-Lite master (`bus_axi`) carrying all traffic — fetch+LSU share it via `mem_arbiter`, converted natively via one `axi4_lite_master_bridge`. Board top splits mem vs peri by `addr[28]` via `axi4_lite_xbar` → `axi4_lite_ram` (mem) / peripheral bus (peri slave not yet instantiated). CPU is agnostic to mem/peri; only non-bus CPU output is `dbg_stall_o` → LED0. Per-stage pc/instr/valid taps stay internal (probed via Verilator hierarchy, not ports).

**Key files:**
- `src/rtl/core/top_module.sv` — board top
- `src/rtl/core/rv32imac_zicsr_zifencei.sv` — CPU top
- `src/rtl/bus/axi4_lite_xbar.sv` — 1→2 AXI4-Lite crossbar
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

No lint config. Verilator sim in `sim/` (functional) and `sim/ram_tb/` (AXI4-Lite protocol compliance).

## Simulation (Verilator)

`sim/` builds fetch+decode+execute+arbiter+bridge+RAM, logs fetch/decode/execute activity. Requires `apt-get install verilator`. Built with `--public-flat-rw` (CPU has no per-stage debug ports).

- `sim/sim_top.sv` — wrapper mirroring `top_module`; preloads RAM via `$readmemh`, plusarg `+INIT=<path>` (default `program.hex`). Exposes a `PROBE_LEN`-word RAM window as scalar wires for VCD tracing (16 words @ word 63 = the quicksort `.data` array).
- `sim/sim_main.cpp` — drives clk/rst, 3 log passes (fetch/decode/execute-retire+writeback). Reads internal taps (`fe_pc`, `de_pc`, `ex_pc`/`ex_valid`, `wb_en`/`wb_addr`/`wb_data`) via `Vsim_top___024root.h` + `TAP()` macro. wb sampled pre-edge (comb from `de_q`), `ex_valid` post-edge. Writes `sim/sim_top.vcd`. GTKWave mnemonic decode via `sim/gtkwave_alu_op.txt` / `gtkwave_opcode.txt`. Run stops on park detection (8 identical retires) or `MAX_CYC` (default 4000). `STAP()` macro samples `dbg_stall_o` and prints a stall breakdown (RAW bubble / DIV-REM hold / LSU wait %).
- `sim/program.hex` — hand-crafted oracle: RAW interlock (ALU-RAW, div-then-dependent, branch-on-dependent), LSU round-trip + load-use, byte/halfword sign/zero extend. Data at 0x100+, code at 0x00-0x58 (von Neumann, kept separate).
- `sim/Makefile` — `make run` (default oracle); `RUN_ARGS="+INIT=sw/build/program.hex"` for C programs.
- `sim/sw/` — C→hex via `riscv32-esp-elf-gcc` 14.2.0 (`-march=rv32imac -mabi=ilp32 -nostdlib -ffreestanding`, linked @0x0). Default `main.c`: recursive quicksort over 16-int array, returns `0x600D` (sorted) or `0xBAD` (broken). `-march=rv32imac` doesn't emit Zilx — that stays covered by `program.hex`.

```bash
cd sim && make run                    # oracle program
make sw-run                           # build C prog + run (from repo root)
```
Build artefacts gitignored.

### AXI4-Lite RAM compliance test (`sim/ram_tb/`)
Independent BFM master driving `axi4_lite_ram` directly. Checks registered BVALID held under delayed BREADY (the key compliance fix), AW/W ordering, byte strobes, back-to-back writes, single-outstanding, RVALID held under delayed RREADY.
```bash
cd sim/ram_tb && make run     # "N checks, 0 failures"
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
- **`fetch_stage.sv`** — PC + F/D reg + 1-entry skid buffer (2-deep FIFO), single-outstanding overlap-prefetch. Run-ahead response landing while F/D full goes to skid, freeing the shared bus for the LSU (deadlock-free run-ahead). `stall_i` (decode) / `branch_valid_i`+`branch_addr_i` (execute redirect) wired at CPU top.
- **`decode_stage.sv`** — RV32I+M+C+Zilx+Zicsr. Expand-then-decode-uniformly (`c_expand()` turns RVC→32-bit, one decoder for both); hold buffer stashes upper compressed half. Zilx (`OPC_AMO` funct5 10010/11010; 11110 illegal) swaps rs1/rs2, computes `mem_shamt`. Zicsr (`OPC_SYSTEM` funct3≠0): decodes to `csr_op`/`csr_wren`/`csr_addr`, `wb_src=WB_CSR`; imm variants carry zimm in `imm`. `OPC_SYSTEM` funct3=0 (ecall/ebreak/mret/wfi) → illegal (no trap yet). `stall_o` = hold-term | execute stall | RAW hazard; `flush_i` kills D/E on branch. RAW interlock compares `ex_wb_en_i`/`ex_wb_addr_i` against live decode source addrs → bubbles D/E and holds F/D one cycle. `OPC_MISC_MEM` (Zifencei) / unknown → illegal.
- **`reg_file.sv`** — 32×32 BSRAM, async read ×2 / sync write ×1, x0 hardwired. Confirmed NOT the Fmax limiter (A/B vs `registers` style, identical within noise — registers form costs +992FF/+1128LUT for nothing). No runtime reset on `regs` (BSRAM single write port can't clear all 32 words/cycle; forcing it broke timing) — sim zero-inits via `` `ifdef VERILATOR ``; HW relies on BSRAM power-up + write-before-read (arch-legal).
- **`csr_regfile.sv`** — 11-entry Zicsr machine-mode subset (mstatus/misa/mie/mtvec/mscratch/mepc/mcause/mtval/mip + mcycle/minstret). Async read (decode addr) + sync write (execute RMW). FF+LUT mux, NOT BSRAM (sparse non-contiguous address slice). CSRs ARE reset (architected values; `misa`=0x40002105 read-only). Unimplemented addrs read 0 / ignore writes. `mcycle`/`minstret` free-running perf counters, also CSR-writable; branch/jump retire inputs wired but unused (reserved for future `mhpmcounter`).
- **`alu.sv`** — combinational RV32I + single-cycle MUL (DSP) + multi-cycle DIV/REM (32-iter restoring FSM) + Zilx EA (`ALU_LX = a + (b << shamt)`).
- **`execute_stage.sv`** — selects operands, drives DIV/REM + LSU via unified FSM (`EX_IDLE`/`EX_DIV_BUSY`/`EX_MEM_WAIT`), writes back ALU/PC4/load/old-CSR, resolves branches + fetch redirect, drives native LSU port, does the CSR RMW. Loads/stores/Zilx launch in `EX_IDLE`, stall in `EX_MEM_WAIT` until retire (`rvalid`/`bvalid`). CSR: `csr_new` = RW:src / RS:`old|src` / RC:`old&~src`; write gated on retire predicate AND (RS/RC) `src!=0`. Load alignment: shift by `addr[1:0]`, sign/zero-extend per size. Misaligned access suppressed, not trapped, no trap. **No bypass path** — hazards resolved only by the decode-side stall-on-RAW interlock.
- **`rv32imac_zicsr_zifencei.sv`** — CPU top wiring fetch+reg_file+csr_regfile+decode+execute+mem_arbiter+bridge. Only non-bus output: `dbg_stall_o`.
- **`top_module.sv`** — board top. 25MHz `clk_i`→rPLL→`clk_core`=50MHz, single clock domain (no CDC). `bus_axi`→`axi4_lite_xbar`→mem (`axi4_lite_ram`) / peri (tied off, reserved for UART/GPIO). `led_o[0]`=stall, `led_o[3:1]`=free-running counter.
- **`axi4_lite_master_bridge.sv`** — `mem_req_t`/`mem_rsp_t`↔AXI4-Lite, single FSM, single outstanding. `rsp_o.bvalid` asserted on B handshake (store retire).
- **`axi4_lite_xbar.sv`** — 1→2 crossbar, routes by `addr[SEL_BIT]` (default bit 28). Per-direction target latch, single-outstanding pass-through, no comb loop.
- **`mem_arbiter.sv`** — fetch(low-pri)/LSU(high-pri)→1 shared bridge. Re-arbitrates every free cycle by priority (NOT auto-relaunch previous owner) — stops fetch's near-constant `wvalid` from starving the LSU.
- **`axi4_lite_ram.sv`** — AXI4-Lite slave, single-beat, protocol-compliant (verified by `ram_tb`). BVALID registered & held until B handshake (the fix vs a naive combinational version). Single-outstanding, byte-strobed via BSRAM byte enables.

### Fetch behaviour
2-deep FIFO (F/D head + 1-entry skid tail). Issues (`wvalid`) only when FIFO has room; accepts responses (`rready`) whenever there's room — response lands in skid if F/D is full, freeing the shared bus for the LSU immediately (avoids a starvation deadlock). ~2 cyc/instr steady state. Skid gave 15-20% cycle-count improvement over a no-skid gate fix (measured on oracle + Zilx quicksort). Redirect kills F/D+skid, marks in-flight discarded, sets new `pc_q`. Compressed: fetch always reads 32-bit words; decode handles expansion/odd-half alignment.

### Decode behaviour
Source priority: spanning stitch > compressed hold > odd-half target > fresh low half. **RVC spanning** (32-bit instr split across a word boundary) is handled: low half stashed, stitched with next word's upper half when it arrives (one bubble, `span_wait`). Odd-half branch targets that are 32-bit instrs stitch the same way. `decoded_valid` excludes wait states so neither a spurious valid nor a false RAW trigger occurs. Deferred (`illegal=1`): Zifencei fence/fence.i, `OPC_SYSTEM` funct3=0, atomics, unknown. Zicsr ops decode and retire fully.

### Hazard interlock (stall-on-RAW, in decode_stage, no bypass)
`raw_haz` fires when execute retires a writeback (`ex_wb_en_i`) matching a live decode source addr, gated on `decoded_valid` (covers hold-buffer RVC consumers too). On hit: bubble D/E (`de_next='0`, no re-run of execute) + hold F/D one cycle, so decode re-reads regs after the write commits. Covers ALU-RAW, div-done-then-use, branch-on-dependent, and load-use (load's extra `EX_MEM_WAIT` naturally delays the consumer; its `wb_en` pulse triggers the bubble). `~flush_i` skips the stall on a taken JAL/JALR. No comb loop (depends only on registered sources).

**Known limitations:**
- No bypass path — every dependent op pays a 1-cycle bubble.
- No trap/exception machinery. Misaligned accesses suppressed, not trapped. Cross-word sub-word accesses unhandled.
- Peripheral bus is address-decoded but **no slave instantiated yet** — a peri access currently stalls the LSU forever (tied-off `awready`/`arready`).

### Open work
- LSU done (loads/stores/Zilx retire via shared bus + arbiter; load-use covered by RAW interlock).
- Need a real UART/GPIO slave on `axi_bus_peri` (decode path is already in place).
- Zicsr subset retires (see file list above); Zifencei + `OPC_SYSTEM` funct3=0 still deferred. No CSR field semantics yet (mstatus MIE/MPIE, mip/mie bits, mtvec MODE, mcause codes) — needed before trap entry/return (mret, ecall/ebreak).
- No trap/exception machinery at all — add before relying on unaligned-tolerant code.
- RVC spanning is handled (see Decode behaviour); remaining cost is the 1-cycle `span_wait` bubble per spanning instr (would need a wider F/D to avoid).
- `cmd.do` targets 50MHz; PnR closes ~50.15MHz (regfile primitive ruled out as limiter — route-dominated execute/ALU/decode path is the next target for headroom).
- `.gprj.user` is per-machine IDE state (gitignored); canonical file list is the `.gprj`.