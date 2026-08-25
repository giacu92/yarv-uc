# CLAUDE.md

Guidance for Claude Code in this repo.

## Project

RV32IMAC + Zicsr + Zifencei RISC-V core for a **Gowin GW2AR-18C** FPGA (QFN88) on a Tang Nano 20k. Clock: 25 MHz single-ended from an MS5351M generator (CLK0, PIN10, LVCMOS33) — not the stock 27 MHz oscillator. **Active build: 40 MHz via on-chip rPLL** (`clk_core = clk_i × 8/5`, IDIV_SEL=4 / FBDIV_SEL=7 / ODIV_SEL=16, VCO 640 MHz, period 25 ns) — **closed at 40.281 MHz actual (2026-08-25)**. It took the two register stages to get here: the LSU request and the CSR read. Fallback to the 25 MHz bypass is three lines in `top_module` plus re-commenting the SDC generated clock and setting `global_freq 25.000` (recipe in the file); the bypass is also the diagnostic config, since it removes the rPLL from the picture entirely.

**Status:** fetch/decode/execute + LSU + Zicsr + trap/exception/interrupt implemented. **Harvard** memory system — dedicated read-only I-mem for fetch, native byte-strobed D-mem for LSU, AXI4-Lite only for peripherals. **Both memories are 16 KiB (`ADDR_W=14`)**: the GW2AR-18C has 46 BSRAM blocks = 828 Kb, so the earlier 2×64 KiB (1024 Kb) could not exist — each 16 KiB memory is 8 blocks (4 byte lanes × 2), 16 of 46 total. Loads/stores/Zilx/CSR ops retire via native D-mem (or peri bridge) with an **execute→decode forward path** (distance-1 RAW resolved same-cycle, zero bubble; no stall-on-RAW interlock).

**Machine-mode traps:** precise sync traps at execute commit — instruction access fault (mcause=1, mtval=unfetchable PC), illegal instr (mcause=2), ecall-M (11), ebreak (3), load/store addr-misaligned (4/6, mtval=bad EA); `mret` returns; `wfi`=halt-until-pending-interrupt; `fence`/`fence.i`=nop. `mtvec` direct+vectored; mepc/mcause/mtval on entry. Software interrupt (mcause=0x8000_0003) via `msip_peri` AXI4-Lite slave @0x1000_3000. Timer interrupt (mcause=0x8000_0007) via `clint_timer` (64-bit mtime/mtimecmp @0x1000_1000+). External interrupt (mcause=0x8000_000B) = OR of peripheral IRQs (UART today) → `meip_i`. Priority MEI>MSI>MTI. A trapping instruction is not retired (matches spec + Spike). Sim-verified (oracle + Spike cosim).

**Timing (2026-08-25):** the 40 MHz rPLL build **closes at 40.281 MHz actual**. How it got there, all measured at 25 MHz before the retarget: +2.2 ns of slack with nothing done (~27.7 MHz, limiter the regfile→forward mux) → +5.320 ns with the load byte offset latched (~28.9 MHz, limiter the store path into `mtimecmp`) → +10.152 ns with the LSU request registered (~33.5 MHz, limiter the CSR-address fan-out) → +12.577 ns with the CSR read registered (~36.5 MHz, limiter `regfile → forward mux → branch compare/target → PC redirect`). Constrained at 25 ns, PnR then found the rest: an Fmax measured under a loose constraint understates what the tool will do when actually pushed, which is worth remembering before concluding a target is out of reach. Next limiter if more is ever wanted: that branch/redirect path — compute PC-relative targets in decode (only `jalr` needs a register operand) or register the redirect at the cost of a cycle on taken branches. Legacy `VON_NEUMANN` build dropped — Harvard only.

CPU exposes 3 ports: native `imem` (RO), native `dmem` (byte-strobed), AXI4-Lite master `axi_peri`. Native→AXI conversion for peripherals done inside CPU by `axi4_lite_master_bridge`; board top is pure point-to-point wiring (no crossbar). LSU decodes `addr[PERI_ADDR_BIT]` itself (0→native D-mem, 1→peri bridge→0x1000_0000+). Only non-bus CPU output: `dbg_stall_o`→LED0.

**Key files:**
- `src/rtl/core/top_module.sv` — board top
- `src/rtl/core/rv32imac_zicsr_zifencei.sv` — CPU top
- `src/rtl/core/trap_unit.sv` — exception/interrupt entry + mret
- `src/rtl/utils/native_ram.sv` — Harvard I/D-mem native slave
- `src/rtl/utils/msip_peri.sv` — AXI4-Lite MSIP MMIO slave
- `src/rtl/utils/clint_timer.sv` — AXI4-Lite CLINT timer slave (64-bit mtime/mtimecmp)
- `src/rtl/utils/axi4_lite_uart.sv` — AXI4-Lite UART slave, TX+RX FIFOs (16 B), IRQ→mip.MEIP
- `src/rtl/bus/axi4_lite_xbar.sv` — 1→2 crossbar (unused, kept for reuse)
- `src/rtl/bus/axi4_lite_xbar_3.sv` — 1→3 peri crossbar (UART/timer/MSIP + DECERR for unmapped)
- `rv32imac_Zicsr_Zifencei.gprj` — Gowin IDE project
- `impl/rv32imac_Zicsr_Zifencei_process_config.json` — synth config
- `impl/gwsynthesis/`, `impl/pnr/` — synth/PnR outputs (PnR gitignored)

## Build flow (Gowin EDA)

IDE-only, no RTL Makefile. Toolchain on remote host `giacomo@192.168.10.36`: `gw_sh` at `/home/giacomo/gowin_ide/IDE/bin/gw_sh` (V1.9.11.03 Education). rsync repo to `~/gowin_proj/rv32imac_Zicsr_Zifencei/`. Errors/warnings in `impl/gwsynthesis/rv32imac_Zicsr_Zifencei_syn.rpt.html`.

### Synthesize
```bash
QT_QPA_PLATFORM=offscreen QT_OPENGL=software LIBGL_ALWAYS_SOFTWARE=1 gw_sh impl/synth_check.tcl
```
Gotcha: no-ops if `.vg`/report already exist — delete outputs by explicit filename first.

### Place & Route
Options in `impl/pnr/cmd.do` (GW2AR-18C, `-bit -tr -ph -timing`, `global_freq 40.000`); device opts in `impl/pnr/device.cfg`.
```bash
QT_QPA_PLATFORM=offscreen QT_OPENGL=software LIBGL_ALWAYS_SOFTWARE=1 gw_sh impl/pnr_check.tcl
```
Gotcha: `gw_sh -pnr -do ...` no-ops (invalid flag in this version) — use the Tcl wrapper. Also no-ops if outputs exist — delete by filename first. Outputs: `.fs`/`.bin`/`.binx`; timing in `.tr.html` ("Max Frequency Summary"). **SDC**: `src/phys/rv32imac_Zicsr_Zifencei.sdc` must be listed as a `<File type="file.sdc">` in the `.gprj` (not just referenced from `cmd.do`) or PnR falls back to unconstrained 100 MHz. `pnr_check.tcl` also forces `-global_freq 40.000`; the SDC's `create_generated_clock -multiply_by 8 -divide_by 5` on `clk_core` is the real constraint.

### Constraints (`src/phys/`)
`.cst`: `clk_i`→PIN10 (25MHz LVCMOS33), `rst_i`→PIN88 (**active-high** board reset S1, `PULL_MODE=DOWN` — released=run, pressed=reset; see [[board-reset]] memory), `uart_txd_o`→PIN69 / `uart_rxd_i`→PIN70 (BL616 USB-UART bridge), `led_o[0]`=stall, `led_o[3:1]`=counter.
`.sdc`: **40 MHz rPLL active** — `clk25`@25MHz on `clk_i` is the reference and `create_generated_clock ... -multiply_by 8 -divide_by 5` names the rPLL output `clk_core` (25 ns). Three places must agree or the reports constrain something the design does not run at: the rPLL parameters in `top_module`, this generated clock, and `global_freq` in `impl/pnr_check.tcl` + `impl/pnr/cmd.do`. History: 50→40→25(bypass)→35(rPLL)→25(bypass)→**40(rPLL, active, closed at 40.281 MHz)**. The 25 MHz retreat was forced by the trap+timer critical path; what made 40 reachable was registering the LSU request and the CSR read. A/B test proved the regfile primitive (BSRAM vs `registers` style) is NOT the Fmax limiter. Pre-forwarding the critical path was route-dominated (~65% route) CSR-address fan-out; post-forwarding (2026-08-24) the limiter is the regfile async read → decode forward mux (the bypass into D/E operands). `rst_i`/`led_o`/`uart_rxd_i` false-path (`uart_rxd_i` is an async pin feeding the board top's double-flop synchronizer — no launch clock to relate it to).

No lint config. Verilator sim in `sim/` (functional), `sim/hw/native_mem_tb/` (native RAM compliance), `sim/hw/ram_tb/` (AXI4-Lite compliance), `sim/cosim/quicksort/` (RTL vs Spike).

## Simulation (Verilator)

Builds fetch+decode+execute+native I/D-mem+peri bridge (Harvard only now). `--public-flat-rw` build (no per-stage debug ports).

- `sim/sim_top.sv` — wrapper preloading native I/D-mem via `$readmemh`, plusargs `+IINIT=` (default `imem.hex`) / `+DINIT=` (default `dmem.hex`). Exposes a `PROBE_LEN`-word D-mem window for VCD tracing. Wires peri bus through `axi4_lite_xbar_3`→uart+timer+msip. **UART RX stimulus**: `uart_rxd_i` is a real port, double-flopped exactly like `top_module` (board parity — before 2026-08-25 the sim drove `rxd_i` raw, so the board's synchronizer was never simulated). **UART TX monitor**: every byte pushed into the TX FIFO is logged to `sim/sim_uart_tx.txt` (tap on `u_uart.tx_push`) — that is how you read a serial program's output. UART clock/baud are overridable parameters `UART_CLK_HZ`/`UART_BAUD` (defaults 50 MHz/10 MHz = 5 clocks per bit, fast); pass `-GUART_CLK_HZ=25000000 -GUART_BAUD=115200` for the board's real 217-clocks-per-bit divisor.
- `sim/sim_main.cpp` — drives clk/rst, logs fetch/decode/execute-retire+writeback via internal taps. **UART RX driver**: `UART_RX="2000\r"` types that string into the serial console as real 8N1 frames (C escapes decoded). `UART_RX_PACED=0` ships frames back-to-back instead of waiting for RX-FIFO room — what a line-buffered terminal does with a pasted line, and the case the RX FIFO exists to survive. `UART_BIT_CYCLES=217` matches a board-accurate UART build. `NO_VCD=1` skips the waveform dump (a board-accurate run is millions of cycles = multi-GB VCD). Writes `sim/sim_top.vcd`. Stops on park detection (8 identical retires) or `MAX_CYC` (default 4000). `STAP()` prints a stall breakdown (RAW/DIV-REM/LSU-wait %). Checks the WFI-halt invariant on every run (see WFI oracle below) — prints `WFI-halt check: OK` or fails with `WFI-HALT FAIL`.
- `sim/imem.hex` + `sim/dmem.hex` — hand-crafted Harvard oracle: RAW hazards (now resolved by forwarding, not stall), LSU round-trip + load-use, byte/halfword sign/zero extend.
- `sim/program.hex` — legacy von-Neumann oracle, unused (file kept).
- `sim/Makefile` — `make run` (default oracle); `RUN_ARGS="+IINIT=... +DINIT=..."` for C programs.
- `sim/sw/` — C→two images via `riscv32-esp-elf-gcc` 14.2.0 (`-march=rv32imac -mabi=ilp32 -nostdlib -ffreestanding`, `medlow`, link script splits `.text`→IMEM ORIGIN=0 / `.data`→DMEM ORIGIN=0x2000). **Toolchain override**: `make RISCV_PREFIX=/home/giacomo/_toolchains/riscv32-ilp32d--glibc--stable-2024.05-1/bin/riscv32-buildroot-linux-gnu` (the esp toolchain is gone from this machine). Every firmware Makefile carries two flags for that *linux/glibc* toolchain: **`-no-pie -Wl,-N`** (its `ld` emits a PT_PHDR segment the flat `link.ld` MEMORY layout does not cover — "PHDR segment not covered by LOAD segment") and **`-fno-pie`** (it defaults to PIE, so gas expands `la sym` into a GOT load and gcc emits PC-relative data addressing; both break the Harvard split — `link.ld` requires medlow ABSOLUTE `lui`+`addi` so a data address computed in `.text` lands in D-mem. Without it `sw_trap` loaded `mtvec` from an uninitialised `.got` word and reboot-looped). Default `main.c`: recursive quicksort over a **256-word** array filled by a deterministic LCG (same sequence on Spike and RTL; pseudo-random so the recursion stays near log2(N) deep instead of degenerating to N frames on sorted input), printed before and after the sort, returns `0x600D` (pass) / `0xBAD` (fail). `PRINT_ARRAY=0` compiles the printing out — the co-sim needs it, since the first UART access is where Spike stops being comparable and a printing build would end the diff before the sort.

```bash
cd sim && make run                    # Harvard oracle
make sw-run                           # build C prog + run (from repo root)
```
Build artefacts gitignored.

### Native RAM compliance (`sim/hw/native_mem_tb/`)
BFM master driving `native_ram` directly. Checks RVALID registered & held until RREADY, byte-strobed partial writes, back-to-back writes, single-outstanding, posted-store commit at launch-accept, read-only ignoring writes.
```bash
cd sim/hw/native_mem_tb && make run     # "N checks, 0 failures"
```

### AXI4-Lite RAM compliance (`sim/hw/ram_tb/`)
BFM master driving `axi4_lite_ram` (peri-side only in Harvard build). Checks registered BVALID held under delayed BREADY, AW/W ordering, byte strobes, back-to-back writes, single-outstanding, RVALID held under delayed RREADY.
```bash
cd sim/hw/ram_tb && make run
```

### Co-sim vs Spike (`sim/cosim/quicksort/`)
Runs the same C ELF on Spike (`--log-commits`, built via `build_spike.sh`) and Verilator RTL; `cosim_diff.py` diffs per-retire pc + register write. Harvard requires `.data` at non-zero VMA (`DMEM ORIGIN=0x2000`) so Spike's unified space holds `.text`@0/`.data`@0x2000 disjoint. `SPIKE_MEM`: `0x0:0x1000` code, `0x2000:0x2000` data+stack — the real 8 KiB D-mem, so an access the hardware would silently alias makes Spike trap instead of quietly succeeding. The firmware is rebuilt with `PRINT_ARRAY=0` for the run, and `RISCV_PREFIX` is forwarded if given.
```bash
make cosim     # -> "PASS -- matched N retires"
```

### Trap oracle + illegal-trap cosim (`sim/sw_trap/`, `sim/cosim/ecall/`)
`trap_test.S` (built `-march=rv32imac_zicsr_zifencei`): standalone M-mode program exercising ecall/load-misaligned/illegal/MSIP+WFI; self-checks, writes `0x600D`/`0xBAD` at D-mem 0x2000.
```bash
cd sw_trap && make
cd .. && make run RUN_ARGS="+IINIT=sw_trap/build/imem.hex +DINIT=sw_trap/build/dmem.hex"
```
`sim/cosim/ecall/`: Spike cosim of a sync trap (illegal instr `.word 0x0000007f`), shared `cosim_diff.py`. ecall itself isn't Spike-comparable (Spike hijacks M-mode ecall as htif exit; MSIP has no Spike slave).
```bash
cd cosim/ecall && make cosim   # -> "PASS -- matched 17 retires"
```

### WFI-wake arbitration oracle (`sim/sw_wfi_trap/`)
Regression for a WFI-halt deadlock: `wfi_halt_q` must clear on `int_pending`, not `take_interrupt` (which loses priority to a sync trap) — otherwise a faulting instr behind `wfi` left the halt flag set, trap entry cleared `mstatus.MIE`, dropping `int_pending` and freezing the pipe unrecoverably. `wfi_trap_test.S` arms `mtimecmp=400`, runs a 32-cycle `div` to fill the pipe, then `wfi` + an illegal instr. On wake the illegal trap wins arbitration first (marker @0x2040), then the pending timer interrupt is taken (marker @0x2044). `gen_hex.py` hand-encodes the program (no toolchain needed).
```bash
cd sw_wfi_trap && python3 gen_hex.py
cd .. && make run RUN_ARGS="+IINIT=sw_wfi_trap/build/imem.hex +DINIT=sw_wfi_trap/build/dmem.hex"
```

### Timer oracle (`sim/sw_timer/`)
`timer_test.S`: arms `mtimecmp=200`, `wfi`s, wakes on MTIP (mcause=0x8000_0007), handler stores marker=7 @0x2040, clears MTIP (`mtimecmp=0xFFFFFFFF_FFFFFFFF`). Not Spike-comparable (no CLINT slave in Spike) — standalone oracle only.
```bash
cd sw_timer && make
cd .. && make run RUN_ARGS="+IINIT=sw_timer/build/imem.hex +DINIT=sw_timer/build/dmem.hex"
```

### UART FIFO + IRQ compliance (`sim/hw/uart_tb/`)
BFM master driving `axi4_lite_uart` directly, with a continuous 8N1 decoder on `txd_o` and a frame driver on `rxd_i` (10 clocks per bit). Checks: TX FIFO ships N queued bytes in order with no polling in between; TX_READY drops when full and a write to a full FIFO is **held** until room appears (measured in cycles, and the byte still ships in order); an RX burst inside the depth is fully retained in order with no overrun; one frame past the depth is dropped and latches RX_OVERRUN while the queued bytes survive; reading an empty RX FIFO pops nothing (no pointer underflow); IRQ is level-sensitive and gated by CTRL (no interrupt until an IE is written, deasserts when software drains).
```bash
cd sim/hw/uart_tb && make run     # "146 checks, 0 failures"
```

### UART echo + external-interrupt (MEIP) oracle (`sim/sw_uart_echo/`)
`uart_echo.c`: echoes 4 bytes by polling, then enables `CTRL.RX_IE` + `mie.MEIE` + `mstatus.MIE` and echoes 4 more from an interrupt handler (`__attribute__((interrupt("machine")))`), sleeping in `wfi` in between. Writes `0x600D`/`0xBAD` to D-mem **0x3000** (not 0x2000 — `.rodata` is linked there). The only end-to-end test of MEIP: `uart_irq_o`→`meip_i`→`mip.MEIP`→`trap_unit`→interrupt entry, plus the `wfi` wake on an external interrupt. Doubles as the hardware bring-up program: type 8 characters on the board and phase 1 tells you whether bytes reach the CPU at all, phase 2 whether the interrupt path works.
```bash
cd sw_uart_echo && make
cd .. && UART_RX='abcdefgh' make run RUN_ARGS="+IINIT=sw_uart_echo/build/imem.hex +DINIT=sw_uart_echo/build/dmem.hex"
# -> serial log "ECHO / abcd / IRQ / efgh / GOOD", wb x15 = 0x0000600d
```

### RVC scramble-bit oracle (`sim/sw_rvc_scramble/`)
Per-scramble-bit decode oracle for `c_expand()`: feeds every RVC scrambled-immediate form (c.addi4spn/c.addi16sp/c.li/c.addi/c.lui/c.andi/c.srli/c.srai/c.lw/c.sw/c.lwsp/c.swsp/c.j/c.jal/c.beqz/c.bnez) with each immediate bit set in isolation, self-checks, writes `0x600D`/`0xBAD` @0x2000. The assembler (riscv32-esp-elf-gcc, `-march=rv32imac_zicsr_zifencei`) emits the spec-correct compressed encodings; the core's `c_expand()` decoder is the thing under test. A `mtvec` trap handler catches any mis-decoded jump/offset as FAIL (no hang). This is the guard for the scramble-bit class of bugs — cosim/oracles don't toggle those bits (see [[c-expand-rvc-immediate-scramble-bugs]]). It caught the c.addi4spn `nz[3]`/`nz[2]` swap that manual review had dismissed. Pass = `wb x6 = 0x0000600d` in the execute log / probe word 0x800 = `0x600D`.
```bash
cd sw_rvc_scramble && make
cd .. && make run RUN_ARGS="+IINIT=sw_rvc_scramble/build/imem.hex +DINIT=sw_rvc_scramble/build/dmem.hex"
```

### Instruction-access-fault oracle (`sim/sw_ifault/`)
`ifault_test.S` jumps to 0x100000 (far outside the 16 KiB I-mem) and checks that exactly one trap arrived with `mcause=1` and `mtval` equal to the address jumped to; writes `0x600D`/`0xBAD` @0x2000. The handler does **not** `mret` to `mepc` — the faulting address is still unfetchable — it rewrites `mepc` to a known label, which is what a real handler must do. Toolchain-free apart from the assembler.
```bash
cd sw_ifault && make
cd .. && make run RUN_ARGS="+IINIT=sw_ifault/build/imem.hex +DINIT=sw_ifault/build/dmem.hex"
```

### ISA / memory probe (`sim/sw_isa_probe/`)
Board bring-up probe that reports through fixed strings and a bit-dump built only from register-register `AND` and mask doubling — never through the hex printer or any instruction under test, because the printer was the thing lying. Covers `c.andi` (immediates 15/7/3/1, hand-encoded halfwords so the encoding is exactly the one named) against the 32-bit `andi`, the shifts, register-register `AND`/`OR`, a byte load at each lane, and a memory matrix: `lw` / `lbu` at constant offsets / `lbu` at a **computed** address / `lhu` / byte stores read back, on one word in `.rodata` and one in `.data`. The constant-offset-vs-computed-address split is what isolated the load byte-select bug (a `const` read at a constant index gets folded at compile time and proves nothing; only the computed index hits memory).
```bash
cd sw_isa_probe && make UART_TX_PACED=1     # paced TX: no TX_READY poll, FIFO never fills
cd .. && make run RUN_ARGS="+IINIT=sw_isa_probe/build/imem.hex +DINIT=sw_isa_probe/build/dmem.hex"
```
`UART_TX_PACED=1` (in `sim/sw/uart.h`, honoured by `sim/sw/Makefile` and `sim/sw_uart_echo/Makefile`) replaces the `TX_READY` poll with a software delay longer than a frame, so only one byte is ever in flight. It is a diagnostic, not a shipping configuration: it separates "the FIFO filled" from "the poll never returned" when a board goes quiet mid-line.

## Code formatting (Verible)

Policy in `verible.flags` (4-space indent, 100-col, aligned ports/params/assignments) — edit that file, not CLI overrides.
```bash
make format        # reformat in place
make format-check  # CI: exit 1 if unformatted
make format-diff
```
Not in apt; static binary on build host at `~/tools/verible` → `~/.local/bin`.

## Architecture

Built bottom-up. Every RTL file: `import rv32_pkg::*;` + `` `resetall `` / `` `default_nettype none `` / `` `timescale 1ns/1ps ``.

### Naming
Ports `_i`/`_o`. Flops `_q`, next-state comb `_d`. Instances `u_*`. Stage debug taps `fe_`/`de_`/`ex_`, internal only (`dbg_stall_o` is the sole exported one).

### Files
- **`rv32_pkg.sv`** — `XLEN=32`; `mem_req_t`/`mem_rsp_t`. `PERI_ADDR_BIT`=28; peri windows `UART_BASE/SIZE`=0x1000_0000/4K, `MTIMER_BASE/SIZE`=0x1000_1000/8K, `MSIP_PERI_ADDR/SIZE`=0x1000_3000/4K. Decode types: opcodes (incl `OPC_AMO`), `alu_op_t` (incl `ALU_LX`), `wb_src_t` (incl `WB_CSR`), `csr_op_t`/`csr_addr_t` (MSTATUS/MISA/MIE/MTVEC/MSCRATCH/MEPC/MCAUSE/MTVAL/MIP/MCYCLE/MINSTRET), `sys_op_t`, `MCAUSE_*` codes, `MSTATUS_*` bit positions/masks, `MTVEC_DIRECT/VECTORED`. Packed `de_t` D/E struct.
- **`fetch_stage.sv`** — PC + F/D reg + 1-entry skid (2-deep FIFO), single-outstanding overlap-prefetch. `stall_i` (decode) / `branch_valid_i`+`branch_addr_i` (execute redirect incl. trap/mret/interrupt). **`IMEM_ADDR_W` range check**: a PC outside the implemented I-mem issues no bus request (the memory decodes only those bits, so the read would alias back into the image and execute it) and instead enqueues a FIFO entry flagged `fe_fault_o`, in the slot a response would have taken. The parameter is forwarded from the top level and must match the instantiated `native_ram`.
- **`decode_stage.sv`** — RV32I+M+C+Zilx+Zicsr. Expand-then-decode (`c_expand()` RVC→32-bit, one decoder). Hold buffer for upper compressed half. RVC funct3=100 group (c.srli/srai/andi CB + c.sub/xor/or/and CA): selector = `c[11:10]` (00 srli / 01 srai / 10 andi / 11 arith), arith sub-group = `c[6:5]` (00 sub / 01 xor / 10 or / 11 and); rd=rs1=`crs1`={2'b01,c[9:7]}, rs2=`crs2`={2'b01,c[4:2]}; `c[12]` is shamt[5]/imm[5] (NOT a selector). **Fixed 2026-08-25**: the table previously keyed on `{c[12],c[11:10]}` and used `crd`=c[4:2] (imm bits, not rd'), so c.andi decoded as c.sub and YarvMon's `get_line` falsely asserted RX_READY — latent because no cosim/oracle emits funct3=100 (only YarvMon UART polls hit it; see [[c-expand-funct3-100-not-cosim-covered]]). **Also fixed 2026-08-25 (RVC immediate scramble):** c.addi16sp was missing `nzimm[4]=c[6]` (dropped, zero-extended — stack-adjust multiples of 16 with bit4 set decoded as 0); c.jal + c.j had `imm[7]`/`imm[5]` swapped (`c[6]`/`c[2]` in wrong joff slots — spec is `imm[7]=c[6]`, `imm[5]=c[2]`). Both latent: the prior "verified vs c.j 16=0xA801" check only exercised `imm[4]=c[11]`, never the `c[6]`/`c[2]` bits; no cosim/oracle hits those scramble-bit patterns. **c.addi4spn was ALSO swapped** (`nz[3]`/`nz[2]`): code had `nz[3]=c[6]`,`nz[2]=c[5]` but spec `nzuimm[5:4|9:6|2|3]=instr[12:11|10:7|6|5]` is `nzuimm[2]=c[6]`,`nzuimm[3]=c[5]` — so nzuimm=4 decoded as 8 and vice versa. Fixed same day; caught by the `sw_rvc_scramble` per-bit oracle (a manual review had wrongly dismissed it as correct). Zilx (`OPC_AMO` funct5 10010/11010; 11110 illegal) swaps rs1/rs2, computes `mem_shamt`. Zicsr (`OPC_SYSTEM` funct3≠0) decodes csr_op/csr_wren/csr_addr, `wb_src=WB_CSR`. `OPC_SYSTEM` funct3=0: ecall/ebreak/mret/wfi → `sys_op` (legal). `OPC_MISC_MEM`: fence/fence.i → `sys_op` (legal nop). Unknown → `dec_illegal=1`, `MCAUSE_ILLEGAL`. **`fe_fault_i`** (fetch out of range) outranks every source: no word exists to decode, so it emits a precise trap with `MCAUSE_INSTR_ACC` and `mtval` = the unfetchable PC, and drops any stashed half — if a spanning instruction was waiting for its upper half, that half is exactly what faulted. `stall_o` = hold-term | execute stall | WFI-halt — **no RAW term** (forwarding resolves it). **Execute→decode forwarding**: `fwd_rs1`/`fwd_rs2` inject `ex_wb_data_i` into `de_d.rs1_data`/`rs2_data` when `ex_wb_en_i` & addr matches — distance-1 RAW zero-bubble. Legacy `raw_haz` interlock disabled.
- **`reg_file.sv`** — 32×32 BSRAM, async read×2/sync write×1, x0 hardwired. Confirmed NOT the Fmax limiter (A/B vs `registers` style, identical). No runtime reset (BSRAM single write port); sim zero-inits via `` `ifdef VERILATOR ``; HW relies on BSRAM power-up + write-before-read.
- **`csr_regfile.sv`** — 11-entry Zicsr M-mode subset. **Registered read** (decode addr presented one cycle, data out the next) + sync write (execute RMW). The read used to be asynchronous, which put the read mux in the same cycle as everything it feeds and made `de_q.csr_addr → fetch pc_q` the critical path (a CSR value forwarded into an address computation and on into the redirect). Execute holds a CSR op one extra cycle (`EX_CSR_WAIT`) to collect the data; measured cost **zero cycles** — 1600 CSR reads in a back-to-back benchmark came out at 4432 cycles either way, and every oracle is unchanged, because at 2.2 cycles per instruction (single-outstanding I-mem) the extra execute cycle sits inside the fetch bubble that is already there. Consequence to remember: `mcycle`/`minstret` read back the value as of the previous cycle, a one-cycle offset on a free-running counter. FF+LUT mux (sparse, not BSRAM). CSRs reset to architected values (`misa`=0x40002105 RO). Unimplemented addrs read 0/ignore writes. `mcycle`/`minstret` free-running. Trap-write bundle ports (priority over RMW) + `msip_i`/`mtip_i`/`meip_i` (mip bits) + comb taps `mtvec_o`/`mepc_o`/`mstatus_o`/`mip_o`/`mie_o` for the trap unit. `mstatus` RMW forces MPP=2'b11 (WARL, M-only); `mtvec` RMW masks MODE.
- **`alu.sv`** — combinational RV32I + single-cycle MUL (DSP) + multi-cycle DIV/REM (32-iter restoring FSM) + Zilx EA (`a + (b<<shamt)`).
- **`trap_unit.sv`** — combinational exception/interrupt entry + mret, peer of execute at CPU top. Consumes CSR taps + execute triggers (sync_trap/mret/take_interrupt, cause/tval/pc); produces fetch redirect (mtvec BASE, BASE+4*code vectored, or mepc for mret) + CSR trap-write bundle. `int_pending_o = mstatus.MIE & (MEIP&MEIE | MSIP&MSIE | MTIP&MTIE)`; `int_cause_o` selects MEI>MSI>MTI (all three wired). mstatus: entry MPIE←MIE/MIE←0/MPP←11; mret MIE←MPIE/MPIE←1/MPP←11 (M-only, so MPP is effectively read-only 2'b11).
- **`execute_stage.sv`** — selects operands, drives DIV/REM + LSU via unified FSM (`EX_IDLE`/`EX_MEM_LAUNCH`/`EX_DIV_BUSY`/`EX_MEM_WAIT`/`EX_CSR_WAIT`), writes back ALU/PC4/load/old-CSR, resolves branches+redirect, drives native LSU, CSR RMW. **LSU register stage** (2026-08-25): `EX_IDLE` only *captures* the request — effective address, lane-shifted store data, byte strobes, peri/D-mem select — into flops; `EX_MEM_LAUNCH` drives the bus from those flops until the slave accepts. Before this the request came straight off `alu_result`, putting `regfile → forward mux → adder → strobe decode → memory port` in one cycle with the bus on the end of the deepest chain in the design; it closed on paper and failed on silicon (quicksort stopped after 17 characters, at the first TX-FIFO-full poll loop, while the same program in simulation at the same baud printed all 5781 bytes). Cost one cycle per access (quicksort 59318 → 63238 cycles, IPC 0.500 → 0.469); bought +4.8 ns of slack and moved the critical path off the LSU entirely. The mirror change on the return path (latch `rdata`, align and retire the next cycle, so the writeback and the forward source are flop outputs) was implemented and measured — another cycle per load, 68014 cycles / IPC 0.436 — and **not kept**: with the request registered the board runs correctly and slack is +10.152 ns with the critical path far from the LSU, so it bought nothing. Reach for it only if a symptom points at the `rdata → shift → sign-extend → writeback mux → forward mux` chain again. **Posted store**: retires on the launch accept, commits same edge. Loads wait in `EX_MEM_WAIT` until `rvalid`. LSU steers `addr[PERI_ADDR_BIT]`. CSR: `csr_new`=RW:src / RS:`old|src` / RC:`old&~src`. Load alignment: shift by **`mem_addr_q[1:0]`**, the registered effective address from the capture cycle, then sign/zero-extend. **It must NOT be `alu_result[1:0]`** — that was the 2026-08-25 silicon bug: `alu_result` is combinational out of the D/E operands, which the execute→decode forward path feeds, so reading it in the response cycle demanded that the whole `regfile → forward mux → adder` chain still be settled and unchanged a cycle later. On hardware it was not: a load whose address came from a distance-1 forward (`add` immediately followed by `lbu`, which is what indexing a table with a computed index compiles to) read the right word but selected **byte 0** instead of the addressed byte. Simulation could never show it — there the chain settles inside the cycle whatever its depth. Symptom on the board: `hex[(v >> i) & 0xF]` returned `hex[i & ~3]`, so every hex value printed came out with the low two bits of each nibble cleared (`0x0123ABCD` → `0x000088CC`), which looked like corrupted CSRs, a broken trap path and a dead interrupt controller for half a day. A `` `ifdef VERILATOR `` assertion now checks the premise the flop relies on (no slave answers a read in the accept cycle). **Trap machinery**: `freeze = stall_i | wfi_stall`; sync traps fire in `EX_IDLE` (never launch on misaligned) — `sync_trap_req` exports to trap unit, normal wb/mem/csr/branch suppressed; `mret` retires + redirects to mepc; `take_interrupt` suppresses next instr at retire boundary or on WFI wake (mepc=wfi+size); WFI retires once then halts until `int_pending`. Trapping instr not retired (matches spec+Spike). Exports `ex_wb_en_o`/`ex_wb_addr_o`/`ex_wb_data_o` to decode same-cycle, feeding the forward path.
- **`rv32imac_zicsr_zifencei.sv`** — CPU top: fetch+reg_file+csr_regfile+decode+execute+trap_unit. 3 ports (native imem/dmem + AXI4-Lite `axi_peri`; peri bridge lives inside CPU). Plus `msip_i`/`mtip_i`. `trap_unit` combinational peer of execute. Only non-bus output: `dbg_stall_o`.
- **`top_module.sv`** — board top. `clk_core=40 MHz` via on-chip rPLL (25×8/5, single clock domain, no CDC); reset sync gated on `pll_lock`. Fallback: comment the rPLL out, `clk_core=clk_i=25 MHz`, `pll_lock=1'b1` (recipe in the file). Harvard: native `u_imem`(RO)/`u_dmem` on CPU ports; `axi_bus_peri`→`axi4_lite_xbar_3`→UART+timer+MSIP; their irq/mtip/msip feed CPU inputs. `CLK_CORE_HZ=40_000_000` feeds UART's `CLK_FREQ_HZ` and **must track the rPLL** — at 40 MHz BAUDDIV resets to 346 → 115 274 Hz (+0.06% of 115 200); get it wrong and the line is at the wrong baud, which on a board reads as a dead core. `uart_rxd_i` double-flopped before the UART (async pin, single fabric domain). `led_o[0]`=stall, `led_o[3:1]`=counter.
- **`native_ram.sv`** — Harvard native slave, `READ_ONLY` param, `ADDR_W=14` (16 KiB) in both `top_module` and `sim_top` — they must match or the sim stops modelling the board. Storage carries `syn_ramstyle`/`syn_romstyle`/`syn_noprune` (the GowinSynthesis spellings) next to the Vivado-style `ram_style`; note none of them pin the *depth*. **GowinSynthesis sizes an inferred ROM from its `$readmemh` content, not from the declared depth**, so an image-sized I-mem lets every fetch above the image alias back into real instructions and a wrong redirect runs silently. Firmware images are therefore padded to the full declared depth with `ebreak` (`bin2hex.py --pad-words/--pad-value`, `IMEM_PAD_WORDS=4096`); zero would also trap but a run of zero words reads as "no init" and can be dropped again, and `mcause=3` (breakpoint) distinguishes a wander into the padding from `mcause=2` on genuine garbage. Mirrors `axi4_lite_ram` handshake (`wready` gating, RVALID held until RREADY, `bvalid=0`, no addr latch — read-launch latches `rdata_q` at accept).
- **`msip_peri.sv`** — AXI4-Lite MMIO, 1-bit MSIP reg @`MSIP_PERI_ADDR`. Write bit[0] sets/clears mip.MSIP. Protocol mirrors `axi4_lite_ram`.
- **`clint_timer.sv`** — AXI4-Lite CLINT (`MTIMER_BASE`, 8 KiB). 64-bit free-running `mtime` (RO) + 64-bit `mtimecmp` (RW, resets all-ones), 4×32-bit words (lo/hi @ +0/+4, +8/+0xC). `mtip_o = mtime>=mtimecmp`. **Two-stage pipelined compare** (stage-1: parallel `ge_hi`/`eq_hi`/`ge_lo`; stage-2: `ge_hi | (eq_hi & ge_lo)`) to cut the 64-bit carry chain off the timing path — `mtip_o` delayed 2 cycles (harmless, level IRQ). Software must arm `mtimecmp` hi=all-ones → lo → real hi (else spurious MTIP in the gap). `mtime` writes ignored.
- **`axi4_lite_uart.sv`** — AXI4-Lite UART, 8N1, **TX + RX FIFOs** (`TX_FIFO_DEPTH`/`RX_FIFO_DEPTH`, default 16, powers of two — ring buffers with an extra pointer bit for full-vs-empty, LUT-RAM/flops, not BSRAM). `TXDATA` write is **held** when the FIFO is full — `awready` drops for that address and the write commits only once the engine frees a slot (bounded by one frame); it used to be dropped-with-OKAY, which made a lost byte indistinguishable from a byte never written and produced silently truncated output, `RXDATA` read pops (read-to-consume; a read of an empty FIFO pops nothing), `STATUS` = TX_READY (FIFO has room) / RX_READY (FIFO non-empty) / RX_OVERRUN (sticky, byte arrived with the FIFO full; cleared by an RXDATA read), `CTRL` = TX_IE/RX_IE, `BAUDDIV` (applied only when both engines are idle). Level IRQ, both IEs reset to 0. **Why FIFOs (2026-08-25)**: with a single-byte RX buffer a full-duplex echo program loses input — echoing a byte costs a whole frame time (87 µs at 115200), so every byte arriving during the echo was dropped. A terminal shipping a typed line in one burst made YarvMon look like it ignored every command. Reproduced in sim with `UART_RX_PACED=0`, fixed by the FIFOs, guarded by `sim/hw/uart_tb`. `rxd_i` must be handed an already-synchronized signal (the caller double-flops it).
- **`axi4_lite_master_bridge.sv`** — `mem_req_t`/`mem_rsp_t`↔AXI4-Lite, single FSM, single outstanding. `bvalid` on B handshake. Peri-only now (inside CPU).
- **`axi4_lite_xbar.sv`** — 1→2 crossbar by `addr[SEL_BIT]` (default 28). Unused now, kept for reuse.
- **`axi4_lite_xbar_3.sv`** — 1→3 crossbar, 3 compile-time BASE/SIZE windows. Unmapped peri address → local **DECERR terminator** (was previously left with ready low, parking the LSU forever).
- **`mem_arbiter.sv`** — deleted (was fetch/LSU arbiter for dropped VON_NEUMANN build).
- **`axi4_lite_ram.sv`** — AXI4-Lite slave, single-beat, protocol-compliant (`ram_tb`). BVALID registered & held until B handshake. Single-outstanding, byte-strobed via BSRAM byte enables. Von-Neumann mem slave / Harvard peri-side (kept, reusable).

### Fetch behaviour
2-deep FIFO (F/D head + 1-entry skid). Issues only when FIFO has room; accepts responses whenever there's room (lands in skid if F/D full). Harvard: fetch owns the I-mem port uncontended — skid just overlaps F/D-head-stalls. ~2 cyc/instr steady state (single-outstanding). Skid gave 15-20% cycle-count improvement over no-skid (measured on oracle+Zilx quicksort). Redirect kills F/D+skid, sets new `pc_q`. Compressed: fetch always reads 32-bit words; decode handles expansion/odd-half alignment.

### Decode behaviour
Source priority: spanning stitch > compressed hold > odd-half target > fresh low half. RVC spanning (32-bit instr split across word boundary) handled: low half stashed, stitched with next word's upper half (1 bubble, `span_wait`). `decoded_valid` excludes wait states. Deferred/traps in execute: unknown opcode (`MCAUSE_ILLEGAL`), `OPC_AMO` funct5 11110/sfence.vma (no VM). Legal (decode to `sys_op`, retire in execute): ecall/ebreak/mret/wfi/fence/fence.i. Zicsr decodes and retires fully.

### Hazard resolution (execute→decode forwarding)
`fwd_rs1`/`fwd_rs2` fire when execute retires a writeback to a register the decoding instr reads (x0 excluded): inject `ex_wb_data_i` into D/E operands instead of the stale async regfile read — zero bubble. Covers ALU-RAW, div-done-then-use, branch-on-dependent, load-use (the load's `EX_MEM_WAIT` holds the consumer in decode via `stall_i`; the load's `wb_en` pulse on `rvalid` drives the forward). Distance-2+ hazards: harmless, regfile async read returns the already-committed value. Legacy `raw_haz` bubble interlock **disabled**.

**Rule the forward path imposes on the rest of the datapath** (largely defused by the LSU register stage above, but still the rule to think with): a combinational value derived from the D/E operands (anything downstream of `alu_result`) may be consumed **only in the cycle it is produced**. Anything a later cycle needs must be latched when it is produced. The operands can come from the bypass, so such a value sits at the end of the design's critical path; simulation settles it regardless of depth, silicon does not. This is exactly how the load byte-select bug got in (see `execute_stage.sv` above), and it is the first thing to check when hardware and simulation disagree. Audited and correct today: `store_wstrb` / `store_wdata` / `mem_req.addr` (all consumed in the launch cycle), `sync_tval` on a misaligned trap (same cycle, `EX_IDLE`), the trap bundle payload (same cycle as the trigger).

**Known limitations:**
- Forward path is distance-1 only (single in-order retire slot); correct because execute retires ≤1 writeback/cycle in order.
- M-mode only (no S/U, no medeleg/mideleg, no PMP). **Instruction access fault implemented** (fetch outside `IMEM_ADDR_W`); instruction-address-misaligned is deliberately absent — with the C extension IALIGN=16, `jalr` clears bit 0 by definition and every branch offset is even, so an odd instruction address cannot arise. Cross-word sub-word accesses unhandled. Timer + external interrupt sourced; MEIP is a single ORed level (only UART today, no PLIC — ISR must poll to find source). Unimplemented CSR addrs still silently read 0/ignore writes (no illegal-instruction trap).
- WFI halts forever if no enabled interrupt ever arrives (legal). `fence.i`/`fence` are nops (Harvard has no D→I write path — no self-modifying code).
- Harvard: I-mem holds `.text`/`.text.init` only; `.rodata`/`.data`/`.bss`/stack live in D-mem. **Every `link.ld` must collect the small-data sections** (`.srodata*`/`.sdata*`/`.sbss*`) into `.rodata`/`.data`/`.bss`: RISC-V gcc puts any constant or variable up to `-msmall-data-limit` (8 bytes) there, and since the image is extracted with `objcopy -j .rodata -j .data`, an uncollected `.srodata` never reaches the D-mem hex — a 4-byte `const` then reads 0 at runtime while the same constant folded at compile time reads correctly. Fixed 2026-08-25 in all five scripts. **`.bss` is zeroed by `start.S`** at boot from `__bss_start`/`__bss_end` (word loop, both ends aligned by `link.ld`) — before that it held power-up BSRAM contents on hardware while reading as zero in simulation, which cost a false "TRAP OK" in the MEIP oracle and made YarvMon's state depend on power-up junk. **`sp = 0x4000`** (top of the 16 KiB D-mem): the D-mem decodes only `ADDR_W` bits, so a stack pointer above the top aliases silently into the data it is meant to sit clear of (the old `sp = 0x10000` "worked" only by aliasing). `.data` linked at DMEM ORIGIN 0x2000 (not 0) so Spike co-sim can hold `.text`@0/`.data`@0x2000 disjoint. Requires `medlow` absolute addressing.

### Open work
- **Silicon bring-up done (2026-08-25).** The board runs quicksort (256 values printed), YarvMon and the MEIP oracle. Getting there turned up five real defects, four of which simulation structurally could not show: the load byte-select reading a live combinational value a cycle late (silicon-only), the I-mem ROM being sized from its `$readmemh` content so a stray fetch aliased into real code instead of trapping (silicon-only), `sp` above the top of a memory that decodes fewer bits (silicon-only), small-data sections never reaching the image (both, but latent), and a dropped-with-OKAY UART write (both, but invisible). The pattern worth keeping: when hardware and simulation disagree, suspect a value whose *lifetime* differs between the two, and instrument so the reporting path is not itself under test (`sim/sw_isa_probe/`).
- Harvard split done. Perf: quicksort 4711 cyc / IPC~0.46 / 9.5% stall (Harvard) vs 5863/0.37/16% (von-Neumann) — −16% cycles (32-element array; the program is 256 elements now). Cosim vs Spike: quicksort matches **29625 retires** (256-element sort + verify + setup, `PRINT_ARRAY=0`) then **stops at the first UART MMIO access** — Spike has no UART/CLINT/MSIP slave and is instruction-based (no cycle timing), so `uart_puts`'s TX_READY poll is un-cosim-able retire-by-retire; the diff driver (`cosim_diff.py`) detects Spike's trap-to-entry on unmapped MMIO and reports a clean stop (harness gap, not a CPU bug). ecall cosim PASS 17 matched.
- I-mem `INIT_FILE` must point at real firmware for meaningful synthesis (empty init folds the pipeline to dead code). `top_module.sv` `u_imem`/`u_dmem` load the **YarvMon** default product firmware: `sim/sw-yarvmon/build/imem.hex` (`.text`→I-mem 0x0) + `sim/sw-yarvmon/build/dmem.hex` (`.rodata`/`.data`→D-mem word 0x800 = byte 0x2000, matching the link VMA). YarvMon is a wozmon-style serial monitor over the UART (115200 8N1): hex addr to examine, `:` deposit, `.` block dump, `R` call. Build it with `make` in `sim/sw-yarvmon/`. The sim oracle `sim/imem.hex` is still the `make run` default (sim only).
- LSU done (loads/stores/Zilx via native D-mem+peri bridge; load-use covered by forwarding; posted store both paths).
- **Peripherals/interrupts — active front.** All 3 interrupt sources wired: MSIP, MTIP (CLINT), MEIP (UART). Done: CLINT timer, `axi4_lite_xbar_3` peri mux w/ DECERR, UART wired into `top_module`/`sim_top` w/ double-flopped `rxd_i`, **UART + `axi4_lite_xbar_3` added to the `.gprj`** and **UART pins assigned in `.cst`** (`uart_txd_o` PIN69, `uart_rxd_i` PIN70, BL616 USB-UART bridge) — synthesized + PnR'd 2026-08-24. **UART FIFOs + RX stimulus + MEIP oracle done 2026-08-25** (see `axi4_lite_uart.sv`, `sim/hw/uart_tb/`, `sim/sw_uart_echo/`): the harness now types real 8N1 frames into `uart_rxd_i` and logs TX bytes, and MEIP is verified end to end (including the `wfi` wake on an external interrupt). Remaining, in order: (5) GPIO (dir/out/in, IRQ, same MMIO template); (6) PLIC-style interrupt controller (MEIP has no cause register — ISR must poll). Re-synthesized and closed since (see the 40 MHz bullet). The UART's TXDATA write is now held rather than dropped when the FIFO is full, and register writes honour `wstrb[0]` — a byte store to one of the upper lanes of a register addressed no field and used to push `wdata[7:0]`, i.e. a NUL.
- **Trap/exception/interrupt machinery done** (M-mode): sync traps, mret, wfi, fence/fence.i nops, mstatus semantics, mtvec direct+vectored, MSIP+MTIP+MEIP sources, MEI>MSI>MTI priority, **instruction access fault** (2026-08-25). Verified: `sw_trap` oracle (MSIP self-write @`MSIP_PERI_ADDR` 0x1000_3000 + WFI wake — test addr fixed 2026-08-25, was stale 0x1000_0000 from pre-UART layout), `sw_timer` oracle, `sw_ifault` oracle, Spike cosim of illegal-trap (`cosim/ecall`, PASS 17 matched — ecall itself not Spike-comparable), `sw_wfi_trap` arbitration oracle (toolchain-free). Remaining: S/U-mode+delegation, illegal-CSR-access trap, PLIC, vectored-mode interrupt cosim.
- **40 MHz: DONE, closed at 40.281 MHz actual (2026-08-25)** with the rPLL at 25×8/5. The two changes that got it there were the LSU request register stage (+4.8 ns) and the registered CSR read (which removed the limiter the report named before it). Everything re-verified on that build: all oracles, both co-sims, the three compliance testbenches, and on hardware quicksort (256 values printed) and YarvMon. Next limiter if more is ever wanted: `regfile → forward mux → branch compare/target → PC redirect`.
- RVC spanning handled; remaining cost is 1-cycle `span_wait` bubble per spanning instr (needs wider F/D to remove). RVC funct3=100 decode fixed 2026-08-25; RVC immediate-scramble bugs (c.addi4spn `nz[3]`/`nz[2]`, c.addi16sp missing `nzimm[4]`, c.jal/c.j `imm[7]`/`imm[5]`) fixed 2026-08-25 and guarded by the `sw_rvc_scramble` per-bit oracle (see `decode_stage.sv` above + [[c-expand-rvc-immediate-scramble-bugs]]).
- I-mem single-outstanding (~2 cyc/instr); pipelined 1-cyc/instr I-mem is a later fetch-throughput optimization, out of scope.
- `cmd.do` targets **40 MHz** and closes (history 50→40→25 bypass→35 rPLL→25 bypass→40 rPLL). Three places must agree on the target: the rPLL parameters in `top_module`, the SDC generated clock, and `global_freq` in `pnr_check.tcl` + `cmd.do`.
- `.gprj.user` is per-machine IDE state (gitignored); canonical file list is the `.gprj`.

### Plan (2026-08-25, in order)
Done and off the list: Harvard split, LSU, forwarding, trap machinery, all three interrupt sources, UART with FIFOs, silicon bring-up, 40 MHz closure, `.bss` clearing, instruction access fault.

1. **GPIO** — direction / output / input registers plus an interrupt, same MMIO template as UART/MSIP/CLINT. It is also what makes the next item meaningful.
2. **PLIC-style interrupt controller** — MEIP is one ORed level with no cause register, so with two external sources the ISR must poll to find which fired. Worth doing once GPIO exists.
3. **Illegal-CSR-access trap** — unimplemented CSR addresses currently read 0 and ignore writes silently, which hides a software bug rather than reporting it.
4. **Vectored-mode interrupt cosim** — `mtvec` MODE=01 is implemented but only direct mode is co-simulated.
5. **Pipelined I-mem** — the single-outstanding fetch is the dominant bottleneck at ~2.2 cycles per instruction, and therefore the only remaining change that would move IPC substantially rather than trim it. It is also the most invasive.
6. **RVC spanning bubble** — one cycle per 32-bit instruction that straddles a word boundary; needs a wider F/D.
7. **Co-sim MMIO gap** — the diff stops at the first UART access because Spike has no such device; closable by teaching Spike the peripherals or by running a no-MMIO firmware for the comparison.
8. **Deferred by choice**: S/U mode + delegation (`medeleg`/`mideleg`), PMP, cross-word sub-word accesses.