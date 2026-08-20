# C → `imem.hex` + `dmem.hex` (sim/sw, Harvard)

Compiles a small bare-metal C program into the pair of `$readmemh` word
files the Harvard sim loads — `build/imem.hex` (code → I-mem) and
`build/dmem.hex` (data → D-mem) — so the sim can run real RISC-V code
instead of the hand-crafted `sim/imem.hex`/`sim/dmem.hex` oracle.

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
make            # -> build/imem.hex + build/dmem.hex (and build/program.elf.objdump)
make show       # disassemble build/program.elf
```

From the repo root, build and run the sim loading both images:

```
make sw-run     # = make sw  +  make -C sim run RUN_ARGS="+IINIT=sw/build/imem.hex +DINIT=sw/build/dmem.hex"
```

The sim's `+IINIT=<path>` / `+DINIT=<path>` plusargs select the code and
data images (defaults `imem.hex` / `dmem.hex`); see `sim/README.md`.

## Files

- `start.S`    — freestanding entry `_start` at I-mem 0x0: set `sp`
  (`0x10000`, top of the 64 KiB D-mem — stack grows down), `call main`,
  halt loop.
- `main.c`     — recursive quicksort over an initialized `.data` array
  (Lomuto partition, `volatile` to defeat constant-folding); verifies
  ascending order and returns `0x600D` in `a0` (sorted) or `0x00000BAD`
  (broken). `partition()` hand-encodes a Zilx scaled indexed word load
  (`lxs.w`) via `.insn`, since `-march=rv32imac` has no Zilx mnemonics.
- `link.ld`    — Harvard link script: two `MEMORY` regions —
  `IMEM (rx) ORIGIN = 0` (code) and `DMEM (rwx) ORIGIN = 0x2000` (data),
  64 KiB and 56 KiB. `.text.init`/`.text` go to `IMEM` (fetch port,
  read-only); `.rodata`/`.data`/`.bss` go to `DMEM` (LSU port; `.bss`
  last so the objcopy image is contiguous with no NOBITS gap). `.data`
  sits at DMEM 0x2000 (not 0) so the co-sim golden model (Spike, a
  unified-address-space von-Neumann sim) can hold `.text`@0 and
  `.data`@0x2000 disjoint in its single space — at VMA 0 they would
  clobber each other. Requires `medlow` absolute addressing
  (`lui`+`addi`), not `medany` (`auipc` PC-relative) — `medany` would
  resolve data addresses against the code's I-mem base and break the
  Harvard split (hardware routes by operation, not address).
- `bin2hex.py` — raw little-endian `.bin` → `$readmemh` word file
  (`@<word>` + one 8-hex-digit 32-bit word per line). `--base <byte_addr>`
  sets the `@` word index (default 0); used for `dmem.hex` so the `.data`
  image lands at D-mem 0x2000 (`--base 0x2000` → `@0x800`), not word 0.
- `Makefile`   — build rules (`-march=rv32imac -mabi=ilp32 -nostdlib
  -ffreestanding -O2`; `-Wl,--no-relax` + `-Wl,--no-check-sections` in
  `LDFLAGS`). Two `objcopy -O binary -j ...` runs produce `imem.bin`
  (`-j .text.init -j .text`) and `dmem.bin` (`-j .rodata -j .data`),
  each fed to `bin2hex.py` → `imem.hex` + `dmem.hex`. `.bss` (NOBITS)
  contributes no file content, so it is dropped from `dmem.bin`.

Build artefacts (`build/`) are gitignored.

## Core coverage

The LSU is live (loads/stores retire through the native D-mem, or the
peri bridge for `addr[PERI_ADDR_BIT]` addresses) and the stall-on-RAW
interlock covers register and load-use hazards, so a memory-heavy
program like quicksort is a real correctness check: it exercises
fetch / decode / execute AND the data path (array loads/stores, stack
spill/fill from recursion, branches on loaded values). The
retire+writeback log (`a0` at exit) is the observable result. `.bss`
is **not** zeroed at runtime (`start.S` does not clear it), so state
that needs a known value lives in an initialized `.data` array, not in
uninitialized `.bss` globals.

`-march=rv32imac` does not emit Zilx indexed loads, so `partition()`
hand-encodes `lxs.w` via `.insn`; the hand-crafted `sim/imem.hex` /
`sim/dmem.hex` oracle covers the other Zilx sizes/signs (b/h/w,
signed/unsigned) and the unscaled variant. The peri (MMIO) bus slave
is still tied off, so keep data accesses in the D-mem region (low
addresses) — a peri access (`addr[28]` set) stalls the LSU until a
real UART/GPIO slave is dropped in.