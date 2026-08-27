# Provenance of sifive/

These are the sources of SiFive's `benchmark-dhrystone` tree, **vendored
verbatim** — byte-identical to the upstream tree. Nothing in this directory
is edited, and nothing in it may be: `strcpy` and `strcmp` run inside
Dhrystone's measurement loop, so the loop body *is* the benchmark, and a
score from a modified workload is not comparable with anyone else's.

```
upstream : https://github.com/sifive/benchmark-dhrystone
commit   : 0ddff53 ("Merge pull request #8 from sifive/strcmp-for-dhrystone")
files    : dhry.h  dhry_1.c  dhry_2.c  strcmp.S
licence  : LICENSE (also upstream) -- Dhrystone itself carries no explicit
           licence; strcmp.S is FreeBSD-licensed, (c) 2017 SiFive Inc.
```

Dhrystone 2.1 is Reinhold P. Weicker's benchmark (1988), translated to C by
Rick Richardson. SiFive's tree is that source plus a hand-written RISC-V
`strcmp`, and it is the version RISC-V cores are usually quoted against.

`make verify-sifive` (which `make` runs first) checks every file against
`VENDORED.md5`, so an accidental edit fails the build instead of quietly
producing a score for a modified benchmark.

## Everything this port needs lives outside this directory

`../dhry_portme.c` carries the port: `main()`, `time()` over `mcycle`, a
bump allocator for the two records Dhrystone mallocs, `strcpy`,
`memcpy`/`memset`, and the summary lines. `../stdio.h` shadows the
toolchain's for `dhry.h`'s `#include <stdio.h>`, `../dhry_link.ld` is the
link script, and `printf` is `../../common/ee_printf.c`, shared with the
CoreMark port. Four consequences of leaving upstream untouched are worth
knowing before reading a run:

- **A run under 2 s prints "Measured time too small to obtain meaningful
  results".** That is upstream's own run rule (`Too_Small_Time`), and it is
  right: a short run is not a reportable score. It needs `DHRY_ITERS`
  around 150 000 at 50 MHz, which is a board run, not a simulation one. The
  22 `should be:` lines above it are what say the benchmark computed
  correctly, and they are checked at every iteration count. The port's own
  summary is computed from cycles and has no minimum.
- **`main` is renamed, not edited.** The Makefile compiles `dhry_1.c` — and
  only `dhry_1.c` — with `-Dmain=dhry_main` so the port can supply the real
  `main()` and print a summary after Dhrystone's report. `start.S` calls
  `main` once and then spins; there is no exit path, and Dhrystone has no
  finalisation hook of its own the way CoreMark has `portable_fini()`.
- **`float` is defined to `long`**, again by the Makefile and not by an
  edit. `dhry_1.c` uses `float` in exactly seven places, all in the report
  block after the timer stops, and upstream already prints both results
  through an `(int)` cast. This core has no FPU and the toolchain's libgcc
  is built `ilp32d`, so the soft-float helpers those expressions need do not
  exist to link against. Integer arithmetic also makes the two numbers
  exact rather than float-rounded.
- **`Arr_2_Glob` is `int [50][50]`** — 10 000 bytes of `.bss`, which does
  not fit in the 8 KiB `common/link.ld` leaves above `0x2000`. The array is
  part of the benchmark, so the memory moved instead: `../dhry_link.ld`
  starts DMEM at 0 and takes the whole 16 KiB. The cost is the Spike
  co-simulation — see that file.

## Why the port's own strcpy is word-at-a-time

Upstream ships `strcmp.S` and nothing else from the C library, because
`strcpy` and `strcmp` are both called from inside the timed loop and a
Dhrystone number therefore says as much about the library as about the
core. `../dhry_portme.c` supplies a `strcpy` in the same shape as that
`strcmp.S`: word-at-a-time while both pointers share an alignment, byte-wise
otherwise and for the word holding the terminator.

Measured on this core, at `DHRY_ITERS=2000`, changing nothing else:

```
byte-loop strcpy      891 cycles/iteration    0.63 DMIPS/MHz
word-wise strcpy      686 cycles/iteration    0.82 DMIPS/MHz
```

Both are real measurements of this core; they differ only in which library
was linked. The word-wise one is what the port ships, because published
scores are quoted against newlib or an equivalent and that is the number
those can be read against.
