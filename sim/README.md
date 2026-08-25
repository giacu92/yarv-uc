# Simulation (Verilator)

Functional simulation of the implemented pipeline (fetch + decode +
execute + LSU + Zicsr CSR file + trap/exception/interrupt unit). The
**Harvard** build wires the CPU to a native read-only I-mem
(`native_ram`, `+IINIT`) and a native byte-strobed D-mem (`native_ram`,
`+DINIT`); the AXI4-Lite peripheral bus carries three MMIO slaves behind
a 1→3 address-decode xbar (`axi4_lite_xbar_3`, base+size windows from
`rv32_pkg`; unmapped → DECERR): `axi4_lite_uart` (UART, `0x1000_0000` —
its level IRQ drives `mip.MEIP`), `clint_timer` (machine timer
interrupt, `0x1000_1000+`), and `msip_peri` (machine software interrupt,
`0x1000_3000`). The board top's wiring is replicated in `sim_top.sv` so
the memories can be preloaded and the CPU's per-stage debug taps can be
logged.

The UART is driven for real in both directions: `uart_rxd_i` is a port
(double-flopped exactly like the board top, so the board's synchronizer
is actually simulated), fed with 8N1 frames by the C++ harness, and every
byte the CPU pushes into the TX FIFO is captured to `sim_uart_tx.txt`.
That is how a serial-console program (YarvMon, `sw_uart_echo`) is
observed and driven — see "UART console I/O" below.

This harness is **not** part of the synthesis file list.

## One-time setup

Install Verilator (Debian/Ubuntu):

```
sudo apt-get install -y verilator
```

## Build & run

```
cd sim
make run                                          # Harvard: imem.hex/dmem.hex oracle
make run RUN_ARGS="+IINIT=sw/build/imem.hex +DINIT=sw/build/dmem.hex"  # C program
# or, from the repo root:
make sw-run       # build the C program (sim/sw) + run the Harvard sim loading it
```

`make run` compiles `obj_dir/Vsim_top` and runs it. The harness drives
clk/rst (async active-low reset for a few cycles) and prints **three**
logs, each in its own reset+run pass so they stay aligned (each stage
lags the previous by one cycle):

- a **fetch log** — one line per F/D-valid word: `cycle / fe_pc /
  fe_instr / c` (c = compressed flag of the low half), with a
  word-advance-+4 check;
- a **decode log** — one line per D/E-valid instruction:
  `cycle / de_pc / de_instr`;
- an **execute retire + writeback log** — one line per E/M-valid
  retired op: `cycle / ex_pc / ex_instr`, plus a `wb x<n> = 0x...` line
  when the op writes a register (sampled from the internal `wb_en` /
  `wb_addr` / `wb_data` nets). This makes the execute→decode forward path
  and the LSU load-use path verifiable: dependent ops get the retiring
  value same-cycle via the bypass (distance-1 RAW, zero bubble), with the
  load's `EX_MEM_WAIT` holding the consumer in decode until `rvalid`.

The CPU exports no per-stage debug ports; the harness reads the
internal taps (`fe_*`, `de_*`, `ex_*`, `wb_*`) as flat members of the
Verilator root object (built `--public-flat-rw`). An exit summary prints
`retired N instructions in M cycles`, `IPC = N/M`, and a
`stalled K/M cycles (P%)` breakdown — the DIV/REM hold, LSU
`EX_MEM_WAIT`, and (legacy, now zero) RAW-hazard costs per run. Every
run also checks the WFI-halt invariant from the internal `wfi_halt_q` /
`int_pending` taps: prints `WFI-halt check: OK`, or `WFI-HALT FAIL` with
a nonzero exit if the halt outlives a pending interrupt by more than
`WFI_STUCK_N` (64) cycles or is held with no wake for more than
`WFI_HALT_N` (4000). The run stops early on park
detection (8 consecutive identical retires — the `start.S` `1: j 1b`
self-loop); a `MAX_CYC` env var (default 4000) bounds programs that
never park (e.g. `MAX_CYC=20000 make run`). A VCD waveform
`sim_top.vcd` is also written; open it with `make wave` (needs
`gtkwave`).

### VCD / GTKWave

The VCD traces the full hierarchy (`--trace`), so decode internals are
named even though they are not CPU ports: `u_decode.opcode`,
`u_decode.alu_op`, `u_alu.alu_op_i`, `funct3/5/7`, `imm_*`, `rs1/rs2_*`,
etc. To show a numeric signal as a mnemonic in GTKWave, set its Data
Format to Bin, then `Edit → Data Format → Translate Filter File →
Enable and Select`, and point it at a translate file. Two ready files
live here:

- `gtkwave_alu_op.txt` — `ALU_ADD..ALU_LX` (applies to
  `u_decode.alu_op` / `u_alu.alu_op_i`);
- `gtkwave_opcode.txt` — `OPC_LUI..OPC_AMO` (applies to
  `u_decode.opcode`).

Re-apply a filter if you delete/re-add the signal (it does not
auto-reapply).

## Program image

The Harvard build loads two `$readmemh` preloads (one 32-bit hex word per
line; the word value IS the instruction/data word):

- `sim/imem.hex` — instruction image (I-mem, read-only).
- `sim/dmem.hex` — data image (D-mem, byte-strobed). Empty placeholder
  for the oracle, which writes its own data at runtime via stores.

The images are **plusarg-selected**: `+IINIT=<path>` / `+DINIT=<path>`
override the defaults, so a C-compiled image pair can be loaded without
clobbering the oracle. To compile C → images, use the `sim/sw/` flow
(see `sim/sw/README.md`).

## UART console I/O

The harness types into the UART and records what comes out, so a serial
program can be exercised end to end without hardware.

```
cd sim
UART_RX='2000\r' make run RUN_ARGS="+IINIT=sw-yarvmon/build/imem.hex +DINIT=sw-yarvmon/build/dmem.hex"
cat sim_uart_tx.txt          # everything the CPU transmitted
```

Environment knobs:

- `UART_RX="..."` — the string to type, as real 8N1 frames on
  `uart_rxd_i`. C escapes are decoded, so `\r` is the Enter key
  `get_line` waits for. Unset = idle line (a `uart_getc()` poll never
  completes).
- `UART_RX_PACED=0` — ship frames back-to-back instead of waiting for RX
  FIFO room. This is what a line-buffered terminal does when it sends a
  whole typed line at once, and it is the case that broke YarvMon on
  hardware before the UART had FIFOs: echoing a byte costs a full frame
  time (87 µs at 115200), so with a single-byte RX buffer every byte
  arriving during the echo was dropped and the command line arrived
  empty. Keep it in any UART regression — the paced default cannot
  provoke an overrun by construction.
- `UART_BIT_CYCLES=<n>` — clocks per bit in the driver. Must match the
  UART instance: 347 for the active 40 MHz board build, 217 for the 25 MHz
  PLL-bypass one. Pair it with a board-accurate build (below).
- `NO_VCD=1` — skip the waveform dump. A board-accurate run is millions
  of cycles, i.e. a multi-gigabyte VCD.

`sim_top`'s UART clock/baud are parameters, so the sim can run either
fast (default 50 MHz / 10 MHz = 5 clocks per bit) or with the board's
real divisor to check the RX
sampling phase at the ratio the hardware actually uses:

```
rm -rf obj_dir
# The board now runs clk_core at 40 MHz (rPLL 25 x 8/5), so its divisor is
# 40e6/115200 = 347 clocks per bit. Pass the numbers of whichever build you
# are reproducing -- 25 MHz/217 for the PLL-bypass build.
make VPARAMS="-GUART_CLK_HZ=40000000 -GUART_BAUD=115200"
NO_VCD=1 UART_BIT_CYCLES=347 UART_RX='2000\r' MAX_CYC=400000 \
  ./obj_dir/Vsim_top +IINIT=sw-yarvmon/build/imem.hex +DINIT=sw-yarvmon/build/dmem.hex
rm -rf obj_dir && make        # back to the fast default
```

A `VPARAMS` change is not tracked by the build dependencies, hence the
explicit `rm -rf obj_dir`.

## UART FIFO + IRQ compliance test (`hw/uart_tb/`)

BFM master driving `axi4_lite_uart` directly, with a continuous 8N1
decoder on `txd_o` and a frame driver on `rxd_i` (10 clocks per bit).
Checks the FIFO contract and the interrupt, not just the AXI handshake:
queued TX bytes ship in order with no polling in between; TX_READY drops
when the TX FIFO is full and a write to a full FIFO is **held** until room
appears — the test measures how many cycles the write took, so it can tell
a held write from an immediate one, and checks the byte still ships in
order; an RX burst inside the depth is fully retained in
order with RX_OVERRUN clear; one frame past the depth is dropped and
latches RX_OVERRUN while the queued bytes survive; reading an empty RX
FIFO pops nothing (no pointer underflow); the IRQ is level-sensitive and
gated by CTRL — nothing fires until an enable is written, and it
deasserts when software drains the condition.

```
cd hw/uart_tb && make run     # "146 checks, 0 failures"
```

## UART echo + external-interrupt (MEIP) oracle (`sw_uart_echo/`)

`uart_echo.c` echoes `PHASE_CHARS` (4) bytes read by polling, then
enables `CTRL.RX_IE` + `mie.MEIE` + `mstatus.MIE` and echoes 4 more from
a machine-interrupt handler, sleeping in `wfi` in between. It writes
`0x600D`/`0xBAD` to D-mem **0x3000** — not 0x2000, where `.rodata` is
linked (writing there would clobber the strings it prints).

This is the only end-to-end test of the machine *external* interrupt:
`uart_irq_o` → `meip_i` → `mip.MEIP` → `trap_unit` → interrupt entry,
including the `wfi` wake on an external interrupt.

```
cd sw_uart_echo && make
cd .. && UART_RX='abcdefgh' make run \
  RUN_ARGS="+IINIT=sw_uart_echo/build/imem.hex +DINIT=sw_uart_echo/build/dmem.hex"
# serial log: "ECHO / abcd / IRQ / efgh / GOOD", and wb x15 = 0x0000600d
```

It doubles as the hardware bring-up program: it is deliberately smaller
and dumber than YarvMon, so on a board that shows no echo, phase 1 tells
you whether bytes reach the CPU at all and phase 2 whether the interrupt
path works.

Bring-up added probes that are worth keeping, because between them they
turned a board that went silent into a board that says where it is:

- `PAT` prints two literals with every nibble distinct, so the hex printer
  is checked before anything is concluded from the values it prints. That
  was not paranoia: on silicon every hex value came out with the low two
  bits of each nibble cleared, which looked exactly like corrupted CSRs.
- `CSRW` writes and reads back `mscratch`/`mcause`/`mepc`/`mtval` with
  walking patterns, which separates "the register does not hold this bit"
  from "the value was computed wrong".
- `MTVEC` is read back against the handler address. A wrong `mtvec` breaks
  every trap at once and does it invisibly, by vectoring into whatever the
  I-mem holds there.
- the handler prints `H<mcause>@<mepc>` on entry and `X` before every
  return, so "died in the handler" and "returned somewhere wrong" are
  distinguishable.
- interrupt waits are bounded and print the full CSR state on timeout.
  An unbounded spin on an interrupt that never arrives looks identical to
  a dead UART, a dead core and a trap storm.

`make UART_TX_PACED=1` builds it with a software delay instead of the
`TX_READY` poll, so a single byte is in flight at a time and the TX FIFO
never fills — that is what separates "the FIFO filled" from "the poll
never returned".

## Instruction-access-fault oracle (`sw_ifault/`)

`ifault_test.S` jumps to 0x100000 — far outside the 16 KiB I-mem — and
checks that exactly one trap arrived, with `mcause` = 1 (instruction access
fault) and `mtval` equal to the address jumped to. It writes `0x600D` to
D-mem 0x2000 on pass, `0xBAD` on failure, and needs nothing but the
assembler.

The handler deliberately does **not** `mret` to `mepc`: the faulting
address is still unfetchable, so returning there would fault again
forever. It rewrites `mepc` to a known label instead, which is what a real
handler has to do with this trap.

```
cd sw_ifault && make
cd .. && make run \
  RUN_ARGS="+IINIT=sw_ifault/build/imem.hex +DINIT=sw_ifault/build/dmem.hex"
```

## ISA / memory probe (`sw_isa_probe/`)

A board bring-up probe for the case where the *reporting* is what lies.
It reports through fixed strings (`name OK` / `name BAD`) and dumps values
in binary using only register-register `AND` and mask doubling by addition
— never the hex printer, and never an instruction under test.

It checks, one verdict per line: `c.andi` with immediates 15/7/3/1 (hand
encoded halfwords, so the encoding is exactly the one named) against the
32-bit `andi`; the shifts; register-register `AND`/`OR`; a byte load at
each lane; and a memory matrix on one word in `.rodata` and one in
`.data` — `lw`, `lbu` at a constant offset, `lbu` at a **computed**
address, `lhu`, and byte stores read back.

That last split is the point. A `const` read at a constant index gets
folded at compile time and proves nothing about the memory; only a
computed index produces a real load. It is what isolated the load
byte-select bug, where a load whose address came from a distance-1
forward read the right word but the wrong byte, on silicon only.

```
cd sw_isa_probe && make UART_TX_PACED=1
cd .. && UART_BIT_CYCLES=217 make run \
  RUN_ARGS="+IINIT=sw_isa_probe/build/imem.hex +DINIT=sw_isa_probe/build/dmem.hex"
# every line OK, "rodata2 0123456789ABCDEF", "PROBE END"
```

`UART_TX_PACED=1` (in `sw/uart.h`, honoured by `sw/Makefile` and
`sw_uart_echo/Makefile`) replaces the `TX_READY` poll with a software
delay longer than one frame, so a single byte is in flight at a time and
the TX FIFO never fills. It is a diagnostic, not a shipping setting: it
separates "the FIFO filled" from "the poll never returned" when a board
goes quiet in the middle of a line.

## Native RAM compliance test (`hw/native_mem_tb/`)

A second, independent harness that does **not** use the CPU — it
instantiates `native_ram` alone (a read/write D-mem and a read-only
I-mem) and drives it as a native `mem_req_t`/`mem_rsp_t` master from C++
(`native_mem_tb.cpp` is a small cycle-accurate BFM). It verifies the
native slave's protocol compliance in isolation: RVALID registered and
**held until RREADY** (not a one-cycle pulse — the key fix vs a naive
read), byte-strobed partial writes, back-to-back writes, single
outstanding (WREADY low while an unread read response is held), posted
store commits at the launch handshake, and read-only ignoring writes.

```
cd sim/hw/native_mem_tb && make run   # prints "N checks, 0 failures" on success
```

## AXI4-Lite RAM compliance test (`hw/ram_tb/`)

A third, independent harness (no CPU) that instantiates `axi4_lite_ram`
alone and drives it as an AXI4-Lite master from C++ (`ram_tb.cpp`). It
verifies the AXI RAM's protocol compliance in isolation
(registered/held BVALID + RVALID, AW-first / W-first orderings,
byte-strobed partial writes, back-to-back writes, single outstanding).
`axi4_lite_ram` is not instantiated in the Harvard sim/synth (native
`native_ram` serves I-mem/D-mem); `ram_tb` still exercises it standalone.

```
cd sim/hw/ram_tb && make run     # prints "N checks, 0 failures" on success
```

## Co-sim vs Spike (`cosim/quicksort/`)

Runs the same C-built ELF on Spike (upstream `riscv-isa-sim`, built locally
once via `build_spike.sh`, run with `--log-commits`) and on the Verilator
RTL sim, then `cosim_diff.py` diffs per-retire architectural effects (pc +
register write). Spike is the golden ISA reference; Zilx is already
implemented upstream (no patch). The RTL sim writes a per-retire trace to
`RTL_TRACE` (`sim_main.cpp`); the diff driver skips Spike's boot-ROM stub
retires and parks both sides at the halt self-loop.

Harvard co-sim needs `.data` at a non-zero VMA: Spike is a single
unified address space, so `.text`@0 and `.data`@0 would clobber each
other (the second LOAD segment overwrites the first at vaddr 0). The
linker places `.data` at DMEM 0x2000 (`sim/sw/link.ld`), and the cosim
`SPIKE_MEM` (`0x0:0x1000` for code, `0x2000:0x2000` for data+stack — the
real 8 KiB D-mem, so an access the hardware would silently alias makes
Spike trap here instead of quietly succeeding)
matches that split — so Spike's unified space and the RTL's split
I-mem/D-mem spaces both see the same absolute addresses.

```
make cosim     # build sw + Spike, run both, diff -> "PASS -- matched N retires"
```

The firmware is rebuilt with `PRINT_ARRAY=0` every time (the artefacts are
shared with `make sw`, which builds the printing variant): the first UART
access is where Spike stops being comparable, so a printing build would end
the diff before the sort it is meant to check. Pass `RISCV_PREFIX=...` to
`make cosim` and it is forwarded to the firmware build. Current result:
**PASS, 29625 retires matched** (256-element sort + verify + setup), then a
clean stop at the first UART MMIO access — a harness limit, not a CPU bug.

The Spike source tree, build, install, and per-run logs are gitignored;
only the harness is committed: `cosim_diff.py` + `build_spike.sh` at
`cosim/` (shared with the illegal-trap co-sim), and the `Makefile` at
`cosim/quicksort/`.

## Trap oracle (`sw_trap/`)

A standalone M-mode trap-exercise program (`trap_test.S`, built
`-march=rv32imac_zicsr_zifencei` so the toolchain emits csr/mret/wfi):
sets `mtvec` (direct), enables `mie.MSIE` + `mstatus.MIE`, and runs four
tests — ecall, load-misaligned, illegal instruction, and MSIP+WFI. The
handler (keyed on `mcause`) advances `mepc`+4 for sync traps / clears
MSIP + sets `mepc`=wfi+4 for the interrupt, leaving distinct D-mem
markers; `main` self-checks them and writes `0x600D` at D-mem 0x2000
(pass) or `0xBAD` (probe word 0x800). Run from `sim/`:

```
cd sw_trap && make                                      # -> build/imem.hex + build/dmem.hex
cd .. && make run RUN_ARGS="+IINIT=sw_trap/build/imem.hex +DINIT=sw_trap/build/dmem.hex"
```

## Illegal-trap co-sim (`cosim/ecall/`)

The Spike co-sim of a synchronous trap: a minimal illegal-instruction
program (`ecall_test.S`, `.word 0x0000007f`) run on Spike + RTL and
diffed with the shared `cosim_diff.py`. The faulting instruction is not
retired in either model. `ecall` itself is **not** Spike-comparable
(Spike hijacks an M-mode ecall as the htif host-call exit; MSIP has no
Spike slave at 0x1000_0000), so the ecall / MSIP+WFI paths are covered
only by the standalone oracle above.

```
cd cosim/ecall && make cosim   # -> "PASS -- matched 17 retires" (run from sim/)
```

## Timer oracle (`sw_timer/`)

A standalone M-mode program (`timer_test.S`, built
`-march=rv32imac_zicsr_zifencei`) exercising the machine timer interrupt:
sets `sp`/`mtvec` (direct), enables `mie.MTIE` + `mstatus.MIE`, writes
`mtimecmp=100` (mtime counts from 0, so `mtime>=100` fires ~cycle 100),
then `wfi`. The timer interrupt wakes it (`mepc=wfi+4`); the handler
checks `mcause[31:0]=0x8000_0007`, stores `0x07` as a marker at D-mem
0x2040, clears MTIP by writing `mtimecmp=0xFFFFFFFF`, and `mret`s.
`main` self-checks the marker and writes `0x600D` at D-mem 0x2000
(pass, probe word 0x800) or `0xBAD`. Run from `sim/`:

```
cd sw_timer && make                                   # -> build/imem.hex + build/dmem.hex
cd .. && make run RUN_ARGS="+IINIT=sw_timer/build/imem.hex +DINIT=sw_timer/build/dmem.hex"
```

## WFI-wake arbitration oracle (`sw_wfi_trap/`)

Regression for a WFI-halt deadlock: `wfi_halt_q` must clear on a pending
enabled interrupt, not on `take_interrupt` (which loses priority to a
sync trap) — otherwise a faulting instruction behind `wfi` left the halt
flag set, trap entry cleared `mstatus.MIE`, dropping the pending
interrupt and freezing the pipe unrecoverably. `wfi_trap_test.S` arms
`mtimecmp=400`, runs a 32-cycle `div` to fill F/D + skid, then `wfi`
followed immediately by an illegal encoding. On wake the illegal trap
wins arbitration first (marker `2` @0x2040, `mepc`+4), then the
still-pending timer interrupt is taken (marker `7` @0x2044, MTIP
disarmed); `main` checks both markers and writes `0x600D`/`0xBAD`.
`gen_hex.py` hand-encodes the program, so the regression runs without the
riscv32 toolchain:

```
cd sw_wfi_trap && python3 gen_hex.py
cd .. && make run RUN_ARGS="+IINIT=sw_wfi_trap/build/imem.hex +DINIT=sw_wfi_trap/build/dmem.hex"
```

## Files

- `sim_top.sv`    — sim wrapper (CPU + native I/D-mem +
  `axi4_lite_uart` + `clint_timer` + `msip_peri` MMIO slaves on the peri
  bus, behind the peri 1→3 xbar, + `mem_probe` generate block exposing a
  window of the data RAM to the VCD). Ports `clk_i`/`rstn_i`/
  `uart_rxd_i`/`led_o`; the RX pin is double-flopped as on the board, and
  a TX monitor writes every transmitted byte to `sim_uart_tx.txt`. UART
  clock/baud are the `UART_CLK_HZ`/`UART_BAUD` parameters. CPU taps stay
  internal, probed via the Verilator hierarchy.
- `sim_main.cpp`  — Verilator C++ harness (clk/rst, trace, three logs
  incl. writeback values, stall breakdown, WFI-halt invariant check,
  park/`MAX_CYC` stop, UART RX frame driver — see "UART console I/O").
- `imem.hex`/`dmem.hex` — Harvard oracle preload (code / data).
- `Makefile`      — build/run rules (`RUN_ARGS` forwards plusargs).
- `hw/native_mem_tb/` — native RAM compliance test.
- `hw/ram_tb/`       — AXI4-Lite RAM compliance test.
- `hw/uart_tb/`      — UART FIFO + IRQ compliance test.
- `cosim/`           — shared co-sim assets: `cosim_diff.py` +
  `build_spike.sh` + the local Spike build/install.
- `cosim/quicksort/` — RTL vs Spike golden ISA ref co-sim (see
  "Co-sim vs Spike").
- `cosim/ecall/`     — Spike co-sim of an illegal-instruction sync trap
  (see "Illegal-trap co-sim").
- `sw/`           — C → imem.hex + dmem.hex flow (see `sw/README.md`).
- `sw_trap/`      — standalone M-mode trap-exercise program
  (ecall/misaligned/illegal/MSIP+WFI, self-checking — see "Trap oracle").
- `sw_ifault/`    — instruction-access-fault oracle (jump outside the
  I-mem, check cause and mtval — see "Instruction-access-fault oracle").
- `sw_isa_probe/` — instruction/memory probe that reports without using
  the hex printer or any instruction under test (see "ISA / memory
  probe").
- `sw_timer/`     — standalone M-mode timer-interrupt program
  (MTIE+MIE, `mtimecmp=100`, WFI wake, self-checking — see "Timer oracle").
- `sw_wfi_trap/`  — WFI-wake arbitration regression (illegal-trap behind
  `wfi` + pending MTI; toolchain-free via `gen_hex.py` — see
  "WFI-wake arbitration oracle").
- `sw_uart_echo/` — UART echo + external-interrupt (MEIP) oracle, and the
  hardware bring-up program (see "UART echo + external-interrupt (MEIP)
  oracle").

Build artefacts (`obj_dir/`, `sw/build/`, `cosim/ecall/build/`,
`cosim/quicksort/*.log`, `*.vcd`, `*.log`, `sim_uart_tx.txt`) are
gitignored.