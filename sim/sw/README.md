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
- `main.c`     — register-only `fib` example.
- `link.ld`    — link script: everything at 0x0 (the CPU boot address),
  64 KiB; `.text.init` first.
- `bin2hex.py` — raw little-endian `.bin` → `$readmemh` word file
  (`@00000000` + one 8-hex-digit 32-bit word per line).
- `Makefile`   — build rules (`-march=rv32imac -mabi=ilp32 -nostdlib
  -ffreestanding -O2 -Wl,--no-relax`).

Build artefacts (`build/`) are gitignored.

## Current-core caveat (DRAFT)

The core has **no LSU** and **no forwarding / hazard unit** yet, and the
peripheral (data) bus has no slave. So memory accesses silently no-op
(stores drop, loads read 0) and RAW-dependent sequences read stale
values. Register-only programs decode and execute correctly (odd-half
RVC branch targets are handled); programs that need the stack or globals
are a **sequencing/decode smoke test, not a correct-result check**,
until the LSU + hazard unit + a data-memory slave land. Add a writeback
tap to observe results.