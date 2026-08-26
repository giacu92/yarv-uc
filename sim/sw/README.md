# Firmware tree (sim/sw, Harvard)

Compiles bare-metal RISC-V programs into the pair of `$readmemh` word files the
Harvard sim loads — `build/imem.hex` (code → I-mem) and `build/dmem.hex`
(data → D-mem) — so the sim can run real code instead of the hand-crafted
`sim/imem.hex`/`sim/dmem.hex` oracle.

## Layout

```
sim/sw/
  Makefile          aggregator: make -> build every program + every test
  common/           shared assets + build logic (every harness pulls from here)
    sw_build.mk      parameterised build include (toolchain, flags, rules)
    uart.h           UART MMIO register definitions
    start.S          freestanding _start: zero .bss, set sp, call main
    link.ld          Harvard link script (.text->IMEM 0, .data->DMEM 0x2000)
    bin2hex.py       .bin -> $readmemh word file
  quicksort/        benchmark program (main.c)
  coremark/         EEMBC CoreMark (eembc/ upstream sources + local port layer)
  isa/              ISA decode/fetch oracles: ifault, isa_probe, rvc_scramble
  intr/             trap + interrupt oracles: trap, timer, wfi_trap
  peri/             peripheral/integration oracles: uart_echo
```

`make -C sim/sw` builds everything. `make -C sim/sw/isa` (or `intr`/`peri`)
builds one group; `make -C sim/sw/quicksort` builds one program. Each leaf
harness Makefile is ~15 lines: it sets a few variables and `include`s
`common/sw_build.mk`, so the toolchain, flags and build rules live in exactly
one place.

`sim/sw-yarvmon/` (the board's default product firmware) stays a sibling of
this tree, not inside it — `top_module.sv` loads `sim/sw-yarvmon/build/imem.hex`.

## Toolchain

Default is the buildroot glibc toolchain `riscv32-buildroot-linux-gnu` (gcc
14.3.0) at `~/_toolchains/riscv32-ilp32d--glibc--stable-2025.08-1`. Override
`RISCV_PREFIX` to use another rv32-capable toolchain (e.g.
`riscv64-unknown-elf`, `riscv-none-elf`):

```
make RISCV_PREFIX=/opt/riscv/bin/riscv64-unknown-elf
```

A **linux/glibc** toolchain needs two flags that `common/sw_build.mk` carries,
because both of its defaults are wrong for a freestanding Harvard image:

- **`-fno-pie`** — that toolchain defaults to PIE, so `gas` expands `la sym`
  into a GOT load (`auipc` + `lw` from `.got`) and gcc emits PC-relative data
  addressing. Neither survives here: there is no GOT in a flat two-image
  layout, and `link.ld` requires medlow **absolute** addressing (`lui`+`addi`)
  so that a data address computed inside `.text` resolves in D-mem, not I-mem.
  Without it `sim/sw/intr/trap` loaded `mtvec` from an uninitialised `.got` word
  and reboot-looped.
- **`-no-pie -Wl,-N`** — its `ld` emits a `PT_PHDR` segment that the flat
  `MEMORY` layout does not cover, failing the link with "PHDR segment not
  covered by LOAD segment". `-N` (omagic) drops it. Harmless on a bare-metal
  toolchain.

## Build & run

In any harness dir:

```
make            # -> build/imem.hex + build/dmem.hex (and build/program.elf.objdump)
make show       # disassemble build/program.elf
```

From the repo root, build the quicksort program and run the sim loading it:

```
make sw-run     # = make sw  +  make -C sim run RUN_ARGS="+IINIT=sw/quicksort/build/imem.hex +DINIT=sw/quicksort/build/dmem.hex"
```

The sim's `+IINIT=<path>` / `+DINIT=<path>` plusargs select the code and data
images (defaults `imem.hex` / `dmem.hex`); see `sim/README.md`. Run a test
oracle the same way, e.g.:

```
cd sim && make run RUN_ARGS="+IINIT=sw/intr/trap/build/imem.hex +DINIT=sw/intr/trap/build/dmem.hex"
```

## Shared assets (common/)

- `start.S` — freestanding entry `_start` at I-mem 0x0: zero `.bss` from
  `__bss_start`/`__bss_end` (the section is NOBITS, so it is not in the loaded
  image, and on hardware its words come up holding power-up BSRAM contents
  while simulation reads them as zero), set `sp` (`0x4000`, top of the 16 KiB
  D-mem — the D-mem decodes only `ADDR_W` bits, so a pointer above the top
  aliases silently back into the data it is meant to sit clear of), zero
  `a0`/`a1` (argc/argv — a `main(int, char **)` reads them, and nothing else
  sets them: on this core they hold power-up register-file contents, under
  Spike the boot stub's hartid and DTB pointer, so a co-sim diverges on the
  first instruction that touches `a1` unless both start defined), `call main`,
  halt loop. C programs link this; standalone `.S` tests carry their own
  `_start`.
- `link.ld` — Harvard link script: `IMEM (rx) ORIGIN = 0` (16 KiB, code) and
  `DMEM (rwx) ORIGIN = 0x2000` (8 KiB, data) — what the device actually holds
  (46 BSRAM blocks = 828 Kb, so two 64 KiB memories could not both exist).
  Small-data sections are collected into the same output sections
  (`.srodata*`/`.sdata*`/`.sbss*`): RISC-V gcc puts anything up to
  `-msmall-data-limit` (8 bytes) there, and since the image is extracted with
  `objcopy -j .rodata -j .data`, an uncollected `.srodata` never reaches the
  D-mem hex — a 4-byte `const` then reads 0 at runtime while the same constant
  folded at compile time reads correctly. `.text.init`/`.text` → `IMEM` (fetch
  port, read-only); `.rodata`/`.data`/`.bss` → `DMEM` (LSU port; `.bss` last so
  the objcopy image is contiguous with no NOBITS gap). `.data` sits at 0x2000
  (not 0) so the co-sim golden model (Spike, unified-address-space) can hold
  `.text`@0 and `.data`@0x2000 disjoint. Requires `medlow` absolute addressing
  (`lui`+`addi`), not `medany` (`auipc` PC-relative) — `medany` would resolve
  data addresses against the code's I-mem base and break the Harvard split.
  `sim/sw/isa/ifault/` keeps a minimal local `link.ld` (pure assembly, no
  `.bss`).
- `bin2hex.py` — raw little-endian `.bin` → `$readmemh` word file (`@<word>` +
  one 8-hex-digit 32-bit word per line). `--base <byte_addr>` sets the `@` word
  index (default 0); `dmem.hex` uses `--base 0x2000` → `@0x800`. `--pad-words N
  --pad-value W` pads the image to `N` words with `W` (ebreak by default) —
  board-fw-style images pad to the full declared I-mem depth so GowinSynthesis
  sizes the inferred ROM from the `$readmemh` content at the right depth
  (otherwise a stray fetch above the image aliases back into real code instead
  of trapping).
- `uart.h` — UART MMIO register definitions; included by the C programs that
  touch the UART (`-I$(COMMON_DIR)` makes `#include "uart.h"` work from any
  harness).
- `sw_build.mk` — the shared build logic; see the header comment for the
  variables a harness sets.

## Programs and tests

- `quicksort/` — recursive quicksort over a 256-word `.data` array (Lomuto
  partition, `volatile` to defeat constant-folding); verifies ascending order
  and returns `0x600D` (sorted) / `0xBAD` (broken). `partition()` hand-encodes
  a Zilx scaled indexed word load (`lxs.w`) via `.insn` (`-march=rv32imac` has
  no Zilx mnemonics). The array is filled by a deterministic LCG so the co-sim
  compares like for like, and pseudo-random input keeps the recursion near
  log2(N) deep. Printed before/after the sort; `make PRINT_ARRAY=0` compiles
  the printing out (the co-sim needs that — the first UART access is where
  Spike stops being comparable).
- `coremark/` — EEMBC CoreMark. `eembc/` holds the unmodified upstream sources
  (Apache-2.0, `eembc/LICENSE.md`); `core_portme.[ch]` and `ee_printf.c` are
  this core's port: `MEM_METHOD=MEM_STATIC` (no malloc here, and a 2 KiB stack
  block would eat most of the stack), `HAS_FLOAT=0`, `HAS_STDIO=0`, timing from
  the `mcycle` CSR, a ~700-byte integer `printf` over the UART, and local
  `memcpy`/`memset` (gcc emits calls to both, and there is no libc to link).
  Builds to 7.1 KiB of `.text` and 3.5 KiB of D-mem (`.rodata`+`.data`+`.bss`),
  so it fits the 16 KiB/16 KiB memories with the stack clear of it. Defaults:
  `ITERATIONS=1` (one iteration is already 657 k cycles — a simulation run
  cannot afford the 10 s an official score needs), `RUN_TYPE=PERFORMANCE_RUN`,
  `CLK_HZ=40000000`, `SKIP_TIME_CHECK=1` (without it a run whose CRCs all
  matched still ends in "Errors detected" because it ran under 10 s). The
  score line is derived from ticks, not from `time_in_secs`, so it is valid
  even when the seconds count rounds to 0: **1.55 CoreMark/MHz** at
  `ITERATIONS=1` (gcc 14.3.0, `-O2`), CRCs `list 0xe714` / `matrix 0x1fd7` /
  `state 0x8e3a` (the official expected values for the 2K performance
  seeds), 642913 ticks, IPC 0.489. Note `mcycle` is 32 bits here (no
  `mcycleh`), so a timed region must stay under 2^32 cycles = 107 s at
  40 MHz. `COSIM=1` builds the co-sim variant, which reads no cycle counter
  at all — a counter value is the one register write Spike can never
  reproduce; see `sim/cosim/coremark/`, which matches 646307 retires.
- `isa/ifault/` — instruction-access-fault oracle (jump outside the I-mem).
- `isa/isa_probe/` — instruction/memory probe that reports without using the
  hex printer or any instruction under test; board bring-up probe.
- `isa/rvc_scramble/` — per-scramble-bit RVC decode oracle for `c_expand()`.
- `intr/trap/` — standalone M-mode trap-exercise program (ecall /
  load-misaligned / illegal / MSIP + WFI).
- `intr/timer/` — standalone M-mode timer-interrupt program.
- `intr/wfi_trap/` — WFI-wake arbitration regression (illegal-trap behind
  `wfi`); `python3 gen_hex.py` builds it with no toolchain.
- `peri/uart_echo/` — UART echo + external-interrupt (MEIP) oracle, and the
  hardware bring-up program.

See `sim/README.md` for each oracle's expected pass marker and run command.

Build artefacts (`build/`) are gitignored.

## Core coverage (quicksort)

The LSU is live (loads/stores retire through the native D-mem, or the peri
bridge for `addr[PERI_ADDR_BIT]` addresses) and the execute→decode forward path
covers register and load-use hazards (zero bubble), so a memory-heavy program
like quicksort is a real correctness check: it exercises fetch / decode /
execute AND the data path (array loads/stores, stack spill/fill from
recursion, branches on loaded values). The retire+writeback log (`a0` at exit)
is the observable result. `.bss` **is** zeroed at runtime as of 2026-08-25 —
`start.S` clears it from `__bss_start` to `__bss_end` before calling `main`.

`-march=rv32imac` does not emit Zilx indexed loads, so `partition()` hand-
encodes `lxs.w` via `.insn`; the hand-crafted `sim/imem.hex`/`sim/dmem.hex`
oracle covers the other Zilx sizes/signs (b/h/w, signed/unsigned) and the
unscaled variant. Keep quicksort's data accesses in the D-mem region (low
addresses) — a peri access (`addr[28]` set) hits a peripheral slave and has no
D-mem alias, so it would stall the LSU.