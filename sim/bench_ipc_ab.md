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

### Measured result (2026-08-30, linker relaxation + 512-entry PHT)

Two changes landed together, so this is a 2x2. Rows are the D-mem/I-mem images
(`-Wl,--no-relax` removed from `sim/sw/common/sw_build.mk`), columns are the PHT
geometry (`BP_PHT_DEPTH`/`BP_GHR_W` in `rv32_pkg.sv`). All four cells run the same
RTL apart from those two localparams, `BP_EN=1` throughout. Scores are the
benchmark's own `mcycle` measurement, not the sim cycle count.

| | PHT 64 x GHR 6 | PHT 512 x GHR 9 |
|---|---|---|
| CoreMark, no-relax | 510008 ticks | 503998 ticks |
| CoreMark, **relax** | 505950 ticks | **501118 ticks** (1.99 CoreMark/MHz) |
| Dhrystone, no-relax | 677 cyc/iter | 660 cyc/iter |
| Dhrystone, **relax** | 651 cyc/iter | **638 cyc/iter** (0.89 DMIPS/MHz) |

Predictor stats at the final (relax + 512) cell, against the old (no-relax + 64) cell:

| Benchmark | mispredicts | accuracy | MPKI | redirect CPI | IPC |
|---|---|---|---|---|---|
| quicksort | 1571 -> **1226** | 74.7% -> **80.2%** | 52.9 -> **41.8** | 0.164 -> **0.129** | 0.549 -> **0.553** |
| CoreMark | 9215 -> **5712** | 86.7% -> **91.7%** | 27.5 -> **17.1** | 0.086 -> **0.053** | 0.575 -> **0.582** |
| Dhrystone | 31995 -> **1036** | 78.5% -> **99.3%** | 41.0 -> **1.4** | 0.348 -> **0.004** | 0.528 -> **0.542** |

Reading the 2x2: relaxation is most of the Dhrystone win and the PHT is most of the
CoreMark win, because they fix different things. Relaxation deletes the
`auipc ra,X; jalr ra,off(ra)` call sequence (110 of Dhrystone's 111 static jalr/jr
sites became `jal`), and a `jal` gets a free PC-relative prediction at decode where a
`jalr` got none at all — that is a call-frequency effect, so it barely moves loop-bound
CoreMark. The PHT resize fixes capacity aliasing in the conditional-branch stream,
which is where CoreMark lives.

**IPC is the wrong headline for the relaxation half.** Dhrystone IPC moves only
0.528 -> 0.542 while cycles/iteration drops 677 -> 638 (-5.8%), because relaxation also
*removes* instructions (the `auipc` half of every call) — a smaller, denser instruction
stream at similar IPC is still less work. Compare cycles, not IPC, across a code-gen
change.

Not attributable to either change: LSU stays the dominant cost in every cell
(`lsu-launch` + `lsu-capture` = 0.42-0.52 CPI, vs redirect now 0.004-0.129).

CoreMark CRCs are byte-identical across all four cells (`seedcrc` 0xe9f5, `crclist`
0xe714, `crcmatrix` 0x1fd7, `crcstate` 0x8e3a) — the workload did not change, only the
code generated for it.

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
- **`-Wno-WIDTH` hides a resize bug.** `sim/Makefile` passes `-Wno-WIDTH` to Verilator.
  When the PHT index widened 6 -> 9 bits, the field alias inside `branch_predictor.sv`
  (`wire [5:0] train_pht_index_i = train_i.pht_index;`) was missed, silently truncating
  every training write to the low 6 entries while lookups used all 9 bits. It compiled
  clean, passed every self-checking oracle and all three co-sims (the predictor is a
  hint; execute is the golden resolver, so a broken predictor cannot fail a correctness
  test), and showed up *only* as an accuracy number: 48.6% on quicksort where the
  trace-driven model said 80%. **Predictor changes have to be judged on the accuracy /
  MPKI line, not on the test suite passing.** Model the change offline first so there is
  a number to disagree with.

### PHT depth is a timing parameter, not an accuracy one (2026-08-31)

The PHT is read combinationally at decode and that read feeds fetch's `launch` /
`inflight` logic in the same cycle, so its depth sits directly on a critical path.
On the 2026-08-31 PnR run a 512-entry table put `pht_index -> RAM out` at 6.1 ns,
**3.36 ns of it pure routing** between the spread-out RAM primitives, landing that
path at -1.024 ns. Measured cost of shrinking it (CoreMark, ITERATIONS=4, -O3):

| PHT x GHR | ticks | mispredicts | vs 512 |
|---|---|---|---|
| 512 x 9 | 2004284 | 18608 | — |
| 256 x 8 | 2010433 | 23601 | +0.31% cycles |
| **128 x 7** | **2017387** | 24944 | **+0.65% cycles** |

0.65% of cycles for ~1 ns of slack is a good trade: 1 MHz is worth 2%. Shipped at
128; move up only if PnR says the slack is there. Changing depth means changing the
three `BP_*` localparams in `rv32_pkg.sv` and nothing else.

The structural fix, if a big table is ever wanted without the timing cost: look the
PHT up at instruction-buffer **push** time and carry the 1-bit prediction in the
buffer entry, taking the RAM read off the decode->fetch path entirely, at the price
of a slightly staler GHR.

### ALU result mux: order by measured arrival, and measure it (2026-08-31)

`alu.sv` selects its result with two muxes ordered by how late each candidate
settles. Getting the order wrong is expensive in both directions, and both
directions were measured on silicon-bound PnR runs:

- The original 11-way `unique case` + div/mul if-else put the **adder** eight mux
  levels deep: 5.50 ns after the carry chain, more than the 4.76 ns adder itself.
- The first fix gave the adder the final mux but folded **MUL** in with the early
  candidates, on the assumption that a DSP-backed op had slack. It did not. MUL's
  output arrives 3.76 ns after its operands -- *later than the adder* -- and became
  the critical path at -1.041 ns with five mux levels behind it.

Final order: MUL takes the last mux (1 level), the adder the one behind it
(2 levels), genuinely early candidates (div / compare / shift / logic) sit deepest.
SLT/SLTU read off the shared adder's carry-out and sign bit rather than
instantiating their own comparators. The restructure is cycle-identical by
construction and was verified so: quicksort 53072, CoreMark 2004284 ticks,
Dhrystone 638 cyc/iter, all bit-identical across the change at PHT 512.
