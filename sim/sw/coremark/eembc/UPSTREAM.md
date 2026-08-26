# Provenance of eembc/

These are the EEMBC CoreMark sources, **vendored verbatim** — byte-identical
to the upstream tree. Nothing in this directory is edited, and nothing in it
may be: a CoreMark score is only comparable with other cores' published
scores if the workload is the one everyone else runs.

```
upstream : https://github.com/eembc/coremark
commit   : 1f483d5 ("Merge pull request #55 from DeflateAwning/main")
files    : core_list_join.c  core_main.c  core_matrix.c
           core_state.c      core_util.c  coremark.h
licence  : Apache-2.0 (LICENSE.md, also upstream)
```

`make verify-eembc` (which `make` runs first) checks every file against
`VENDORED.md5`, so an accidental edit fails the build instead of quietly
producing a score for a modified benchmark.

## Everything this port needs lives outside this directory

`../core_portme.[ch]` and `../ee_printf.c` carry the whole port: static
memory instead of malloc, `mcycle` for timing, a small integer `printf`
over the UART, `memcpy`/`memset`, the banner, and the port's own summary
lines. Two consequences of leaving upstream untouched are worth knowing
before reading a run:

- **A run under 10 s ends in "Errors detected".** Upstream counts the
  CoreMark run-rule violation as an error, and it is right to: a short run
  is not a reportable score. The four CRC lines are what say whether the
  benchmark computed correctly. Raise `ITERATIONS` (643..6905 at 40 MHz) for
  a run that passes on its own terms.
- **Upstream prints the duration and rate as integers** when `HAS_FLOAT=0`,
  and prints no CoreMark/MHz figure at all without an FPU. The port prints
  its own summary after CoreMark's, with two decimals and the
  cycles-per-iteration the score is derived from.

## One upstream inconsistency, for the next reader

Upstream ships `coremark.md5`, the hash list its run rules use to prove the
workload is unmodified. At commit 1f483d5 that list does **not** match
upstream's own `coremark.h`:

```
listed in coremark.md5 : 8ca974c013b380dc7f0d6d1afb76eb2d
actual file in the tree: b0ec69b6c8e75853d06accb3b1bcf534
```

A comment typo fix ("ultithread" -> "multithread") landed in the header
without the hash list being regenerated. The five `.c` files still match
their listed hashes. `VENDORED.md5` records what was actually vendored, so
the check here is against the real upstream tree rather than a stale list.
