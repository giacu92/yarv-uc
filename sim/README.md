# Simulation (Verilator)

Functional simulation of the implemented pipeline (fetch + decode +
execute) plus the on-die AXI4-Lite bridge and an AXI4-Lite RAM slave.
The board top's wiring is replicated in `sim_top.sv` so the RAM can be
preloaded with a program and the CPU's per-stage debug taps can be
logged.

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
- an **execute retire log** — one line per E/M-valid retired op:
  `cycle / ex_pc / ex_instr`.

The CPU exports only `pc / instr / valid` per stage, so the logs show
sequencing and retirement order, not control/immediates/operands/
writeback values. Add a writeback tap when values need checking. A VCD
waveform `sim_top.vcd` is also written; open it with `make wave` (needs
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
RAM's protocol compliance (registered/held BVALID + RVALID, AW-first /
W-first orderings, byte-strobed partial writes, back-to-back writes,
single outstanding, RVALID held while RREADY delayed), which the main
sim cannot (the CPU has no LSU, so it never writes to the RAM).

```
cd sim/ram_tb && make run     # prints "N checks, 0 failures" on success
```

## Files

- `sim_top.sv`    — sim wrapper (CPU + RAM + peri tie-off + debug ports).
- `sim_main.cpp`  — Verilator C++ harness (clk/rst, trace, three logs).
- `program.hex`   — `$readmemh` program preload (RV32I/RVC words).
- `Makefile`      — build/run rules (`RUN_ARGS` forwards plusargs).
- `ram_tb/`       — AXI4-Lite RAM compliance test.
- `sw/`           — C → program.hex flow (see `sw/README.md`).

Build artefacts (`obj_dir/`, `sw/build/`, `*.vcd`, `*.log`) are
gitignored.