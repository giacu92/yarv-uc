# Simulation (Verilator)

Functional simulation of the implemented pipeline (fetch + decode +
execute + LSU + Zicsr CSR file + trap/exception/interrupt unit). The
default **Harvard** build wires the CPU to a native read-only I-mem
(`native_ram`, `+IINIT`) and a native byte-strobed D-mem (`native_ram`,
`+DINIT`); the AXI4-Lite peripheral bus carries the `msip_peri` MMIO
slave (machine software interrupt) — the only peri slave for now; an
`axi4_lite_uart.sv` slave exists on disk but is not yet wired in (see
the root `README.md` Roadmap). The legacy **von-Neumann** build
(`VON_NEUMANN=1`) keeps the `mem_arbiter` + `axi4_lite_xbar` + single
AXI4-Lite RAM (`+INIT`) topology. The board top's wiring is replicated
in `sim_top.sv` so the memories can be preloaded and the CPU's
per-stage debug taps can be logged.

This harness is **not** part of the synthesis file list.

## One-time setup

Install Verilator (Debian/Ubuntu):

```
sudo apt-get install -y verilator
```

## Build & run

```
cd sim
make run                                          # Harvard: imem.hex/dmem.hex oracle
make run RUN_ARGS="+IINIT=sw/build/imem.hex +DINIT=sw/build/dmem.hex"  # C program
make run VON_NEUMANN=1 RUN_ARGS="+INIT=program.hex"  # legacy von-Neumann build
# or, from the repo root:
make sw-run       # build the C program (sim/sw) + run the Harvard sim loading it
```

`VON_NEUMANN=1` selects the legacy single-AXI-master topology; the
default (unset) is Harvard.

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

The Harvard build loads two `$readmemh` preloads (one 32-bit hex word per
line; the word value IS the instruction/data word):

- `sim/imem.hex` — instruction image (I-mem, read-only).
- `sim/dmem.hex` — data image (D-mem, byte-strobed). Empty placeholder
  for the oracle, which writes its own data at runtime via stores.

The images are **plusarg-selected**: `+IINIT=<path>` / `+DINIT=<path>`
override the defaults, so a C-compiled image pair can be loaded without
clobbering the oracle. The legacy von-Neumann build uses a single
`+INIT=<path>` (default `program.hex`). To compile C → images, use the
`sim/sw/` flow (see `sim/sw/README.md`).

## Native RAM compliance test (`hw/native_mem_tb/`)

A second, independent harness that does **not** use the CPU — it
instantiates `native_ram` alone (a read/write D-mem and a read-only
I-mem) and drives it as a native `mem_req_t`/`mem_rsp_t` master from C++
(`native_mem_tb.cpp` is a small cycle-accurate BFM). It verifies the
native slave's protocol compliance in isolation: RVALID registered and
**held until RREADY** (not a one-cycle pulse — the key fix vs a naive
read), byte-strobed partial writes, back-to-back writes, single
outstanding (WREADY low while an unread read response is held), posted
store commits at the launch handshake, and read-only ignoring writes.

```
cd sim/hw/native_mem_tb && make run   # prints "N checks, 0 failures" on success
```

## AXI4-Lite RAM compliance test (`hw/ram_tb/`)

A third, independent harness (no CPU) that instantiates `axi4_lite_ram`
alone and drives it as an AXI4-Lite master from C++ (`ram_tb.cpp`). It
verifies the AXI RAM's protocol compliance in isolation
(registered/held BVALID + RVALID, AW-first / W-first orderings,
byte-strobed partial writes, back-to-back writes, single outstanding).
`axi4_lite_ram` is now peri-side only in the Harvard build; `ram_tb`
still covers it.

```
cd sim/hw/ram_tb && make run     # prints "N checks, 0 failures" on success
```

## Co-sim vs Spike (`cosim/quicksort/`)

Runs the same C-built ELF on Spike (upstream `riscv-isa-sim`, built locally
once via `build_spike.sh`, run with `--log-commits`) and on the Verilator
RTL sim, then `cosim_diff.py` diffs per-retire architectural effects (pc +
register write). Spike is the golden ISA reference; Zilx is already
implemented upstream (no patch). The RTL sim writes a per-retire trace to
`RTL_TRACE` (`sim_main.cpp`); the diff driver skips Spike's boot-ROM stub
retires and parks both sides at the halt self-loop.

Harvard co-sim needs `.data` at a non-zero VMA: Spike is a single
unified address space, so `.text`@0 and `.data`@0 would clobber each
other (the second LOAD segment overwrites the first at vaddr 0). The
linker places `.data` at DMEM 0x2000 (`sim/sw/link.ld`), and the cosim
`SPIKE_MEM` (`0x0:0x1000` for code, `0x2000:0xE000` for data+stack)
matches that split — so Spike's unified space and the RTL's split
I-mem/D-mem spaces both see the same absolute addresses.

```
make cosim     # build sw + Spike, run both, diff -> "PASS -- matched N retires"
```

The Spike source tree, build, install, and per-run logs are gitignored;
only the harness is committed: `cosim_diff.py` + `build_spike.sh` at
`cosim/` (shared with the illegal-trap co-sim), and the `Makefile` at
`cosim/quicksort/`.

## Trap oracle (`sw_trap/`)

A standalone M-mode trap-exercise program (`trap_test.S`, built
`-march=rv32imac_zicsr_zifencei` so the toolchain emits csr/mret/wfi):
sets `mtvec` (direct), enables `mie.MSIE` + `mstatus.MIE`, and runs four
tests — ecall, load-misaligned, illegal instruction, and MSIP+WFI. The
handler (keyed on `mcause`) advances `mepc`+4 for sync traps / clears
MSIP + sets `mepc`=wfi+4 for the interrupt, leaving distinct D-mem
markers; `main` self-checks them and writes `0x600D` at D-mem 0x2000
(pass) or `0xBAD` (probe word 0x800). Run from `sim/`:

```
cd sw_trap && make                                      # -> build/imem.hex + build/dmem.hex
cd .. && make run RUN_ARGS="+IINIT=sw_trap/build/imem.hex +DINIT=sw_trap/build/dmem.hex"
```

## Illegal-trap co-sim (`cosim/ecall/`)

The Spike co-sim of a synchronous trap: a minimal illegal-instruction
program (`ecall_test.S`, `.word 0x0000007f`) run on Spike + RTL and
diffed with the shared `cosim_diff.py`. The faulting instruction is not
retired in either model. `ecall` itself is **not** Spike-comparable
(Spike hijacks an M-mode ecall as the htif host-call exit; MSIP has no
Spike slave at 0x1000_0000), so the ecall / MSIP+WFI paths are covered
only by the standalone oracle above.

```
cd cosim/ecall && make cosim   # -> "PASS -- matched 17 retires" (run from sim/)
```

## Files

- `sim_top.sv`    — sim wrapper (CPU + native I/D-mem or AXI RAM +
  `msip_peri` MMIO slave on the peri bus + `mem_probe` generate block
  exposing a window of the data RAM to the VCD). Ports only
  `clk_i`/`rstn_i`/`led_o`; CPU taps stay internal, probed via the
  Verilator hierarchy.
- `sim_main.cpp`  — Verilator C++ harness (clk/rst, trace, three logs
  incl. writeback values, stall breakdown, park/`MAX_CYC` stop).
- `imem.hex`/`dmem.hex` — Harvard oracle preload (code / data).
- `program.hex`   — von-Neumann oracle preload (RV32I/RVC/M/CSR).
- `Makefile`      — build/run rules (`RUN_ARGS` forwards plusargs;
  `VON_NEUMANN=1` selects the legacy build).
- `hw/native_mem_tb/` — native RAM compliance test.
- `hw/ram_tb/`       — AXI4-Lite RAM compliance test.
- `cosim/`           — shared co-sim assets: `cosim_diff.py` +
  `build_spike.sh` + the local Spike build/install.
- `cosim/quicksort/` — RTL vs Spike golden ISA ref co-sim (see
  "Co-sim vs Spike").
- `cosim/ecall/`     — Spike co-sim of an illegal-instruction sync trap
  (see "Illegal-trap co-sim").
- `sw/`           — C → imem.hex + dmem.hex flow (see `sw/README.md`).
- `sw_trap/`      — standalone M-mode trap-exercise program
  (ecall/misaligned/illegal/MSIP+WFI, self-checking — see "Trap oracle").

Build artefacts (`obj_dir/`, `sw/build/`, `cosim/ecall/build/`,
`cosim/quicksort/*.log`, `*.vcd`, `*.log`) are gitignored.