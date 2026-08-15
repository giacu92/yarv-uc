# Simulation (Verilator)

Functional simulation of the implemented logic (fetch stage + on-die
AXI4-Lite bridge + AXI4-Lite RAM). The board top's wiring is replicated
in `sim_top.sv` so the RAM can be preloaded with a program.

Only the fetch stage exists yet, so instructions do **not** execute —
the sim verifies that fetch delivers the right instruction word at the
right PC, with the right `fd_is_compressed` flag, advancing by 4 each
time, and that the AXI4-Lite round-trip behaves.

## One-time setup

Install Verilator (Debian/Ubuntu):

```
sudo apt-get install -y verilator
```

## Build & run

```
cd sim
make run
```

This compiles `obj_dir/Vsim_top` and runs it. It prints one line per
instruction delivered to the F/D register:

```
cycle  pc          instr       c  note
-----  ----------  ----------  -  ----
    0  0x00000000  0x00000013  .  next_pc=0x00000004
    2  0x00000004  0x00100093  .  next_pc=0x00000008
    ...
```

A VCD waveform `sim_top.vcd` is also written; open it with
`make wave` (needs `gtkwave`).

## Files

- `sim_top.sv`    — sim wrapper (CPU + RAM + peri tie-off + debug ports).
- `sim_main.cpp`  — Verilator C++ harness (clk/rst, trace, log).
- `program.hex`   — `$readmemh` program preload (RV32I words).
- `Makefile`      — build/run rules.

Build artefacts (`obj_dir/`, `*.vcd`, `*.log`) are gitignored.