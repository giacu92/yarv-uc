# riscv-tests ISA suite on this core

The official RISC-V ISA tests, built for this Harvard RV32IMAC core and run
under the Verilator harness. 67 tests across four suites; **62 pass, 5 fail
for reasons that are properties of the core rather than defects** (listed
below and encoded in `sim/Makefile`'s `COMPLIANCE_XFAIL`).

This complements, and does not replace, the in-house oracles under `sw/isa/`.
The oracles cover things the compliance suite does not reach at all — RVC
immediate scrambling, the branch predictor's architectural transparency, the
same-cycle target span, instruction access faults — and they are what
`make regress` runs after an RTL edit. The compliance suite answers the other
question: whether the ISA is implemented as specified, judged by code nobody
here wrote.

## Getting the upstream tree

`riscv-tests/` is not stored in this repository; it is a git submodule pinned
to the commit recorded in `UPSTREAM.md`, and its own `env/` submodule (which
supplies `encoding.h`) has to be initialised with it:

```bash
git submodule update --init --recursive sim/sw/compliance/riscv-tests
```

If the submodule is missing, `make` here builds nothing and reports no tests,
because the test list is discovered from `riscv-tests/isa/<suite>/*.S`.

## Running it

```bash
# 1. build the ~67 images (once, or after re-vendoring)
make -C sim/sw/compliance \
     RISCV_PREFIX=$HOME/_toolchains/riscv32-ilp32d--glibc--stable-2025.08-1/bin/riscv32-buildroot-linux-gnu

# 2. run them
cd sim && make compliance
```

`make compliance` exits non-zero if any test's result differs from the
expected table — including a test that starts *passing* (reported `XPASS`),
because that means the expectation list is stale.

One test alone:

```bash
cd sim && PROBE=0x2000 NO_VCD=1 MAX_CYC=100000 ./obj_dir/Vsim_top \
    +IINIT=sw/compliance/build/rv32ui-add/imem.hex \
    +DINIT=sw/compliance/build/rv32ui-add/dmem.hex
```

Rebuild one test: `make -C sim/sw/compliance rv32ui/add RISCV_PREFIX=...`.

## How the verdict gets out

Upstream's tests report through a memory word called `tohost`, written by the
test environment's trap handler when the test executes the `ecall` that
`RVTEST_PASS` / `RVTEST_FAIL` end in.

`env/link_harvard.ld` pins `.tohost` at the bottom of the D-mem, so **`tohost`
is at 0x2000 for every test** and one fixed `PROBE=0x2000` reads all of them —
no per-test symbol lookup. Encoding is upstream's, unchanged:

| tohost | meaning |
|---|---|
| `0x1` | pass |
| `2n+1` | failed in test case `n` — look `n` up in the test source |
| `0x539` | 1337, upstream's "trap with no handler installed" marker |
| `0x0`, or no park | never reported: hang, or the cycle bound was hit |

After writing `tohost` the handler parks in a **one-instruction** self-loop.
That detail is load-bearing: `sim_main.cpp` ends a run early on 8 consecutive
identical retires, and upstream's multi-instruction `j write_tohost` loop
never produces those — every test would run to `MAX_CYC` instead of finishing
in a few hundred cycles.

## What is in this directory

| path | what |
|---|---|
| `riscv-tests/` | vendored upstream, **never edited** — see `UPSTREAM.md` |
| `env/riscv_test.h` | our replacement for upstream's `env/p` environment |
| `env/link_harvard.ld` | Harvard split: `.text`→I-mem 0, `.tohost`+`.data`→D-mem 0x2000 |
| `test.mk` | per-test build fragment over `sw/common/sw_build.mk` |
| `Makefile` | suite discovery, recursion, `verify-upstream` |
| `riscv-tests.sha256` | manifest guarding the vendored tree |

Two upstream pieces had to be replaced rather than reused, and both are
documented in the files themselves: the environment (it links one address
space at 0x8000_0000 and initialises satp/PMP/mnstatus/medeleg, none of which
exist here) and the linker script.

Note `test.mk` builds with `-march=rv32im_zicsr_zifencei` — **no C**. That
matches upstream's `-march=rv32g` for every rv32 suite and is not an
oversight: with C enabled the assembler auto-compresses eligible
instructions, so the test named `add` would end up exercising `c.add`. The
compressed suite turns C on itself, per case, with `.option rvc`.

## The five expected failures

| test | why |
|---|---|
| `rv32ui-fence_i` | Harvard. No write path from the LSU to the I-mem, so self-modifying code cannot work by construction and `fence.i` is correctly a nop. |
| `rv32ui-ma_data` | Misaligned load/store is not implemented in hardware — it traps (mcause 4/6). The spec permits trapping; the test does not (no handler, expects the access to complete). |
| `rv32uc-rvc` | Case 6 only. It loads from a `.dword` the test embeds in its own `.text`, i.e. reads the I-mem with a data load. Cases 2-5 and 8-30 — every actual RVC encoding — pass. |
| `rv32mi-pmpaddr` | No PMP. |
| `rv32mi-instret_overflow` | Case 3. **The one genuine gap**: `mcycleh` / `minstreth`, which RV32 mandates, are not implemented, so a write to `minstreth` neither lands nor suppresses that instruction's count. Two CSRs would close it. |

Worth stating what the pass list contains, since some of it was not obviously
going to work: all 42 `rv32ui` tests bar the two above, all 8 `rv32um`
(including every `MULH*` form and both divide corners), and 14 of 16
`rv32mi` — `ma_addr`, `ma_fetch`, `illegal`, `breakpoint`, `csr`, `mcsr`,
`scall`, `sbreak`, `shamt`, `zicntr` and the four `*-misaligned` trap tests
all pass, which exercises the trap unit against an external definition of
correct for the first time.

## Suites that are not built

`rv32ua` (no A extension — the AMO opcode carries the custom Zilx indexed
load, and every real AMO encoding decodes to illegal), `rv32si` (M-mode only,
no delegation, no MMU), and the F/D/bitmanip/packed-SIMD suites. Those are
design decisions, not failures, so they are excluded at the suite level rather
than listed as expected failures.
