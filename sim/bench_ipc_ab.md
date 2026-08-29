# Benchmark IPC A/B: branch predictor on vs off (`BP_EN=1` vs `BP_EN=0`)

How to reproduce the IPC comparison runs. All commands run from the **project root**
(`/home/giacomo/gowin_proj/rv32imac_Zicsr_Zifencei`). `make -C sim ...` changes into
`sim/` first, so the `+IINIT=`/`+DINIT=` paths are relative to `sim/` (i.e.
`sw/<bench>/build/imem.hex`).

`BP_EN` is a Verilator **elaboration-time** parameter (`-G`), not a runtime arg, so
toggling it requires a **clean rebuild** of `sim/obj_dir` — a `VPARAMS` change is not
tracked by the build dependencies.

## 1. Build the benchmark hex images (once)

```bash
# quicksort: PRINT_ARRAY=0 compiles out the array dump so it parks at ~30k retires
#            (default PRINT_ARRAY=1 runs far longer and never parks in a short MAX_CYC).
make -C sim/sw/quicksort clean
make -C sim/sw/quicksort PRINT_ARRAY=0

# CoreMark: ITERATIONS=1 is the default and the measured config (~600k sim cycles).
make -C sim/sw/coremark ITERATIONS=1

# Dhrystone: DHRY_ITERS=2000 is the default (~1.46M sim cycles).
make -C sim/sw/dhrystone DHRY_ITERS=2000
```

## 2. Run with the predictor ON (`BP_EN=1`, the default)

```bash
NO_VCD=1 MAX_CYC=200000   make -C sim run RUN_ARGS="+IINIT=sw/quicksort/build/imem.hex +DINIT=sw/quicksort/build/dmem.hex" > /tmp/qs_bp1.log 2>&1
NO_VCD=1 MAX_CYC=4000000  make -C sim run RUN_ARGS="+IINIT=sw/coremark/build/imem.hex  +DINIT=sw/coremark/build/dmem.hex"  > /tmp/cm_bp1.log 2>&1
NO_VCD=1 MAX_CYC=20000000 make -C sim run RUN_ARGS="+IINIT=sw/dhrystone/build/imem.hex +DINIT=sw/dhrystone/build/dmem.hex" > /tmp/dh_bp1.log 2>&1
```

## 3. Rebuild the sim with the predictor OFF (`BP_EN=0`), then run

```bash
rm -rf sim/obj_dir          # REQUIRED: VPARAMS change is not dependency-tracked

NO_VCD=1 MAX_CYC=200000   make -C sim run VPARAMS="-GBP_EN=0" RUN_ARGS="+IINIT=sw/quicksort/build/imem.hex +DINIT=sw/quicksort/build/dmem.hex" > /tmp/qs_bp0.log 2>&1
NO_VCD=1 MAX_CYC=4000000  make -C sim run VPARAMS="-GBP_EN=0" RUN_ARGS="+IINIT=sw/coremark/build/imem.hex  +DINIT=sw/coremark/build/dmem.hex"  > /tmp/cm_bp0.log 2>&1
NO_VCD=1 MAX_CYC=20000000 make -C sim run VPARAMS="-GBP_EN=0" RUN_ARGS="+IINIT=sw/dhrystone/build/imem.hex +DINIT=sw/dhrystone/build/dmem.hex" > /tmp/dh_bp0.log 2>&1
```

To switch back to `BP_EN=1`: `rm -rf sim/obj_dir` and run step 2 again (without
`VPARAMS`).

## 4. Read the IPC / CPI / predictor stats

```bash
for f in /tmp/qs_bp1 /tmp/cm_bp1 /tmp/dh_bp1 /tmp/qs_bp0 /tmp/cm_bp0 /tmp/dh_bp0; do
  echo "===== $f ====="
  grep -E "IPC =|= CPI|branch predictor|RAS:|density|retired [0-9]+ instr|parked" $f.log | grep -vE "^  \+"
done
```

Key lines in the output:
- `IPC = 0.xxx (retired / cycles)` — whole-program IPC.
- `= CPI  1.xxx   (IPC 0.xxx)` — CPI decomposition (1.0 + the `+` buckets == CPI).
- `branch predictor: N resolved, N predicted-taken, N mispredicts (xx% accuracy, xx MPKI)`
- `RAS: N returns, N hits / N misses (xx% hit)`
- `density: 1 redirect per N instr, mem-ops xx% of instr`

## 5. Headline scores (CoreMark/MHz, DMIPS/MHz) — UART output

The benchmark's own score report goes over the UART, logged to `sim/sim_uart_tx.txt`
(not stdout). That file is **shared and overwritten on every run**, so:
- **Do not run the three benchmarks in parallel** if you want the score text — they
  clobber the one UART log. Run them one at a time (the commands above are sequential,
  so they're fine; just don't add `&`).
- After a single CoreMark or Dhrystone run:

```bash
tr -d '\0' < sim/sim_uart_tx.txt
```

The port summary lines (ticks, cycles/iteration, CoreMark/MHz, DMIPS/MHz) are printed
there. CoreMark/MHz and DMIPS/MHz come from the benchmark's internal `mcycle`
measurement, not from the sim cycle count, so they are independent of startup/banner
overhead.

## Measured result (2026-08-28, gshare index `pc[6:1]^ghr`, corrected stat counters)

Same hex images, Verilator, `BP_EN=1` vs `BP_EN=0`:

| Benchmark | BP=0 CPI | BP=1 CPI | BP=0 IPC | BP=1 IPC | ΔIPC |
|---|---|---|---|---|---|
| quicksort (PRINT_ARRAY=0) | 1.860 | 1.821 | 0.538 | 0.549 | +2.0% |
| CoreMark (ITERATIONS=1) | 1.775 | 1.715 | 0.563 | 0.583 | +3.6% |
| Dhrystone (DHRY_ITERS=2000) | 1.925 | 1.870 | 0.519 | 0.535 | +3.1% |

Headline scores, both measured from the benchmark's own `mcycle` report (not scaled
from an IPC ratio):

| Benchmark | BP=0 | BP=1 |
|---|---|---|
| CoreMark cycles/iteration | 528976 | 511378 |
| CoreMark/MHz | 1.89 | **1.95** |
| Dhrystone cycles/iteration | 684 | 666 |
| DMIPS/MHz | 0.83 | **0.85** |

The entire win is **fewer redirects** (correct predictions cost 0 cycles; a mispredict
still pays the full ~3.1-cycle flush+refill):

| Benchmark | redirects BP=0 → BP=1 | redirect CPI | accuracy | MPKI | RAS |
|---|---|---|---|---|---|
| quicksort | 4151 → 1571 (−62%) | 0.420 → 0.164 | 74.68% | 52.94 | 339 returns, 98.2% hit |
| CoreMark  | 39702 → 9319 (−77%) | 0.360 → 0.086 | 86.34% | 27.34 | 1429 returns, 100% hit |
| Dhrystone | 86769 → 31995 (−63%) | 0.348 → 0.124 | 78.46% | 41.02 | 20088 returns, 100% hit |

LSU/div buckets unchanged. What eats most of the gross redirect saving is a *new*
`imem-starve`+`other`+`decode-bubble` bucket that is ~0 with `BP_EN=0` and 0.218 /
0.212 / 0.169 CPI (qs/cm/dh) with `BP_EN=1`: the buffer kill + refill on every
*correct* predicted-taken branch, which no mispredict fires for, so the histogram
charges it to fetch starvation rather than to `redirect`.

The `accuracy` figure printed under `BP_EN=0` (~33–42%) is not a prediction accuracy:
with no predictor every taken branch counts as a mispredict, so it is the not-taken
rate of the branch mix. Only the `BP_EN=1` column means anything.

## 3-stage vs 4-stage (align stage added 2026-08-28)

Independent of `BP_EN`, and measured with `BP_EN=1` on both sides. The align
stage puts a flop between the fetch buffer and the decoder, which costs one
extra refill cycle per buffer kill — and both a mispredict AND a *correct*
predicted-taken redirect kill the buffer:

| | 3-stage | 4-stage | Δ |
|---|---|---|---|
| quicksort IPC / CPI | 0.549 / 1.821 | 0.504 / 1.983 | −8.2% / +8.9% |
| CoreMark cycles/iteration | 511378 | 548278 | +7.2% |
| CoreMark/MHz | 1.95 | 1.82 | −6.7% |
| CoreMark IPC / CPI | 0.583 / 1.715 | 0.544 / 1.839 | |
| Dhrystone cycles/iteration | 666 | 702 | +5.4% |
| DMIPS/MHz | 0.85 | 0.81 | −4.7% |
| cycles per redirect (quicksort) | 3.09 | 3.91 | +0.82 |

**Break-even is 53.6 MHz** (CoreMark): below that the split is a net loss in
absolute performance, above it a win. Retire counts are identical on both
sides and all three co-sims match Spike at the same counts (quicksort 29632,
ecall 17, CoreMark 332803) — the stage is architecturally invisible, which is
the property that had to hold.

### Notes / gotchas

- **Retire-count identity check:** quicksort (no printing) retires **29675 both ways**
  — the predictor is architecturally invisible, as it must be. CoreMark/Dhrystone retire
  slightly *more* with `BP_EN=1` (+1107 / +2391) because their UART `TX_READY` poll loop
  is a busy-wait whose iteration count scales with IPC. That is timing-dependent by
  construction, **not** an architectural divergence; the co-sim uses a no-print build for
  exactly this reason.
- **Rebuild the timed CoreMark image before measuring.** `make -C sim/cosim/coremark
  cosim` builds `COSIM=1 -O2` into the *same* `sim/sw/coremark/build/`, and that image
  has no cycle counter — it reports `Total ticks: 0` and a different cycle count. If the
  UART report shows `Compiler flags : -O2` or `Total ticks : 0`, you are measuring the
  co-sim image: `make -C sim/sw/coremark clean && make -C sim/sw/coremark`.
- **Stat counters are levels, not pulses.** `cf_resolving` / `lookup_req.ret_consume` are
  high for exactly one cycle per event, but consecutive events give no falling edge in
  between, so `sim_main.cpp` counts every high cycle and must not edge-gate the `n_bp_*`
  counters. An earlier edge-gated version under-reported CoreMark's control-flow count by
  2917 of 68234 (adjacent-cycle pairs, e.g. `if (a && b)`) and silently dropped any
  mispredict landing on the second cycle of a pair. Cross-check: the counters now match a
  per-opcode count of the retire trace exactly (CoreMark 68240 CF / 1429 returns).
- **MAX_CYC:** quicksort parks at ~54k–55k cycles, CoreMark at ~585k–603k, Dhrystone at
  ~1.46M–1.50M. The values above (200000 / 4000000 / 20000000) are safe upper bounds;
  the sim stops on park detection (8 identical retires) before reaching them.
- **NO_VCD=1** is mandatory for the long runs — a board-accurate CoreMark/Dhrystone run
  is millions of cycles and produces a multi-GB VCD without it.
- **Partial-add revert:** an earlier 14-bit (mod-2^IMEM_ADDR_W) target adder was tried as
  a timing hack and reverted to the full 32-bit `src_pc + imm`. It is IPC-neutral — every
  branch target in these kernels is inside the 16 KiB I-mem, so both adds give identical
  targets. The numbers above are the post-revert (full-adder) figures.
