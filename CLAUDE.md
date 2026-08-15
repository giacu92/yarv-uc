# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

A RV32IMAC + Zicsr + Zifencei RISC-V core targeting a **Gowin GW2AR-18C** FPGA (part `GW2AR-LV18QN88C8/I7`, QFN88 package), on a Sipeed Tang Nano 20k board. The core is a work-in-progress pipeline; **only the instruction fetch stage is implemented so far**. The CPU exits **two AXI4-Lite masters** (`imem_axi`, `peri_axi`). The native `mem_req_t` / `mem_rsp_t` → AXI4-Lite conversion is done **inside the CPU** (one `axi4_lite_master_bridge` per master port), so the rest of the system sees the CPU as a plain AXI4-Lite master and the board top stays free of glue.

Key files:
- Board-level top (IDE `TopModule`): `src/rtl/core/top_module.sv` — `module top_module`.
- CPU RTL top: `src/rtl/core/rv32imac_zicsr_zifencei.sv` — `module rv32imac_zicsr_zifencei`; instantiates pipeline stages + two on-die AXI4-Lite bridges.
- Gowin IDE project: `rv32imac_Zicsr_Zifencei.gprj` (file list + device).
- Process/synthesis config: `impl/rv32imac_Zicsr_Zifencei_process_config.json` (`TopModule`, tool options).
- Synthesized netlist/reports: `impl/gwsynthesis/`. PnR bitstream/reports: `impl/pnr/` (gitignored — regenerable).

## Build flow (Gowin EDA)

This is a **Gowin FPGA Designer** project — no open-source flow, no Makefile. Build via the IDE or `gw_sh` Tcl shell. The Gowin toolchain is **not installed in this environment**; find `gw_sh`/`gw_ide` on the actual build host before invoking (the old `~/gowin_ide/...` paths no longer exist — do not assume them).

The synthesizer writes its run log to `impl/gwsynthesis/rv32imac_Zicsr_Zifencei.log` — **read that file for errors/warnings**; `gw_sh` itself prints only a banner to stdout.

### Synthesize

A committed Tcl entry point exists: `impl/synth_check.tcl`. It opens the `.gprj`, sets `top_module`, and runs `syn`. Invoke it with the Gowin shell (use `QT_QPA_PLATFORM=offscreen` over SSH — the shell still links Qt and needs X11 otherwise):

```bash
QT_QPA_PLATFORM=offscreen gw_sh impl/synth_check.tcl
```

**Gowin CLI quirk (important):** `gw_sh` silently no-ops and produces no output if the target `.vg` / `.log` already exist from a previous run. **Delete them before re-running** synthesis, or the run will appear to succeed while changing nothing.

### Place & Route

Driven by `impl/pnr/cmd.do` (targets GW2AR-18C, runs `-bit -tr -ph -timing`, converts SDP32/36 → SDP16/18 BSRAMs, `global_freq 100.000`). PnR device options come from `impl/pnr/device.cfg`:

```bash
gw_sh -pnr -do impl/pnr/cmd.do
```

Outputs `impl/pnr/rv32imac_Zicsr_Zifencei.fs` / `.bin` for programming. Note: `cmd.do` has **no `-sdc` flag**, so the SDC constraints file is **not** applied in the current PnR flow — timing is unconstrained beyond the global frequency. Add `-sdc src/phys/rv32imac_Zicsr_Zifencei.sdc` to `cmd.do` when you want the 27 MHz clock constraint enforced.

### Constraints (in `src/phys/`, NOT `impl/pnr/`)

Pin assignment — `src/phys/rv32imac_Zicsr_Zifencei.cst`:
- `clk_i` → PIN4 (27 MHz onboard oscillator)
- `rstn_i` → PIN88 (mapped; async, active-low)
- `led_o[0..3]` → PIN15, PIN16, PIN17, PIN18 (onboard LEDs; `fd_pc_dbg_o[3:0]`)

Timing — `src/phys/rv32imac_Zicsr_Zifencei.sdc` (only applied if passed via `-sdc`):
- Primary clock `clk27` at 27 MHz on `clk_i` (period 37.037 ns).
- `rstn_i` (false-path-from) and `led_o[*]` (false-path-to) marked non-timing-critical.

There are **no unit tests and no lint config** in the repo. A **Verilator** functional sim harness lives in `sim/` (see **Simulation** below); it exercises the implemented fetch + bridge + RAM logic.

## Simulation (Verilator)

`sim/` holds a Verilator C++ harness that builds the implemented logic (fetch stage + on-die AXI4-Lite bridge + AXI4-Lite RAM) and logs what the fetch stage delivers. It is **not** part of the synthesis file list.

- `sim/sim_top.sv` — sim wrapper. Replicates `top_module`'s wiring (CPU `imem_axi` → `axi4_lite_ram`; `peri_axi` tied off) but instantiates the RAM with `INIT_FILE="program.hex"` so a program is preloaded via `$readmemh`, and exposes the CPU's full F/D debug taps as output ports for the C++ log.
- `sim/sim_main.cpp` — drives clk/rst (async active-low reset for a few cycles), clocks the design, prints one line per instruction delivered to the F/D register (`cycle / fd_pc / fd_instr / c / next_pc`), and writes a VCD (`sim/sim_top.vcd`) for GTKWave.
- `sim/program.hex` — `$readmemh` preload, one 32-bit hex word per line (the word value IS the instruction encoding). Edit it to test different programs.
- `sim/Makefile` — `make run` builds (`obj_dir/Vsim_top`) and runs from `sim/` (so `program.hex` resolves relative to the run cwd).

Only fetch is implemented, so instructions do **not** execute — the sim verifies fetch delivers the right word at the right PC (advancing by 4), with the right `fd_is_compressed` flag, and that the AXI4-Lite round-trip behaves. Requires Verilator installed on the build host:

```bash
sudo apt-get install -y verilator
cd sim && make run
```

Build artefacts (`sim/obj_dir/`, `*.vcd`, `*.log`) are gitignored.

## Architecture

Built bottom-up; most pipeline stages past fetch are not yet present. Every RTL file does `import rv32_pkg::*;` and starts with `` `resetall `` / `` `default_nettype none `` / `` `timescale 1ns / 1ps `` — **match these in new files**.

### Naming conventions (RTL)

- **Ports:** inputs end `_i`, outputs end `_o` (e.g. `clk_i`, `fd_pc_o`).
- **Internal signals:** **no prefix** — they are neither inputs nor outputs, so they are distinguishable already. Flop registers end `_q`, their next-state combinational counterparts end `_d` (e.g. `pc_q`/`pc_d`, `busy_q`, `state_q`). Plain wires/internals are unadorned (e.g. `imem_req`, `ar_hs`, `axi_bus_imem`).
- **Module instance names:** keep `u_*` (e.g. `u_cpu`, `u_imem_bridge`) — not signals.
- **Types (typedef/enum), parameters, localparams, enum labels, and AXI interface member names** (`awvalid`, `arready`, ...) keep their own spelling; AXI members follow the AXI spec.

- **`src/rtl/pkg/rv32_pkg.sv`** — package: `XLEN=32`, `STRB_WIDTH`, `AXI4_LEN`, and the native memory structs, **split per direction (AXI-style)** so each is a legal single-direction packed struct port: `mem_req_t` (master→bridge: `wvalid`/`we`/`addr`/`wdata`/`wstrb`/`rready`) and `mem_rsp_t` (bridge→master: `wready`/`rvalid`/`rdata`). Handshakes: request launch is `req.wvalid && rsp.wready`; read response is `rsp.rvalid && req.rready`. `req_handshake()` returns the launch predicate. **No `bvalid` (write-ack) yet** — TODO for the LSU; fetch is read-only and the peri bridge is tied off today.
- **`src/rtl/core/fetch_stage.sv`** — the only implemented stage. Owns the PC and the F/D pipeline register (`fd_pc_o`/`fd_instr_o`/`fd_valid_o`/`fd_is_compressed_o`). Exposes a **native** instruction-memory interface (`imem_req_o` / `imem_rsp_i`, direction-split) plus `next_pc_o`. **No bus protocol here** — it handshakes with the on-die bridge (`req.wvalid && rsp.wready` to launch, `rsp.rvalid && req.rready` to capture) as a single-outstanding **overlap-prefetch** FSM (no explicit `state_t`; uses `busy_q`/`req_pc_q`/`flushed_q` flags). Forward-compat inputs `stall_i`, `branch_valid_i`, `branch_addr_i` are on the port but tied off in the CPU top today.
- **`src/rtl/core/rv32imac_zicsr_zifencei.sv`** — CPU RTL top. Instantiates `fetch_stage` (F/D outputs exposed as full-width debug taps — `fd_pc_full_dbg_o`/`fd_instr_dbg_o`/`fd_valid_dbg_o`/`fd_is_compressed_dbg_o`/`next_pc_dbg_o` — because decode is missing) plus **two `axi4_lite_master_bridge`** instances: `u_imem_bridge` (driven by `fetch_stage`'s `imem_req_o`/`imem_rsp_i`) and `u_peri_bridge` (request tied inert — `wvalid=0` — LSU not yet implemented). The native interface is direction-split, so there are **no `req_ready` wires** — `wready` lives in `mem_rsp_t`. `peri_rsp` is sunk to a dummy net (`unused_peri_rsp`) for the future LSU. Exits two AXI4-Lite masters. `fd_pc_dbg_o[3:0]` brought out as the LED tap.
- **`src/rtl/core/top_module.sv`** — board top. Wires CPU `imem_axi` → `axi4_lite_ram` slave on `axi_bus_imem`; routes `peri_axi` to `axi_bus_peri` with the slave side tied off (all `*ready=0`/`*valid=0`) so a future peripheral drops in without rewiring. The CPU's full F/D debug taps are left unconnected here (swept by synthesis); the sim wrapper (`sim/sim_top.sv`) consumes them. `led_o` = `fd_pc_dbg_o[3:0]`.
- **`src/rtl/bus/axi4_lite_if.sv`** — SystemVerilog interface (32-bit addr/data) with `master`, `slave`, and `trunk` modports. `aclk`/`aresetn` are driven into the trunk from the board top.
- **`src/rtl/bus/axi4_lite_master_bridge.sv`** — native `mem_req_t`/`mem_rsp_t` (direction-split) → AXI4-Lite AR/AW/W + R/B. Single shared FSM (`S_IDLE`/`S_RD_WAIT`/`S_WR_ADDR`/`S_WR_DATA`/`S_WR_WAIT`) — **single outstanding overall** (read OR write, not both). `rsp_o.wready = (state_q == S_IDLE)` is the launch handshake from the producer's side. **Read path**: in `S_RD_WAIT` the master's `req_i.rready` is forwarded straight to `axi.rready`, so the AXI slave holds `rvalid`/`rdata` until the master can accept; `rsp_o.rvalid = r_hs` the cycle data is consumed. For writes, AW+W launch in lock-step; on `b_hs` → `S_IDLE`. **Write retirement is not signalled back** (no `bvalid` in `mem_rsp_t` yet — TODO LSU); `bready` held high.
- **`src/rtl/utils/axi4_lite_ram.sv`** — AXI4-Lite slave single-beat RAM, `(* ram_style = "block" *)` (infers BSRAM on Gowin). Params: `ADDR_W` (byte-addressed depth = 2^ADDR_W bytes) and optional `INIT_FILE` for `$readmemh`. Read latency 1 cycle (registered); `bvalid` asserted the cycle W handshakes (after AW captured). Byte-strobed writes. Wired as the `axi_bus_imem` slave.

### Fetch stage behaviour (current)

Single-outstanding **overlap-prefetch**. No `state_t` enum — the FSM is a set of flags (`busy_q`/`req_pc_q`/`flushed_q`) plus the F/D register. Handshakes with the on-die bridge: launch = `imem_req_o.wvalid && imem_rsp_i.wready`; capture = `imem_rsp_i.rvalid && imem_req_o.rready`.

- `pc_q`: **next fetch address** — runs ahead of decode. Resets to `boot_addr_i`. On launch it advances to `pc_q + 4`; on redirect it is overwritten with the target. (Note: fetch always reads 32-bit words and advances by 4 — see Compressed below.)
- `req_pc_q`: address of the **in-flight** fetch. Stamped onto the F/D register at capture, so `fd_pc_o` is the **exact** address of the delivered instruction (not the already-advanced `pc_q`).
- `busy_q`: a fetch is in flight (at most one — single outstanding). `imem_req_o.wvalid = !busy_q && !branch_valid_i` (issue only when idle and not redirecting).
- `imem_req_o.rready = !fd_valid_q || flushed_q` — accept read data when the F/D register has room, **or** drain a flushed (redirected) response to free the bridge. This depends **only on registers**, never on `rvalid`, so there is no combinational loop through the bridge's `axi.rready` forwarding.
- **Overlap-prefetch**: on capture of fetch K (busy→0 next cycle), the next fetch K+1 is launched the very next cycle (the bridge is back in `S_IDLE`), while decode consumes K from the F/D register. Only one transaction is ever in flight (K+1; K already sits in F/D). If decode is slower than memory and K+1's response lands while F/D is still full, `rready` stays low and the bridge/AXI slave hold `rvalid`/`rdata` until decode frees F/D — **no skid buffer needed** (single outstanding ⇒ nothing queues behind the waiting response). Steady-state ~2 cycles/instruction (the bridge round-trip floor: 1 issue + 1 response).
- `fd_valid_o`: **held level** — high from a fresh capture until decode consumes it (`fd_valid_q && !stall_i` → `fd_valid_d=0`), or a redirect kills it. Mutually exclusive with capture (capture needs F/D empty; consume needs F/D full).
- **Redirect** (`branch_valid_i`, highest priority): kills stale F/D (`fd_valid_d=0`) and marks the in-flight fetch `flushed_q=1` so its response is drained and discarded; sets `pc_q` to the target. `wvalid` is gated by `!branch_valid_i` so no fetch of the old `pc_q` issues during the redirect cycle. If the flushed response lands the same cycle as the redirect, it is drained immediately.
- **Compressed (C)**: NOT handled here — always fetches 32 bits, advances by 4; `fd_is_compressed_o = (rdata[1:0] != 2'b11)` is computed for decode, which owns RVC expansion (a compressed instr in the low half of a word ⇒ the next instr is the upper half of the same word, handled in decode).
- **stall_i**: downstream back-pressure. While high the F/D register is held (not consumed); prefetch still issues up to 1 ahead (bounded by single outstanding) and is discarded on redirect.

### Open work / things future instances should know

- **Decode stage is missing** — `fetch_stage`'s F/D outputs are connected to `()` in the CPU top. This is the next obvious step (planned: `decode_stage.sv` + `reg_file.sv`, with RVC expansion living in decode).
- The **redirect path** (`branch_valid_i`/`branch_addr_i` → PC redirect + in-flight flush) and **stall path** (`stall_i` from a hazard unit) are **implemented in the fetch FSM** but tied off in the CPU top. Reserve these names when adding execute/branch and hazard modules.
- The CPU exposes `peri_axi` (inert, no LSU). When the LSU lands it should drive the internal `peri_req`; `u_peri_bridge` will translate to AW/W on `peri_axi` with **no board-top changes**.
- `cmd.do` sets `global_freq 100.000` MHz and currently applies **no SDC** — the Tang Nano 20k runs at 27 MHz; update both before relying on timing closure.
- `rv32imac_Zicsr_Zifencei.gprj.user` is per-machine IDE state (gitignored) — don't rely on it; the canonical file list is the `.gprj`.