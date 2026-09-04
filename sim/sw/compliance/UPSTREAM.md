# Vendored upstream: riscv-tests

`riscv-tests/` is the official RISC-V ISA test suite, pinned as a git
submodule at the commit below rather than copied into this repository. It
is **never edited**. Everything this core needs in order to run it lives
outside that directory, in `env/` and `test.mk`, exactly as `sw/coremark/`
keeps its port outside `eembc/` and `sw/dhrystone/` outside `sifive/`.

The reason is the same one as for those two: a modified compliance suite is
not a compliance suite. A test that has been "fixed" until it passes measures
the fix, not the core.

## Provenance

| item | value |
|---|---|
| repository | https://github.com/riscv-software-src/riscv-tests |
| commit | `2ebecad997fa58cd9e5724340ba75aa4b59bd1d0` |
| submodule `env/` | https://github.com/riscv/riscv-test-env |
| submodule commit | `6de71edb142be36319e380ce782c3d1830c65d68` |
| licence | see `riscv-tests/LICENSE` and `riscv-tests/env/LICENSE` |
| vendored | 2026-09-03 |

## What is used, and what is not

`riscv-tests.sha256` covers only the files this harness reads (172 files,
~1 MB) rather than the whole submodule, so `verify-upstream` answers "is the
code we compile the upstream code" and stays silent about the parts of the
suite that are never built:

```
LICENSE
env/LICENSE
env/encoding.h                 CSR numbers, mcause codes, mstatus bits
isa/macros/scalar/             test_macros.h -- TEST_CASE, TEST_RR_OP, ...
isa/rv32ui  isa/rv32um  isa/rv32uc  isa/rv32mi
isa/rv64ui  isa/rv64um  isa/rv64uc  isa/rv64mi  isa/rv64si
```

The rv64 directories are not optional and are not dead weight: every rv32
test source is a three-line wrapper that `#include`s the rv64 body with the
XLEN-dependent parts compiled out (`rv32ui/add.S` includes `../rv64ui/add.S`).
`rv32mi/scall.S` and `rv32mi/sbreak.S` reach into `../rv64si/`.

Present in the submodule but never built, because nothing here can run them: `isa/rv32ua` and `isa/rv64ua`
(no A extension -- the AMO opcode is the custom Zilx indexed load),
`isa/rv32si`/`rv64si` beyond the two files above (no S-mode), the F/D/vector/
bitmanip/hypervisor suites, `benchmarks/`, `debug/`, `mt/`, and upstream's
own build system (`configure`, `Makefile.in`, `isa/Makefile`) -- this harness
builds through `sw/common/sw_build.mk` instead, so the images come out in the
same two-file `$readmemh` shape as every other program in the tree.

The upstream test environment `env/p/` is **deliberately not used**. It
links code and data into one address space at 0x8000_0000 and programs CSRs
this core does not have; `env/riscv_test.h` in this directory replaces it and
documents each deviation.

## Verifying

```bash
make -C sim/sw/compliance verify-upstream
```

Checks every vendored file against `riscv-tests.sha256`. Regenerate that
manifest only when deliberately re-vendoring a newer upstream commit, and
update the table above in the same change:

```bash
cd sim/sw/compliance/riscv-tests && \
  find LICENSE env/LICENSE env/encoding.h isa/macros/scalar \
       isa/rv32ui isa/rv32um isa/rv32uc isa/rv32mi \
       isa/rv64ui isa/rv64um isa/rv64uc isa/rv64mi isa/rv64si -type f \
    | LC_ALL=C sort | sed 's|^|./|' | xargs sha256sum > ../riscv-tests.sha256
```
