# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

A RV32IMAC + Zicsr + Zifencei RISC-V core targeting a **Gowin GW2AR-18C** FPGA (part `GW2AR-LV18QN88C8/I7`, QFN88 package), on a Sipeed Tang Nano 20k board. The core is a work-in-progress pipeline: **fetch and decode stages are implemented** (the pipe reaches the D/E register); **execute onward is not yet present**. The CPU exits **two AXI4-Lite masters** (`imem_axi`, `peri_axi`). The native `mem_req_t` / `mem_rsp_t` → AXI4-Lite conversion is done **inside the CPU** (one `axi4_lite_master_bridge` per master port), so the rest of the system sees the CPU as a plain AXI4-Lite master and the board top stays free of glue.

Key files:
- Board-level top (IDE `TopModule`): `src/rtl/core/top_module.sv` — `module top_module`.
- CPU RTL top: `src/rtl/core/rv32imac_zicsr_zifencei.sv` — `module rv32imac_zicsr_zifencei`; instantiates pipeline stages + two on-die AXI4-Lite bridges.
- Gowin IDE project: `rv32imac_Zicsr_Zifencei.gprj` (file list + device).
- Process/synthesis config: `impl/rv32imac_Zicsr_Zifencei_process_config.json` (`TopModule`, tool options).
- Synthesized netlist/reports: `impl/gwsynthesis/`. PnR bitstream/reports: `impl/pnr/` (gitignored — regenerable).

## Build flow (Gowin EDA)

This is a **Gowin FPGA Designer** project — no open-source flow, no Makefile. Build via the IDE or `gw_sh` Tcl shell. The Gowin toolchain is **not installed in the local WSL env**; it runs on a remote build host (`giacomo@192.168.10.36`) where `gw_sh` lives at `/home/giacomo/gowin_ide/IDE/bin/gw_sh` (Gowin V1.9.11.03 Education, NOT on the remote PATH — use the full path). rsync the repo to `~/gowin_proj/rv32imac_Zicsr_Zifencei/` there to build; see the `remote-gowin-build-host` memory for the exact workflow.

The synthesizer writes its report to `impl/gwsynthesis/rv32imac_Zicsr_Zifencei_syn.rpt.html` — **read that file for errors/warnings**; `gw_sh` itself prints only a banner to stdout.

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
- `led_o[0..3]` → PIN15, PIN16, PIN17, PIN18 (onboard LEDs; `fe_pc_dbg_o[3:0]`)

Timing — `src/phys/rv32imac_Zicsr_Zifencei.sdc` (only applied if passed via `-sdc`):
- Primary clock `clk27` at 27 MHz on `clk_i` (period 37.037 ns).
- Generated clock `clk_core` at 99 MHz on the `clk_core` net (`create_generated_clock -source clk_i -master_clock clk27 -multiply_by 11 -divide_by 3`; 27×22/6, period 10.101 ns). The whole fabric runs on `clk_core`, so this is the only timing-critical clock; `clk27` only feeds the rPLL and has no user-logic paths.
- `rstn_i` (false-path-from) and `led_o[*]` (false-path-to) marked non-timing-critical.

There is **no lint config** in the repo. A **Verilator** functional sim harness lives in `sim/` (see **Simulation** below); it exercises the implemented fetch + decode + bridge + RAM logic. A separate **AXI4-Lite RAM protocol-compliance test** lives in `sim/ram_tb/` (see **Simulation** below); it drives the RAM slave directly as a master and verifies the B/R channel handshake rules.

## Simulation (Verilator)

`sim/` holds a Verilator C++ harness that builds the implemented logic (fetch + decode + on-die AXI4-Lite bridge + AXI4-Lite RAM) and logs what fetch delivers and what decode produces. It is **not** part of the synthesis file list.

- `sim/sim_top.sv` — sim wrapper. Replicates `top_module`'s wiring (CPU `imem_axi` → `axi4_lite_ram`; `peri_axi` tied off) but instantiates the RAM with `INIT_FILE="program.hex"` so a program is preloaded via `$readmemh`, and exposes the CPU's `fe_*` (fetch) AND `de_*` (decode) debug taps — `pc / instr / valid` per stage — as output ports for the C++ log.
- `sim/sim_main.cpp` — drives clk/rst (async active-low reset for a few cycles), clocks the design, and prints **two** logs: a **fetch log** (one line per F/D-valid word: `cycle / fe_pc / fe_instr / c`, with a word-advance-+4 check) and a **decode log** (one line per D/E-valid instruction: `cycle / de_pc / de_instr`). Each log is its own reset+run pass so the two stay aligned. A VCD (`sim/sim_top.vcd`) is written for GTKWave. The CPU exports only `pc / instr / valid` per stage now, so the decode log no longer shows control/immediates/operands — add taps back when those need verifying.
- `sim/program.hex` — `$readmemh` preload, one 32-bit hex word per line (the word value IS the instruction encoding; a word may hold one 32-bit instr or two 16-bit compressed instrs). Edit it to test different programs. **There is no assembler** — encodings are hand-computed and verified against the sim decode log (the sim is the oracle).
- `sim/Makefile` — `make run` builds (`obj_dir/Vsim_top`) and runs from `sim/` (so `program.hex` resolves relative to the run cwd). The RTL list includes `reg_file.sv` + `decode_stage.sv` (not part of synthesis).

Fetch and decode are implemented but there is **no execute stage**, so instructions do **not** execute — the sim verifies fetch delivers the right word at the right PC (advancing by 4) and that the AXI4-Lite round-trip behaves, and prints the decode PC/instruction stream. The CPU exports only `pc / instr / valid` per stage, so decode control/immediates/reg-reads are no longer observable in sim (reads are 0 until a writeback stage exists). Requires Verilator installed on the build host:

```bash
sudo apt-get install -y verilator
cd sim && make run
```

Build artefacts (`sim/obj_dir/`, `*.vcd`, `*.log`) are gitignored.

### AXI4-Lite RAM compliance test (`sim/ram_tb/`)

A second, independent Verilator harness that does **not** use the CPU — it instantiates `axi4_lite_ram` alone and drives it as an AXI4-Lite master from C++ (`ram_tb.cpp` is a small cycle-accurate BFM). It verifies the RAM's **protocol compliance**, which the main sim cannot (the CPU has no LSU/writeback, so it never writes to the RAM):

- `sim/ram_tb/ram_tb.sv` — wrapper that breaks the `axi4_lite_if` out to flat master-side ports for the C++ BFM.
- `sim/ram_tb/ram_tb.cpp` — BFM + checks. Key checks: **BVALID is registered and held high while BREADY is deliberately kept low for several cycles** (the fix that made the RAM compliant — the old combinational BVALID would have dropped here); AW-first and W-first orderings; byte-strobed partial writes read back correctly; back-to-back writes; **single outstanding** (AWREADY/WREADY low while B pending); RVALID held while RREADY delayed.
- `sim/ram_tb/Makefile` — `make run` builds `obj_dir/Vram_tb` and runs it; exits non-zero on any check failure.

```bash
cd sim/ram_tb && make run     # prints "N checks, 0 failures" on success
```

## Code formatting (Verible)

SystemVerilog is formatted with **Verible** (`verible-verilog-format`). The project policy lives in `verible.flags` (a Verible `--flagfile`); it captures the style the RTL already follows — 4-space indent, 100-column limit, aligned port / named-parameter / named-port / assignment groups, and `end else` kept on one line. Edit `verible.flags` to change the project-wide policy; do not pass overriding flags on the command line or the two drift apart.

A top-level `Makefile` drives the formatter over every `.sv`/`.svh`/`.v` under `src/rtl` and `sim/` (excluding `sim/obj_dir`):

```bash
make format        # reformat every file in place
make format-check  # exit 1 if any file is unformatted (CI / pre-commit)
make format-diff   # print the pending formatting diff
```

Verible is not in Debian apt on this distro; install the static binary from [chipsalliance/verible](https://github.com/chipsalliance/verible/releases) (the formatter is `verible-verilog-format`, the linter `verible-verilog-lint`). The build host has it at `~/tools/verible` with the `bin/` tools symlinked into `~/.local/bin` (already on PATH). The formatter reads `verible.flags` from the repo root via `--flagfile`, so it works the same from the IDE or CLI.

## Architecture

Built bottom-up; fetch and decode are implemented, execute onward is not yet present. Every RTL file does `import rv32_pkg::*;` and starts with `` `resetall `` / `` `default_nettype none `` / `` `timescale 1ns / 1ps `` — **match these in new files**.

### Naming conventions (RTL)

- **Ports:** inputs end `_i`, outputs end `_o` (e.g. `clk_i`, `fe_pc_o`).
- **Internal signals:** **no prefix** — they are neither inputs nor outputs, so they are distinguishable already. Flop registers end `_q`, their next-state combinational counterparts end `_d` (e.g. `pc_q`/`pc_d`, `busy_q`, `state_q`). Plain wires/internals are unadorned (e.g. `imem_req`, `ar_hs`, `axi_bus_imem`). The one exception: a stage's **own output pipeline register** carries that stage's sigil (see next) so it disambiguates from other same-named flops in the stage — e.g. `fe_pc_q` (the F/D register PC) vs `pc_q` (fetch's next-fetch address).
- **Module instance names:** keep `u_*` (e.g. `u_cpu`, `u_imem_bridge`) — not signals.
- **Types (typedef/enum), parameters, localparams, enum labels, and AXI interface member names** (`awvalid`, `arready`, ...) keep their own spelling; AXI members follow the AXI spec.
- **Pipeline debug taps (stage sigil):** every pipeline stage exposes **only** the PC it is treating, the instruction word, and a valid as outputs, prefixed by a stage-identifying sigil — `fe_` (fetch), `de_` (decode), `ex_` (execute, future), .... Any further debug signals are added on demand (do **not** bake a long control-bundle tap list into the ports). The sigil names the **producing** stage: the F/D register is fetch's output (`fe_pc`/`fe_instr`/`fe_valid`); the D/E register is decode's output, exposed as `de_pc`/`de_instr`/`de_valid`. A stage's **consuming** input ports take the producer's sigil (decode's F/D inputs are `fe_*_i`); `is_compressed` is **not** a separate fetch port — decode derives it from `fe_instr_i[1:0]` itself. The CPU top mirrors the per-stage taps as `fe_*_dbg_o` / `de_*_dbg_o` (plain `logic`, pc/instr/valid only); the board top leaves them unconnected (swept by synthesis) except `fe_pc_dbg_o[3:0]` → LEDs.

- **`src/rtl/pkg/rv32_pkg.sv`** — package: `XLEN=32`, `STRB_WIDTH`, `AXI4_LEN`, the native memory structs (**split per direction, AXI-style**: `mem_req_t` master→bridge `wvalid`/`we`/`addr`/`wdata`/`wstrb`/`rready`; `mem_rsp_t` bridge→master `wready`/`rvalid`/`rdata`; launch = `req.wvalid && rsp.wready`, read = `rsp.rvalid && req.rready`, `req_handshake()` returns the launch predicate; **no `bvalid` yet** — TODO LSU), **and the decode types**: major-opcode `localparam`s (`OPC_LUI`..`OPC_SYSTEM`), `alu_op_t` (18 values, 5 bits — base RV32I + M), `branch_t` (`BR_NONE`..`BR_JALR`), `alu_src_a_t`/`alu_src_b_t`/`wb_src_t`/`mem_size_t`, and the packed **`de_t`** D/E control struct (single-direction, legal as one port — matches `mem_req_t`/`mem_rsp_t`). `de_t` fields: `valid`/`pc`/`instr`/`is_compressed`/`rs1_addr`/`rs2_addr`/`rs1_data`/`rs2_data`/`imm`/`rd`/`reg_write`/`alu_op`/`alu_src_a`/`alu_src_b`/`mem_read`/`mem_write`/`mem_size`/`mem_unsigned`/`wb_src`/`branch_type`/`illegal`. `instr` is the 32-bit word decode treated (native or RVC-expanded), latched alongside `pc`/`valid` so the `de_*` taps stay aligned.
- **`src/rtl/core/fetch_stage.sv`** — fetch stage. Owns the PC and the F/D pipeline register, exposed as `fe_*` taps: `fe_pc_o`/`fe_instr_o`/`fe_valid_o` (pc/instr/valid only — no `fe_is_compressed_o`/`fe_next_pc_o`; decode derives is-compressed from `fe_instr[1:0]`). Exposes a **native** instruction-memory interface (`imem_req_o` / `imem_rsp_i`, direction-split). **No bus protocol here** — it handshakes with the on-die bridge (`req.wvalid && rsp.wready` to launch, `rsp.rvalid && req.rready` to capture) as a single-outstanding **overlap-prefetch** FSM (no explicit `state_t`; uses `busy_q`/`req_pc_q`/`flushed_q` flags). Forward-compat inputs `stall_i` (driven by decode's `stall_o`), `branch_valid_i`, `branch_addr_i` are on the port; `branch_*` stay tied off in the CPU top today.
- **`src/rtl/core/decode_stage.sv`** — decode stage (phase 1: RV32I + M + C). Consumes fetch's `fe_*` F/D outputs (its input ports are `fe_instr_i`/`fe_pc_i`/`fe_valid_i` — pc/instr/valid only; `is_compressed` is derived locally from `fe_instr_i[1:0]`) and produces the D/E control word (`de_o`, `de_t`) latched into a D/E register. **Expand-then-decode-uniformly**: a 16-bit RVC instr is turned into its 32-bit RV32I equivalent by the local `c_expand()` function, then the same uniform decoder decodes the 32-bit word (native or expanded); M has no compressed forms. A **hold buffer** stashes the upper half of a word when the low half is compressed (decoded next cycle, PC = word_pc+2). Reads rs1/rs2 from `reg_file` asynchronously (addresses out, data back same cycle, latched into `de_o`). `stall_o` feeds fetch's `stall_i` (wired, currently INERT — see below). Deferred opcodes (`OPC_MISC_MEM`/`OPC_SYSTEM`/atomics/unknown) decode to `illegal=1`. See **Decode stage behaviour** below.
- **`src/rtl/core/reg_file.sv`** — 32×32 register file, **inferred as flops** (1024 FF + 2 combinational read muxes — not BRAM, no async-read BSRAM; not LUTRAM). **2 async read ports + 1 sync write port** (posedge). Explicit `x0` read-zero mux; writes to `x0` ignored. **All regs reset to 0** for Verilator determinism. Ports: `clk_i`/`rstn_i`, `rs1_addr_i`/`rs2_addr_i` → `rs1_data_o`/`rs2_data_o`, `wr_addr_i`/`wr_data_i`/`wr_en_i`. The write port has no producer yet (no writeback) → tied `wr_en=0` in the CPU top, so reads return 0 until a writeback stage exists.
- **`src/rtl/core/rv32imac_zicsr_zifencei.sv`** — CPU RTL top. Instantiates `fetch_stage` + `reg_file` + `decode_stage`, plus **two `axi4_lite_master_bridge`** instances: `u_imem_bridge` (driven by `fetch_stage`'s `imem_req_o`/`imem_rsp_i`) and `u_peri_bridge` (request tied inert — `wvalid=0` — LSU not yet implemented). The native interface is direction-split, so there are **no `req_ready` wires** — `wready` lives in `mem_rsp_t`. `peri_rsp` is sunk to a dummy net (`unused_peri_rsp`) for the future LSU. Exits two AXI4-Lite masters. Debug taps: `fe_*` (fetch) and `de_*` (decode) — **pc/instr/valid only per stage** (the full D/E control stays inside as `de_w`; it is no longer unpacked into flat ports). `fetch_stage.stall_i` ← `decode_stage.stall_o` (replaces the old `1'b0`). `fe_pc_dbg_o[3:0]` brought out as the LED tap.
- **`src/rtl/core/top_module.sv`** — board top. **Clock tree:** an `rPLL` primitive (FCLKIN=27, IDIV_SEL=5, FBDIV_SEL=21, ODIV_SEL=8) generates `clk_core` = 27×22/6 = **99 MHz** from the 27 MHz `clk_i`; a 2-FF reset synchronizer produces `rstn_core` (async-assert on `rstn_i` or `!pll_lock`, sync-deassert on `clk_core`). **Single clock domain** — the CPU, both AXI4-Lite buses (`aclk`), and the `axi4_lite_ram` slave all run on `clk_core`/`rstn_core`; `clk_i` only feeds the rPLL and `rstn_i` only feeds the synchronizer, so there is **no clock-domain crossing**. Wires CPU `imem_axi` → `axi4_lite_ram` slave on `axi_bus_imem`; routes `peri_axi` to `axi_bus_peri` with the slave side tied off (all `*ready=0`/`*valid=0`) so a future peripheral drops in without rewiring. The CPU's `fe_*`/`de_*` debug taps (pc/instr/valid) are left unconnected here except `fe_pc_dbg_o[3:0]` → LEDs (swept by synthesis otherwise); the sim wrapper (`sim/sim_top.sv`) consumes them. `led_o` = `fe_pc_dbg_o[3:0]`.
- **`src/rtl/bus/axi4_lite_if.sv`** — SystemVerilog interface (32-bit addr/data) with `master`, `slave`, and `trunk` modports. `aclk`/`aresetn` are driven into the trunk from the board top.
- **`src/rtl/bus/axi4_lite_master_bridge.sv`** — native `mem_req_t`/`mem_rsp_t` (direction-split) → AXI4-Lite AR/AW/W + R/B. Single shared FSM (`S_IDLE`/`S_RD_WAIT`/`S_WR_ADDR`/`S_WR_DATA`/`S_WR_WAIT`) — **single outstanding overall** (read OR write, not both). `rsp_o.wready = (state_q == S_IDLE)` is the launch handshake from the producer's side. **Read path**: in `S_RD_WAIT` the master's `req_i.rready` is forwarded straight to `axi.rready`, so the AXI slave holds `rvalid`/`rdata` until the master can accept; `rsp_o.rvalid = r_hs` the cycle data is consumed. For writes, AW+W launch in lock-step; on `b_hs` → `S_IDLE`. **Write retirement is not signalled back** (no `bvalid` in `mem_rsp_t` yet — TODO LSU); `bready` held high.
- **`src/rtl/utils/axi4_lite_ram.sv`** — AXI4-Lite slave single-beat RAM, **protocol-compliant** (verified by `sim/ram_tb/`). `(* ram_style = "block" *)` (infers a simple dual-port BSRAM on Gowin: one write port + one read port, single clock). Params: `ADDR_W` (byte-addressed depth = 2^ADDR_W bytes) and optional `INIT_FILE` for `$readmemh`. **Write path**: AW and W are independent channels and may arrive in either order (each captured into its own holding register, `aw_seen_q`/`w_seen_q`); the transaction completes the cycle both are seen, the BSRAM write fires, and **BVALID is registered and held high until the B handshake** (`bvalid && bready`) — this is the AXI "VALID stays asserted until the handshake" rule and the key compliance point (a previous version had a combinational one-cycle BVALID that only worked because the master bridge holds `bready` high; that was non-compliant). **Single outstanding**: while BVALID is pending, `awready`/`wready` are low. **Read path**: 1-cycle registered latency; `arready` depends only on registers + `rready` (never `arvalid`); RVALID registered and held until `rready`. READY outputs never depend on the same-channel VALID. Synchronous active-low reset (matches the bus layer; memory contents are not reset). Byte-strobed writes use the BSRAM byte enables. Wired as the `axi_bus_imem` slave.

### Fetch stage behaviour (current)

Single-outstanding **overlap-prefetch**. No `state_t` enum — the FSM is a set of flags (`busy_q`/`req_pc_q`/`flushed_q`) plus the F/D register (`fe_*_q`). Handshakes with the on-die bridge: launch = `imem_req_o.wvalid && imem_rsp_i.wready`; capture = `imem_rsp_i.rvalid && imem_req_o.rready`.

- `pc_q`: **next fetch address** — runs ahead of decode. Resets to `boot_addr_i`. On launch it advances to `pc_q + 4`; on redirect it is overwritten with the target. (Note: fetch always reads 32-bit words and advances by 4 — see Compressed below.)
- `req_pc_q`: address of the **in-flight** fetch. Stamped onto the F/D register at capture, so `fe_pc_o` is the **exact** address of the delivered instruction (not the already-advanced `pc_q`).
- `busy_q`: a fetch is in flight (at most one — single outstanding). `imem_req_o.wvalid = !busy_q && !branch_valid_i` (issue only when idle and not redirecting).
- `imem_req_o.rready = !fe_valid_q || flushed_q` — accept read data when the F/D register has room, **or** drain a flushed (redirected) response to free the bridge. This depends **only on registers**, never on `rvalid`, so there is no combinational loop through the bridge's `axi.rready` forwarding.
- **Overlap-prefetch**: on capture of fetch K (busy→0 next cycle), the next fetch K+1 is launched the very next cycle (the bridge is back in `S_IDLE`), while decode consumes K from the F/D register. Only one transaction is ever in flight (K+1; K already sits in F/D). If decode is slower than memory and K+1's response lands while F/D is still full, `rready` stays low and the bridge/AXI slave hold `rvalid`/`rdata` until decode frees F/D — **no skid buffer needed** (single outstanding ⇒ nothing queues behind the waiting response). Steady-state ~2 cycles/instruction (the bridge round-trip floor: 1 issue + 1 response).
- `fe_valid_o`: **held level** — high from a fresh capture until decode consumes it (`fe_valid_q && !stall_i` → `fe_valid_d=0`), or a redirect kills it. Mutually exclusive with capture (capture needs F/D empty; consume needs F/D full).
- **Redirect** (`branch_valid_i`, highest priority): kills stale F/D (`fe_valid_d=0`) and marks the in-flight fetch `flushed_q=1` so its response is drained and discarded; sets `pc_q` to the target. `wvalid` is gated by `!branch_valid_i` so no fetch of the old `pc_q` issues during the redirect cycle. If the flushed response lands the same cycle as the redirect, it is drained immediately.
- **Compressed (C)**: NOT handled here — always fetches 32 bits, advances by 4; decode derives `is_compressed = (fe_instr[1:0] != 2'b11)` itself (it is not a fetch port) and owns RVC expansion (a compressed instr in the low half of a word ⇒ the next instr is the upper half of the same word, handled in decode).
- **stall_i**: downstream back-pressure (driven by decode's `stall_o`). While high the F/D register is held (not consumed); prefetch still issues up to 1 ahead (bounded by single outstanding) and is discarded on redirect.

### Decode stage behaviour (current)

**Expand-then-decode-uniformly** (phase 1: RV32I + M + C). `c_expand(16-bit) → 32-bit RV32I equivalent`; the same uniform decoder then consumes the 32-bit word whether it came native (`fe_instr`) or from expansion. M has no compressed forms, so only RV32I compressed instrs are expanded. `c_expand` returns `32'h0` for illegal/unsupported encodings (opcode `0000000` decodes to `illegal=1`).

- **Hold buffer** (`hold_q`/`hold_word_q`/`hold_pc_q`): when a word's low half is compressed, decode it this cycle and stash the upper half for next cycle (PC = `fe_pc + 2`). Source priority: hold buffer > fresh F/D. `is_compressed` is **recomputed** from `hold_word_q[1:0]` for the upper half (do NOT trust the word-level `fe_is_compressed`, which describes the whole word).
- **Uniform decoder**: one `always_comb` extracts fields + immediates (I/S/B/U/J, sign-extended) and emits control per opcode. `rs1/rs2_addr` (forced to `x0` for instrs that don't use them) drive the reg-file async reads; `rs1/rs2_data` are latched into `de_o`. `de_o.instr` = the 32-bit word decode treated. `illegal` defaults to 1; recognised opcodes clear it; `spanning_illegal` or `dec_illegal` squash `reg_write`/`mem_*`/`branch_type` and set `illegal = decoded_valid`.
- **RVC spanning (phase-1 simplification)**: fetch delivers 32-bit words at 4-byte boundaries; decode derives `is_compressed` from `fe_instr[1:0]`. A 32-bit instr is assumed 4-byte aligned; the spanning case (low half compressed AND upper half `[1:0]==2'b11`) is **undefined → `illegal=1`** (documented limitation). This is the only known RVC limitation today.
- **`stall_o = (hold_q && fe_valid_i) || stall_i`** — register-only (no comb loop through fetch). It is **wired but currently INERT**: `hold_q` and `fe_valid_i` are mutually exclusive by construction (hold raises the cycle `fe_valid` falls), so `stall_o` is 0 in steady state. Kept as forward-compat for a future hazard unit / zero-wait-state I-path; no word is lost or double-decoded (priority mux: hold wins).
- **Deferred opcodes** (`illegal=1`, not executed this phase): `OPC_MISC_MEM` (fence/fence.i — Zifencei), `OPC_SYSTEM` (CSR/ecall/ebreak — Zicsr), atomics, any unknown opcode. JAL/JALR/c.j/c.jr/c.jal/c.jalr still produce their control (`branch_type`/`reg_write`/`wb_src`) even without execute — it rides the D/E register to the debug taps.
- **Pitfall — `c.addi` vs `c.li`**: `c.addi rd,imm` → `addi rd,rd,imm` (rs1 = rd); `c.li rd,imm` → `addi rd,x0,imm` (rs1 = x0). Don't confuse them. Related: `c.addi16sp` (rd==x2) vs `c.lui` (else) share quad1 funct3=011; `c.addi4spn` with nzuimm==0 is illegal; `c.mv`/`c.add` (quad2 funct3=100) selected by `c[12]` (0=mv rs1=x0, 1=add rs1=rd), `rd==0` HINT → illegal; `c.jr`/`c.jalr`/`c.ebreak` selected by rs2==0.

### Open work / things future instances should know

- **Execute stage is the next step** — `decode_stage`'s D/E output (`de_o`) is connected to debug taps only (`de_*_dbg_o`, all `()` at the board top). The planned next stage is an execute stage that consumes `de_t` (ALU + branch resolve + M-ext) and writes back to `reg_file` (whose write port is currently tied `wr_en=0`). Reserve the `ex_*` sigil for the E/M register taps.
- The **redirect path** (`branch_valid_i`/`branch_addr_i` → fetch PC redirect + in-flight flush) and **stall path** (`stall_i` from a hazard unit) are **implemented in the fetch and decode FSMs** but tied off in the CPU top (`branch_valid_i=0`, `decode.stall_i=0`; `decode.stall_o` is wired to fetch but inert). Reserve these names when adding execute/branch and hazard modules.
- Decode **defers** A (LSU), Zicsr (CSR file), Zifencei (fence) — their opcodes decode to `illegal=1`. CSR/ecall/ebreak (`OPC_SYSTEM`) and fence (`OPC_MISC_MEM`) are the notable ones to wire when those land.
- **RVC spanning limitation** (phase 1): a 32-bit instr spanning the *word* boundary (low half compressed AND upper half `[1:0]==2'b11`) is `illegal=1` by design. If fetch is ever widened (e.g. 64-bit fetch to hide the 2-cycle memory latency), the spanning case generalises to the new fetch width — extend the same "spanning → illegal" simplification rather than adding stitch logic, at least initially.
- The CPU exposes `peri_axi` (inert, no LSU). When the LSU lands it should drive the internal `peri_req`; `u_peri_bridge` will translate to AW/W on `peri_axi` with **no board-top changes**. `mem_rsp_t` still needs `bvalid` (write-ack) added for the LSU.
- `cmd.do` sets `global_freq 100.000` MHz and currently applies **no SDC** — the Tang Nano 20k runs at 27 MHz; update both before relying on timing closure.
- `rv32imac_Zicsr_Zifencei.gprj.user` is per-machine IDE state (gitignored) — don't rely on it; the canonical file list is the `.gprj`. The `.gprj` now lists `reg_file.sv` + `decode_stage.sv` (after `fetch_stage.sv`).