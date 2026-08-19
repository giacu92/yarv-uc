# Simulation (Verilator)

Functional simulation of the implemented pipeline (fetch + decode +
execute + LSU + Zicsr CSR file) plus the on-die AXI4-Lite bridge,
`mem_arbiter`, `axi4_lite_xbar`, and an AXI4-Lite RAM slave. The board
top's wiring is replicated in `sim_top.sv` so the RAM can be preloaded
with a program and the CPU's per-stage debug taps can be logged.

This harness is **not** part of the synthesis file list.

## One-time setup

Install Verilator (Debian/Ubuntu):

```
sudo apt-get install -y verilator
```

## Build & run

```
cd sim
make run                                  # hand-crafted program.hex oracle
make run RUN_ARGS="+INIT=sw/build/program.hex"   # load the C program
# or, from the repo root:
make sw-run       # build the C program (sim/sw) + run the sim loading it
```

`make run` compiles `obj_dir/Vsim_top` and runs it. The harness drives
clk/rst (async active-low reset for a few cycles) and prints **three**
logs, each in its own reset+run pass so they stay aligned (each stage
lags the previous by one cycle):

- a **fetch log** — one line per F/D-valid word: `cycle / fe_pc /
  fe_instr / c` (c = compressed flag of the low half), with a
  word-advance-+4 check;
- a **decode log** — one line per D/E-valid instruction:
  `cycle / de_pc / de_instr`;
- an **execute retire + writeback log** — one line per E/M-valid
  retired op: `cycle / ex_pc / ex_instr`, plus a `wb x<n> = 0x...` line
  when the op writes a register (sampled from the internal `wb_en` /
  `wb_addr` / `wb_data` nets). This makes the RAW interlock and the
  LSU load-use path verifiable: dependent ops write the correct value,
  with a one-cycle bubble before each hazard consumer.

The CPU exports no per-stage debug ports; the harness reads the
internal taps (`fe_*`, `de_*`, `ex_*`, `wb_*`) as flat members of the
Verilator root object (built `--public-flat-rw`). An exit summary prints
`retired N instructions in M cycles`, `IPC = N/M`, and a
`stalled K/M cycles (P%)` breakdown — the RAW-hazard bubble, DIV/REM
hold, and LSU `EX_MEM_WAIT` costs per run. The run stops early on park
detection (8 consecutive identical retires — the `start.S` `1: j 1b`
self-loop); a `MAX_CYC` env var (default 4000) bounds programs that
never park (e.g. `MAX_CYC=20000 make run`). A VCD waveform
`sim_top.vcd` is also written; open it with `make wave` (needs
`gtkwave`).

### VCD / GTKWave

The VCD traces the full hierarchy (`--trace`), so decode internals are
named even though they are not CPU ports: `u_decode.opcode`,
`u_decode.alu_op`, `u_alu.alu_op_i`, `funct3/5/7`, `imm_*`, `rs1/rs2_*`,
etc. To show a numeric signal as a mnemonic in GTKWave, set its Data
Format to Bin, then `Edit → Data Format → Translate Filter File →
Enable and Select`, and point it at a translate file. Two ready files
live here:

- `gtkwave_alu_op.txt` — `ALU_ADD..ALU_LX` (applies to
  `u_decode.alu_op` / `u_alu.alu_op_i`);
- `gtkwave_opcode.txt` — `OPC_LUI..OPC_AMO` (applies to
  `u_decode.opcode`).

Re-apply a filter if you delete/re-add the signal (it does not
auto-reapply).

## Program image

`sim/program.hex` is a `$readmemh` preload (one 32-bit hex word per
line; the word value IS the instruction encoding). The image is
**plusarg-selected**: `+INIT=<path>` overrides the default
`program.hex`, so a C-compiled program can be loaded without clobbering
the hand-crafted oracle. To compile C → `program.hex`, use the
`sim/sw/` flow (see `sim/sw/README.md`).

## AXI4-Lite RAM compliance test (`ram_tb/`)

A second, independent harness that does **not** use the CPU — it
instantiates `axi4_lite_ram` alone and drives it as an AXI4-Lite master
from C++ (`ram_tb.cpp` is a small cycle-accurate BFM). It verifies the
RAM's protocol compliance in isolation (registered/held BVALID + RVALID,
AW-first / W-first orderings, byte-strobed partial writes, back-to-back
writes, single outstanding, RVALID held while RREADY delayed), which
the integrated sim — where the CPU drives the RAM through the bridge +
arbiter + crossbar — does not isolate.

```
cd sim/ram_tb && make run     # prints "N checks, 0 failures" on success
```

## Files

- `sim_top.sv`    — sim wrapper (CPU + RAM + peri tie-off + `mem_probe`
  generate block exposing a window of `u_ram.mem` to the VCD). Ports only
  `clk_i`/`rstn_i`/`led_o`; CPU taps stay internal, probed via the
  Verilator hierarchy.
- `sim_main.cpp`  — Verilator C++ harness (clk/rst, trace, three logs
  incl. writeback values, stall breakdown, park/`MAX_CYC` stop).
- `program.hex`   — `$readmemh` program preload (RV32I/RVC/M/CSR oracle).
- `Makefile`      — build/run rules (`RUN_ARGS` forwards plusargs).
- `ram_tb/`       — AXI4-Lite RAM compliance test.
- `sw/`           — C → program.hex flow (see `sw/README.md`).

Build artefacts (`obj_dir/`, `sw/build/`, `*.vcd`, `*.log`) are
gitignored.