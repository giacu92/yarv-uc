# C → `program.hex` (sim/sw)

Compiles a small bare-metal C program into the `$readmemh` word file the
sim RAM loads (`build/program.hex`), so the sim can run real RISC-V code
instead of the hand-crafted `sim/program.hex` oracle.

## Toolchain

Uses the prebuilt bare-metal RISC-V toolchain already on the machine —
**no install needed**:

- `riscv32-esp-elf-gcc` 14.2.0 (PlatformIO/esphome cache) at
  `~/esphome/config/.esphome/platformio/packages/toolchain-riscv32-esp/bin`.
- Supports `-march=rv32imac -mabi=ilp32`; has full binutils
  (`ld`, `objcopy`, `objdump`).

Override `RISCV_PREFIX` in the `Makefile` to use another rv32 toolchain.

## Build & run

```
make            # -> build/program.hex (and build/program.elf.objdump)
make show       # disassemble build/program.elf
```

From the repo root, build and run the sim loading it:

```
make sw-run     # = make sw  +  make -C sim run RUN_ARGS="+INIT=sw/build/program.hex"
```

The sim's `+INIT=<path>` plusarg selects the image (default
`program.hex`); see `sim/README.md`.

## Files

- `start.S`    — freestanding entry `_start` at 0x0: set `sp`, `call main`,
  halt loop.
- `main.c`     — recursive quicksort over an initialized `.data` array
  (Lomuto partition, `volatile` to defeat constant-folding); verifies
  ascending order and returns `0x600D` in `a0` (sorted) or `0x00000BAD`
  (broken). `partition()` hand-encodes a Zilx scaled indexed word load
  (`lxs.w`) via `.insn`, since `-march=rv32imac` has no Zilx mnemonics.
- `link.ld`    — link script: everything at 0x0 (the CPU boot address),
  64 KiB; `.text.init` first.
- `bin2hex.py` — raw little-endian `.bin` → `$readmemh` word file
  (`@00000000` + one 8-hex-digit 32-bit word per line).
- `Makefile`   — build rules (`-march=rv32imac -mabi=ilp32 -nostdlib
  -ffreestanding -O2`; `-Wl,--no-relax` in `LDFLAGS`).

Build artefacts (`build/`) are gitignored.

## Core coverage

The LSU is live (loads/stores retire through the shared imem bus) and
the stall-on-RAW interlock covers register and load-use hazards, so a
memory-heavy program like quicksort is a real correctness check: it
exercises fetch / decode / execute AND the data path (array
loads/stores, stack spill/fill from recursion, branches on loaded
values). The retire+writeback log (`a0` at exit) is the observable
result. `.bss` is **not** zeroed at runtime (`start.S` does not clear
it), so state that needs a known value lives in an initialized `.data`
array, not in uninitialized `.bss` globals.

`-march=rv32imac` does not emit Zilx indexed loads, so `partition()`
hand-encodes `lxs.w` via `.insn`; the hand-crafted `sim/program.hex`
oracle covers the other Zilx sizes/signs (b/h/w, signed/unsigned) and
the unscaled variant. The peri (MMIO) bus slave is still tied off, so
keep programs in the mem region — a peri access stalls the LSU.