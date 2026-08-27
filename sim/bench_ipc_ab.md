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

## Measured result (2026-08-28, full 32-bit target adder)

Same hex images, Verilator, `BP_EN=1` vs `BP_EN=0`:

| Benchmark | BP=0 CPI | BP=1 CPI | BP=0 IPC | BP=1 IPC | ΔIPC |
|---|---|---|---|---|---|
| quicksort (PRINT_ARRAY=0) | 1.860 | 1.822 | 0.538 | 0.549 | +2.0% |
| CoreMark (ITERATIONS=1) | 1.775 | 1.711 | 0.563 | 0.585 | +3.9% |
| Dhrystone (DHRY_ITERS=2000) | 1.925 | 1.868 | 0.519 | 0.535 | +3.1% |

Headline scores (IPC ratio × the CLAUDE.md BP=0 baselines, which match the BP=0 IPC
above): CoreMark 1.88 → ~1.95 CoreMark/MHz; Dhrystone 0.82 → ~0.85 DMIPS/MHz;
quicksort IPC 0.538 → 0.549.

The entire win is **fewer redirects** (correct predictions cost 0 cycles; a mispredict
still pays the full ~3.1-cycle flush+refill). Predictor accuracy: quicksort 74%,
CoreMark 84%, Dhrystone 79%; RAS hit 98–100%. LSU/div buckets unchanged.

### Notes / gotchas

- **Retire-count identity check:** quicksort (no printing) retires **29675 both ways**
  — the predictor is architecturally invisible, as it must be. CoreMark/Dhrystone retire
  slightly *more* with `BP_EN=1` (+642 / +2229) because their UART `TX_READY` poll loop
  is a busy-wait whose iteration count scales with IPC. That is timing-dependent by
  construction, **not** an architectural divergence; the co-sim uses a no-print build for
  exactly this reason.
- **MAX_CYC:** quicksort parks at ~55k cycles, CoreMark at ~593k–614k, Dhrystone at
  ~1.46M–1.50M. The values above (200000 / 4000000 / 20000000) are safe upper bounds;
  the sim stops on park detection (8 identical retires) before reaching them.
- **NO_VCD=1** is mandatory for the long runs — a board-accurate CoreMark/Dhrystone run
  is millions of cycles and produces a multi-GB VCD without it.
- **Partial-add revert:** an earlier 14-bit (mod-2^IMEM_ADDR_W) target adder was tried as
  a timing hack and reverted to the full 32-bit `src_pc + imm`. It is IPC-neutral — every
  branch target in these kernels is inside the 16 KiB I-mem, so both adds give identical
  targets. The numbers above are the post-revert (full-adder) figures.