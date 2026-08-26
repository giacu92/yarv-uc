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
