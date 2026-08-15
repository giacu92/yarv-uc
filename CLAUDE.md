# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

A RV32IMAC + Zicsr + Zifencei RISC-V core targeting a **Gowin GW2AR-18C** FPGA (part `GW2AR-LV18QN88C8/I7`, QFN88 package). The core is a work-in-progress pipeline; only the instruction fetch stage is implemented so far. The CPU exits **two AXI4-Lite masters** (`imem_axi`, `peri_axi`). The conversion from the pipeline's native `mem_req_t` / `mem_rsp_t` to AXI4-Lite is done inside the CPU (one `axi4_lite_master_bridge` per master port), so the rest of the system sees the CPU as a plain AXI4-Lite master.

- Top module (board-level / IDE): `top_module` (file `src/rtl/core/top_module.sv`)
- CPU top (RTL-level): `rv32imac_zicsr_zifencei` (file `src/rtl/core/rv32imac_zicsr_zifencei.sv`) — instantiates pipeline stages AND one `axi4_lite_master_bridge` per master port; exits two AXI4-Lite masters.
- Project file (Gowin IDE): `rv32imac_Zicsr_Zifencei.gprj`
- Process / synthesis config: `impl/rv32imac_Zicsr_Zifencei_process_config.json`
- Synthesized netlist / reports: `impl/gwsynthesis/`
- PnR bitstream / reports: `impl/pnr/`

## Build flow (Gowin EDA)

This project is built with the **Gowin FPGA Designer** toolchain, not a generic open-source flow. There are no Makefile / shell scripts in the repo. The tool is invoked through the IDE (project `.gprj`) or via Tcl / `gw_sh`.

The Gowin IDE / Tcl are installed on the build host at:

- IDE binary: `~/gowin_ide/IDE/bin/gw_ide`
- Headless shell: `~/gowin_ide/IDE/bin/gw_sh` (use with `QT_QPA_PLATFORM=offscreen` over SSH because the GUI needs X11)
- Launch helper: `~/gowin_ide/run_ide.sh`

From the IDE:
1. Open `rv32imac_Zicsr_Zifencei.gprj` in Gowin FPGA Designer.
2. **Synthesize** → produces `impl/gwsynthesis/rv32imac_Zicsr_Zifencei.vg`.
3. **Place & Route** → runs `impl/pnr/cmd.do`, producing `impl/pnr/rv32imac_Zicsr_Zifencei.fs` and `.bin`.
4. Program the device with `impl/pnr/rv32imac_Zicsr_Zifencei.fs` (or `.bin`).

From the command line (Gowin shell) — the CLI form `gw_sh -synth -f <gprj>` is fragile: it silently exits without producing any output if the target `.vg`/`.log` files already exist (e.g. from a previous run). **Always use a Tcl script** that calls `open_project` + `run_synthesis`:

```bash
# /tmp/synth.tcl  (or commit one under impl/pnr/)
#   open_project /home/giacomo/gowin_proj/rv32imac_Zicsr_Zifencei/rv32imac_Zicsr_Zifencei.gprj
#   set_option -top_module top_module
#   run_synthesis

QT_QPA_PLATFORM=offscreen gw_sh /tmp/synth.tcl

# Place & Route (uses impl/pnr/cmd.do)
gw_sh -pnr -do impl/pnr/cmd.do
```

The synthesizer writes the run log to `impl/gwsynthesis/rv32imac_Zicsr_Zifencei.log` — **read that file for errors and warnings**, `gw_sh` itself prints only a banner to stdout.

PnR is driven by `impl/pnr/cmd.do` with constraints from `impl/pnr/device.cfg`. The script targets the GW2AR-18C part, runs `-bit -tr -ph -timing` and converts SDP32/36 → SDP16/18 BSRAMs.

Pin assignment (`impl/pnr/rv32imac_Zicsr_Zifencei.cst`):
- `clk_i` → PIN4 (27 MHz onboard oscillator on Tang Nano 20k)
- `led_o[0..3]` → PIN15, PIN17, PIN18, PIN19 (onboard LEDs)
- `rstn_i` is **not** mapped — rely on the FPGA's internal POR until the S1 user-key pin on the GW2AR-18C QFN88 is confirmed against the board schematic.

Timing (`impl/pnr/rv32imac_Zicsr_Zifencei.sdc`):
- Primary clock `clk27` at 27 MHz on `clk_i` (period 37.037 ns).
- `rstn_i` and `led_o[*]` marked as false paths.

There are **no unit tests, no simulation harness, and no lint config** in the repo. Verification (if needed) is done outside this tree.

## Architecture

The core is being built bottom-up — most pipeline stages past fetch are not yet present. The current RTL is intentionally minimal:

- **`src/rtl/pkg/rv32_pkg.sv`** — package with `XLEN = 32`, `STRB_WIDTH`, `AXI4_LEN`, and the native memory structs `mem_req_t` (we/addr/wdata/wstrb) and `mem_rsp_t` (valid/rdata). Every RTL file does `import rv32_pkg::*;`.
- **`src/rtl/core/fetch_stage.sv`** — the only implemented pipeline stage. Owns the PC, the F/D pipeline register (`fd_pc_o`/`fd_instr_o`/`fd_valid_o`/`fd_is_compressed_o`), and exposes a **native instruction-memory interface** (`imem_req_o` / `imem_rsp_i` as `mem_req_t`/`mem_rsp_t`) plus `next_pc_o`. **No bus protocol lives here** — the fetch stage just publishes a request every cycle; the on-die AXI4-Lite bridge inside the CPU converts it into AR/R and feeds the response back through `imem_rsp_i`. Forward-compat inputs `stall_i`, `branch_valid_i`, `branch_addr_i` are present on the port but tied off in the CPU top today.
- **`src/rtl/core/rv32imac_zicsr_zifencei.sv`** — CPU RTL top. Instantiates pipeline stages AND **two `axi4_lite_master_bridge` instances** — one for `imem_axi` (driven by `fetch_stage` today), one for `peri_axi` (LSU side, request tied off today). Exits two AXI4-Lite masters: `imem_axi` (toward instruction/data memory) and `peri_axi` (toward peripherals, unused for now but routed at the boundary so the board top can drop in slaves without re-touching the CPU). `fd_pc_dbg_o[3:0]` is brought out as a debug tap.
- **`src/rtl/core/top_module.sv`** — board-level top (set as `TopModule` in `process_config.json`). Instantiates `rv32imac_zicsr_zifencei` only — no bus glue, no bridges. Wires the CPU's `imem_axi` to an `axi4_lite_ram` slave on `axi_bus_imem`, and the CPU's `peri_axi` to `axi_bus_peri` (trunk left open on the slave side and tied off so future peripherals drop in without rewiring). Exposes `clk_i`, `rstn_i`, and a 4-bit `led_o` wired to the CPU's `fd_pc_dbg_o[3:0]`.
- **`src/rtl/bus/axi4_lite_if.sv`** — local `axi4_lite_if` interface (32-bit data/addr) with `master`, `slave`, and `trunk` modports. Used by the CPU's AXI4-Lite master ports and by the board top to wire slaves.
- **`src/rtl/bus/axi4_lite_master_bridge.sv`** — generic AXI4-Lite master bridge that turns a native `mem_req_t` / `mem_rsp_t` into AR/AW/W + R/B. Per-channel FSM (read / write independent), single outstanding beat per channel. Instantiated twice **inside** the CPU — once for `imem_axi`, once for `peri_axi`.
- **`src/rtl/utils/axi4_lite_ram.sv`** — AXI4-Lite slave single-beat RAM with `(* ram_style = "block" *)` storage (infers BSRAM on Gowin). Parameterised `ADDR_W` (byte-addressed depth = 2^ADDR_W bytes) and optional `INIT_FILE` for `$readmemh`. Read latency 1 cycle; bvalid asserted the cycle AW and W both hand-shake. Byte-strobed writes. Wired as the slave on `axi_bus_imem` by the board top.

### Fetch stage behaviour (current)

- `pc_q`: the address of the current fetch (registered).
- `pc_d = pc_q + 4` by default; a redirect overrides it via `next_pc_d`.
- `imem_req_o.valid = 1` every cycle — continuous fetching. The external bridge is responsible for back-pressure: if it cannot accept a request this cycle, it must assert `stall_i` so the fetch stage holds the PC and the request stays pending at the same address.
- When `imem_rsp_i.valid` arrives (one cycle of high), `fd_instr_o` / `fd_pc_o` / `fd_is_compressed_o` / `fd_valid_o` are latched into the F/D pipeline register and held until the next response.

### Open work / things future instances should know

- The F/D register signals from `fetch_stage` are connected to `()` in the CPU top — the **decode stage is missing** and is the next obvious step.
- The "redirect" path (branch/jal/jalr → PC redirect) and "stall" path (hazard unit) are present in `fetch_stage`'s port list but tied off in the CPU top. Reserve these names when adding the execute/branch and hazard modules.
- `rv32_pkg::mem_req_t` has a `valid` field. The fetch stage asserts it continuously; the on-die `axi4_lite_master_bridge u_imem_bridge` consumes the request when it can launch the AXI4-Lite transaction.
- The CPU exposes `peri_axi` (currently inert, no LSU). When the LSU lands it will drive the internal `peri_req`; the on-die `axi4_lite_master_bridge u_peri_bridge` will translate it into AW/W on `peri_axi` without any board-top changes.
- `cmd.do` uses `global_freq 100.000` MHz; the Tang Nano 20k is rated much lower. Update before relying on timing closure.
