# Local changes to the upstream CoreMark sources

This directory is EEMBC CoreMark as vendored, with one deviation. Keep the
list here honest: a co-sim and a published score both depend on these
files being the benchmark everyone else runs.

## `coremark_main.c` — divide first in the score computation

```c
score100 = total_iterations * 1000000 * 100 / total_time;
```

is evaluated in 32-bit arithmetic on this target (`CORE_TICKS` is
`ee_u32`, and `long unsigned` is 32 bits under ilp32). It overflows as
soon as the run is long enough to be reportable: at the 2000 iterations a
10 s run needs, the numerator is 2e11 against a 4.29e9 ceiling, and a
board run whose real score was 1.54 CoreMark/MHz printed `0.1`.

The expression now divides `total_time` by `total_iterations` first and
scales that, which keeps everything in 32 bits — a 64-bit division would
need `__udivdi3`, and this freestanding link has no libgcc. The cost is at
most one part in ticks-per-iteration (~650000 here). This changes only
what is printed on the last line — no seed, no workload, no
CRC, and nothing inside the timed region. All four CRCs still match the
official values for the 2K performance seeds, and `crcfinal` matches
other cores' published 2000-iteration runs (0x4983).

Note the line itself is not in upstream EEMBC CoreMark either: it comes
from the port this tree was vendored from, which added the CoreMark/MHz
scaling output for runs whose ticks are cycles.

## `coremark_main.c` — two decimals on the duration and the rate

With `HAS_FLOAT=0` these two report lines are integer divisions:

```c
ee_printf("Total time (secs): %d\n", total_time_secs);
ee_printf("Iterations/Sec   : %d\n", total_iterations / total_time_secs);
```

A 32.24 s run therefore prints `32` and `62` — one significant figure on
the two lines a reader takes the result from, and unusable for comparing
against a port that has floating point and prints `21.000000` /
`95.238095`. They now call `print_secs_x100` / `print_iters_per_sec_x100`
in `core_portme.c`, which print hundredths computed from the raw tick
count in 32-bit arithmetic.

Presentation only: `total_time` and `total_iterations` are the same
values, the timed region is untouched, and the ≥10 s validity check still
uses CoreMark's own `total_time_secs`.
