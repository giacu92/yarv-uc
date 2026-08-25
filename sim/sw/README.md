# C → `imem.hex` + `dmem.hex` (sim/sw, Harvard)

Compiles a small bare-metal C program into the pair of `$readmemh` word
files the Harvard sim loads — `build/imem.hex` (code → I-mem) and
`build/dmem.hex` (data → D-mem) — so the sim can run real RISC-V code
instead of the hand-crafted `sim/imem.hex`/`sim/dmem.hex` oracle.

## Toolchain

Any rv32-capable toolchain works; override `RISCV_PREFIX` to pick one.
The esp toolchain named below is gone from the current machine, so in
practice every build here passes
`RISCV_PREFIX=/home/giacomo/_toolchains/riscv32-ilp32d--glibc--stable-2024.05-1/bin/riscv32-buildroot-linux-gnu`,
which is why the Makefiles carry `-fno-pie -no-pie -Wl,-N` (see below).
The default in the `Makefile` is the bare-metal
`riscv32-esp-elf-gcc` 14.2.0 (PlatformIO/esphome cache at
`~/esphome/config/.esphome/platformio/packages/toolchain-riscv32-esp/bin`),
which supports `-march=rv32imac -mabi=ilp32` and ships full binutils.

A **linux/glibc** toolchain also works, e.g.

```
make RISCV_PREFIX=/home/giacomo/_toolchains/riscv32-ilp32d--glibc--stable-2024.05-1/bin/riscv32-buildroot-linux-gnu
```

but it needs two flags that every firmware `Makefile` in this tree now
carries, because both of its defaults are wrong for a freestanding
Harvard image:

- **`-fno-pie`** — that toolchain defaults to PIE, so `gas` expands
  `la sym` into a GOT load (`auipc` + `lw` from `.got`) and gcc emits
  PC-relative data addressing. Neither survives here: there is no GOT in
  a flat two-image layout, and `link.ld` requires medlow **absolute**
  addressing (`lui` + `addi`) so that a data address computed inside
  `.text` resolves in D-mem, not I-mem. Without it `sim/sw_trap` loaded
  `mtvec` from an uninitialised `.got` word and reboot-looped.
- **`-no-pie -Wl,-N`** — its `ld` emits a `PT_PHDR` segment that the flat
  `MEMORY` layout does not cover, failing the link with "PHDR segment not
  covered by LOAD segment". `-N` (omagic) drops it. Harmless on a
  bare-metal toolchain.

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
  (`0x4000`, top of the 16 KiB D-mem — stack grows down), `call main`,
  halt loop. `sp` has to be a real address: the D-mem decodes only
  `ADDR_W` bits, so a pointer above the top aliases silently back into
  the data it is meant to sit clear of.
- `main.c`     — recursive quicksort over a 256-word `.data` array
  (Lomuto partition, `volatile` to defeat constant-folding); verifies
  ascending order and returns `0x600D` in `a0` (sorted) or `0x00000BAD`
  (broken). `partition()` hand-encodes a Zilx scaled indexed word load
  (`lxs.w`) via `.insn`, since `-march=rv32imac` has no Zilx mnemonics.
  The array is filled by a deterministic LCG rather than a literal
  initialiser: the same sequence on Spike and on the RTL keeps the
  co-sim comparing like for like, and pseudo-random input keeps the
  recursion near log2(N) deep instead of the N frames an already-sorted
  input would cost. It is printed before and after the sort;
  `make PRINT_ARRAY=0` compiles the printing out, which the co-sim needs
  because the first UART access is where Spike stops being comparable.
- `link.ld`    — Harvard link script: two `MEMORY` regions —
  `IMEM (rx) ORIGIN = 0` (code) and `DMEM (rwx) ORIGIN = 0x2000` (data),
  16 KiB and 8 KiB — what the device actually holds (46 BSRAM blocks =
  828 Kb, so two 64 KiB memories could not both exist). Small-data
  sections are collected into the same output sections
  (`.srodata*`/`.sdata*`/`.sbss*`): RISC-V gcc puts anything up to
  `-msmall-data-limit` (8 bytes) there, and since the image is extracted
  with `objcopy -j .rodata -j .data`, an uncollected `.srodata` never
  reaches the D-mem hex — a 4-byte `const` then reads 0 at runtime while
  the same constant folded at compile time reads correctly. `.text.init`/`.text` go to `IMEM` (fetch port,
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
signed/unsigned) and the unscaled variant. The peripheral bus now
carries the `msip_peri` MMIO slave at peri base `0x1000_0000` (a write
of bit[0] sets/clears mip.MSIP); keep quicksort's data accesses in the
D-mem region (low addresses) — a peri access (`addr[28]` set) hits the
MSIP register at `0x1000_0000` and has no slave elsewhere, so it would
stall the LSU.