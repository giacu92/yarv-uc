# Harvard Architecture Conversion (I-mem / D-mem split)

> Reference plan. Implementation TBD by the author.
> Branch: `feat__harvard_imem_dm` (created from `main` after merging `feat__posted_store`).

## Context

The core is currently von Neumann: fetch and the LSU share one AXI4-Lite master
through `mem_arbiter` (LSU priority) → one `axi4_lite_master_bridge` →
`axi4_lite_xbar` (split by `addr[28]`) → one `axi4_lite_ram` (mem) / peri (tied off).
Single-outstanding bridge means fetch and LSU contend for the same port, fetch runs
~2 cyc/instr, and loads/stores pay a multi-cycle AXI round-trip.

Goal: convert to Harvard — fetch gets a dedicated read-only I-mem (native, no AXI),
the LSU gets a native byte-strobed D-mem for RAM, and AXI is kept **only for
peripherals**. This removes fetch/LSU contention, shortens load/store latency, and
drops the arbiter + mem-side bridge/xbar. The posted-store mechanism already on
`feat__posted_store` generalizes cleanly to native D-mem (1-cycle sync store) and
peri (posted via launch-accept).

Key enabler: `fetch_stage` and `execute_stage` already speak the native
`mem_req_t`/`mem_rsp_t` interface internally — they are wired to `mem_arbiter`
inside the CPU. Harvard mostly *re-routes those native ports* to dedicated
memories, so the pipeline stage logic is largely untouched.

## Architectural decisions (recommended approach)

1. **CPU boundary becomes three ports** (native for memory, AXI only for peri):
   - `imem` — native `mem_req_t`/`mem_rsp_t`, fetch read-only.
   - `dmem` — native `mem_req_t`/`mem_rsp_t`, LSU data RAM (byte-strobed).
   - `bus_axi` — `axi4_lite_if.master`, LSU peripherals (AXI).
   - The CPU no longer instantiates `mem_arbiter`. `axi4_lite_master_bridge` stays
   inside the CPU but is now peri-only (fed by the LSU's peri-steered request,
   not the arbiter). The LSU decodes `addr[PERI_ADDR_BIT]` itself and steers:
   `0` → `dmem` port, `1` → internal bridge → `bus_axi`. This drops the
   "CPU agnostic to mem/peri" property (the CPU now knows the split) — acceptable
   for a single-board core with a fixed memory map; `PERI_ADDR_BIT` is already in
   `rv32_pkg` the CPU imports. The payoff: no crossbar module at all.

2. **Board top is pure point-to-point wires** (no steering logic):
   - `CPU.imem` → native I-mem (dedicated).
   - `CPU.dmem` → native D-mem (dedicated).
   - `CPU.bus_axi` → `axi_bus_peri` (peri bus, tied off for now).
   - No `native_mem_xbar`, no `axi4_lite_xbar`. Both crossbars are gone. The
   bridge is inside the CPU (peri-only), so the top has no bus-conversion glue.

3. **`.rodata` lives in D-mem**, not I-mem. I-mem holds `.text`/`.text.init` only
   (read-only, single fetch port — no dual-port needed). `.rodata`/`.data`/`.bss`
   and the stack live in D-mem, accessed by normal LSU loads. This avoids a
   second read port on I-mem. Both memories are independent 0-based address
   spaces (I-mem `ORIGIN=0`, D-mem `ORIGIN=0`); no address collision.

4. **Native memory module(s) are single-outstanding** (mirror the existing
   bridge/RAM read FSM: accept on `wready`, assert `rvalid` one cycle later, hold
   `rvalid` until `rready`). This matches the handshake the pipeline already uses,
   so `fetch_stage`/`execute_stage` need no protocol changes. A pipelined
   (1-cyc/instr) I-mem is a *future* fetch-throughput optimization, out of scope
   here; single-outstanding still removes contention (the main win).

5. **Posted store generalizes without code changes**: for a native D-mem store,
   `wready=1` (D-mem idle, selected) → `store_done = mem_launch_hs & mem_write`
   retires same cycle and the sync write commits at the clock edge. For a peri
   store, `wready=1` when the bridge is `S_IDLE` → same `store_done` path. Loads
   still go `EX_MEM_WAIT` until `rvalid` (native D-mem: 1-cycle wait; peri:
   multi-cycle). The `execute_stage` mem-control logic is unchanged; only the
   source of `mem_rsp_i.wready/rvalid/rdata` changes (steering instead of
   arbiter/bridge).

## New modules

- `src/rtl/utils/native_mem.sv` — native `mem_req_t`/`mem_rsp_t` slave,
  parameterized: `SUPPORT_WRITE` (0 = I-mem read-only, 1 = D-mem RW byte-strobed),
  `ADDR_W`, `INIT_FILE`. Storage `(* ram_style = "block" *)`. Read FSM mirrors
  `axi4_lite_ram`'s registered-`rvalid`-held-under-delayed-`rready` behavior (the
  compliance fix already proven by `ram_tb`). Write path (D-mem) uses the same
  byte-strobe write loop as `axi4_lite_ram`. I-mem instance ignores
  `we`/`wdata`/`wstrb`. Reuse the `mem_req_t`/`mem_rsp_t` handshake convention
  from `rv32_pkg` (`req_handshake()`).

## Removed / moved

- **Remove `mem_arbiter`** instantiation (fetch and LSU no longer share). Delete
  `src/rtl/core/mem_arbiter.sv` from the build (`.gprj`, sim `Makefile`). File is
  in git history if ever needed again.
- **`axi4_lite_master_bridge` stays inside the CPU**, now peri-only (fed by the
  LSU's peri-steered request instead of the arbiter). File unchanged; the arbiter
  feeding it is removed and the LSU steer mux replaces it.
- **Remove `axi4_lite_xbar`** instantiation (no AXI mem split; peri bridge drives
  the peri bus directly). Keep `src/rtl/bus/axi4_lite_xbar.sv` on disk (reusable
  for future multi-peri), but drop it from the build list / `.gprj`.
- **No `native_mem_xbar`** — the LSU steers RAM/peri internally on
  `addr[PERI_ADDR_BIT]` (combinational select; safe because the LSU is
  single-outstanding and holds `addr` stable during `EX_MEM_WAIT`), so no
  crossbar module is needed.

## File-by-file changes

### RTL — pipeline stages (minimal/no change)
- `src/rtl/core/fetch_stage.sv` — **no change**. Its `imem_req_o`/`imem_rsp_i`
  ports already speak native; the CPU top rewires them to the `imem` port
  instead of `mem_arbiter`.
- `src/rtl/core/execute_stage.sv` — **mem-control logic unchanged**; the LSU
  gets an internal `addr[PERI_ADDR_BIT]` steer. Split the single
  `mem_req_o`/`mem_rsp_i` into `dmem_req_o`/`dmem_rsp_i` (native, RAM) and
  `peri_req_o`/`peri_rsp_i` (native, → bridge): drive the selected target from
  `alu_result[PERI_ADDR_BIT]`, mux the response back on the same bit
  (`addr` is stable during `EX_MEM_WAIT`, so combinational select is safe).
  `store_done`/`mem_done`/`mem_op_done` unchanged (native D-mem and the peri
  bridge both expose the same `wready`/`rvalid`/`rdata` semantics). Verify the FSM
  transition `EX_IDLE → (mem_read ? EX_MEM_WAIT : EX_IDLE)` still holds for native
  D-mem stores (it does: store retires on `launch_hs`, no wait).
- `src/rtl/core/decode_stage.sv` — **no change**.
- `src/rtl/pkg/rv32_pkg.sv` — **no change** (`mem_req_t`/`mem_rsp_t`,
  `PERI_ADDR_BIT` reused as-is).

### RTL — CPU top
- `src/rtl/core/rv32imac_zicsr_zifencei.sv`:
  - Replace the single `axi4_lite_if.master bus_axi` port with three ports:
    `output mem_req_t imem_req_o, input mem_rsp_t imem_rsp_i` (fetch),
    `output mem_req_t dmem_req_o, input mem_rsp_t dmem_rsp_i` (LSU RAM), and keep
    `axi4_lite_if.master bus_axi` (LSU peri).
  - Delete the `fe_req/fe_rsp/lsu_req/lsu_rsp/imem_req/imem_rsp` internal pairs
    except the ones that become the ports (or rename).
  - Remove `u_mem_arbiter`. Keep `u_bus_bridge` but feed it the LSU's
    peri-steered `peri_req`/`peri_rsp` (from `execute_stage`) instead of the
    arbiter; its `axi` side still drives `bus_axi`.
  - Wire `fetch_stage.imem_req_o/imem_rsp_i` → CPU `imem` port;
    `execute_stage.dmem_req_o/dmem_rsp_i` → CPU `dmem` port;
    `execute_stage.peri_req_o/peri_rsp_i` → `u_bus_bridge` → `bus_axi`.
  - All pipeline taps, regfile, csr, decode, execute wiring unchanged.

### RTL — board top
- `src/rtl/core/top_module.sv`:
  - Drop `axi_bus_cpu`/`axi_bus_mem` trunks (no AXI on the CPU/mem side). Keep
    `axi_bus_peri` for the peri bus.
  - Instantiate `native_mem #(.SUPPORT_WRITE(0), .ADDR_W(16)) u_imem` on
    `CPU.imem`; `native_mem #(.SUPPORT_WRITE(1), .ADDR_W(16)) u_dmem` on
    `CPU.dmem`. Both are direct point-to-point wires (no crossbar).
  - `CPU.bus_axi` → `axi_bus_peri` (peri tieoff unchanged: slave side hardwired
    low). The bridge is inside the CPU, so the top has no bus-conversion glue.
  - Clock/reset (rPLL, `rst_sync`), LEDs unchanged. `.cst`/`.sdc` unchanged
    (memories are on-chip BSRAM, no new IO; no new clocks).

### Sim harness
- `sim/sim_top.sv` — mirror `top_module.sv`: native I-mem + native D-mem on the
  CPU's `imem`/`dmem` ports (direct wires, no crossbar), peri tieoff on
  `bus_axi` (bridge is inside the CPU). Replace the single `$readmemh`
  with two: `$readmemh(iinit_file, u_imem.mem)` and
  `$readmemh(dinit_file, u_dmem.mem)`, with two plusargs `+IINIT=<path>`
  (default `imem.hex`) and `+DINIT=<path>` (default `dmem.hex`). Repoint the
  PROBE_LEN VCD window at `u_dmem.mem[PROBE_BASE_WORD+gi]` (the quicksort data
  array lives in D-mem now). `sim_main.cpp` needs **no change** (taps are
  CPU-internal `u_cpu` hierarchy, topology-independent) — just re-verify the flat
  tap names still resolve after the CPU port rename.
- `sim/Makefile` — RTL list: add `native_mem.sv`; remove `mem_arbiter.sv`;
  keep `axi4_lite_master_bridge.sv` (now peri-only, still in the CPU); drop
  `axi4_lite_xbar.sv` from the sim build list (unused). `$(TOP)` prerequisite:
  `imem.hex dmem.hex` instead of `program.hex`. `RUN_ARGS` plumbing for two
  plusargs.
- `sim/program.hex` — split into `sim/imem.hex` (code `0x00`–`0x58`, `@00000000`)
  and `sim/dmem.hex` (empty placeholder — oracle data is runtime-written at
  `0x100+`, which maps directly to D-mem `0x100+` since D-mem is 0-based 64 KiB;
  no rebase needed). The CSR-write prefix and the self-loop halt at `0x58` stay
  in `imem.hex`.
- Repo-root `Makefile` `sw-run`/`sw` targets: pass `+IINIT=sw/build/imem.hex
  +DINIT=sw/build/dmem.hex`.

### C build flow
- `sim/sw/link.ld` — two `MEMORY` regions both `ORIGIN = 0`:
  `IMEM (rx) : ORIGIN = 0, LENGTH = 64K` and `DMEM (rwx) : ORIGIN = 0, LENGTH = 64K`.
  `SECTIONS`: `.text.init`/`.text` → `> IMEM`; `.rodata`/`.data`/`.bss` → `> DMEM`.
  `ENTRY(_start)` and `.text.init` `KEEP` so `_start` stays at I-mem 0.
- `sim/sw/Makefile` — hex generation: two `objcopy -O binary -j <sections>` runs
  (`-j .text.init -j .text` → `imem.bin`; `-j .rodata -j .data -j .bss` →
  `dmem.bin`), then `bin2hex.py` on each → `imem.hex` + `dmem.hex`. `bin2hex.py`
  unchanged (run twice). Verify `.bss` (NOBITS) contributes no file content
  (current code keeps all initialized state in `.data`, so `.bss` is empty in
  practice — confirm).
- `sim/sw/start.S` — update the "shared imem bus" comment; `li sp, 0x10000` still
  works (top of 64 KiB D-mem, stack grows down; data lives low in D-mem).
- `sim/sw/main.c` — **no change**; `arr` (`.data`) and stack frames land in D-mem
  via the linker; `lxsw`/load/store addresses are D-mem offsets.

### Compliance test
- `sim/ram_tb/` — **no change** (still tests `axi4_lite_ram` standalone; not
  wired to the CPU). The D-mem is now `native_mem`, not `axi4_lite_ram`, so
  `ram_tb` no longer covers the D-mem slave.
- **New `sim/native_mem_tb/`** — clone the `ram_tb` BFM pattern for the native
  `mem_req_t`/`mem_rsp_t` protocol: check `rvalid` held under delayed `rready`,
  byte strobes on D-mem writes, back-to-back writes, single-outstanding
  (wready low while a read pending), posted-store same-cycle retire. This is the
  native-mem compliance gate, analogous to `ram_tb` for AXI.

## Phased delivery (de-risk)

**Phase 1 — Split fetch to native I-mem.**
- Add `native_mem.sv` (start with read-only path; write path added in Phase 2).
- Rewire `fetch_stage` native port → CPU `imem` port → `u_imem` (native_mem
  read-only). LSU stays on the *existing* path for now (arbiter[LSU-only] → bridge
  → xbar → axi4_lite_ram), so D-mem/peri are untouched.
- Sim: `sim_top.sv` gets `u_imem` + `+IINIT`; LSU path unchanged (still one
  `axi4_lite_ram` + xbar). Oracle: `imem.hex` (code) + the existing single RAM
  for data (LSU still von-Neumann for data in this phase).
- Verify: oracle + quicksort pass, fetch no longer contends (stall % drops),
  IPC improves. Isolates the fetch-side change.

**Phase 2 — Split LSU to native D-mem + AXI peri.**
- Add `native_mem.sv` write path (byte strobes).
- Split `execute_stage`'s LSU port into `dmem` (native) + `peri` (native→bridge)
  with the internal `addr[PERI_ADDR_BIT]` steer; wire `dmem` → CPU `dmem` port,
  `peri` → `u_bus_bridge` (kept inside CPU, peri-only) → `bus_axi`.
- Remove `mem_arbiter`, `axi4_lite_xbar` (no crossbars at all).
- Sim: `sim_top.sv` full Harvard (u_imem + u_dmem on direct ports, peri tieoff
  on `bus_axi`), `+IINIT`+`+DINIT`, probe on `u_dmem`. C flow: split
  linker/objcopy.
- Add `sim/native_mem_tb/`.
- Verify: oracle + quicksort pass, load/store latency down, posted-store
  semantics hold for both D-mem (1-cyc) and peri (launch-accept).

## Verification

1. `cd sim && make run` — oracle (`imem.hex`/`dmem.hex`): RAW interlock, div-then-use,
   branch-on-dep, LSU round-trip, byte/halfword sign/zero extend all still pass;
   park detection + IPC printed; compare IPC/stall % to current (0.387 / 16.3%).
2. `make sw-run` (repo root) — C quicksort: builds `imem.hex`+`dmem.hex`, returns
   `0x600D` (sorted); check the PROBE window shows the sorted array in D-mem.
3. `cd sim/native_mem_tb && make run` — "N checks, 0 failures" for native_mem
   (read-hold, byte strobes, single-outstanding, posted store).
4. `cd sim/ram_tb && make run` — still passes (axi4_lite_ram unchanged, peri side).
5. Synth + PnR on the remote build host (per CLAUDE.md flow): confirm it
   synthesizes (new modules Gowin-clean — follow the EX3990/EX3900/BSRAM rules in
   memory), and PnR closes ≥50 MHz. Watch the fetch/I-mem and LSU/D-mem paths
   (native should be *shorter* than the old AXI round-trip); the execute/ALU/decode
   route-dominated limiter is unaffected. Re-measure Actual Fmax.

## Risks / notes

- **fence.i / self-modifying code**: Harvard makes this harder (needs a D→I write
  path + fetch flush). Already deferred/illegal — accepted as a Harvard
  limitation, documented. Not in scope.
- **Peri semantics**: with the posted store, a peri store retires at launch-accept
  (before the slave's B). Back-to-back peri stores still pace on the bridge's
  `wready` (single-outstanding). Acceptable (matches posted-write semantics).
  The tied-off peri (no slave) still hangs the LSU at the *next* mem op, not the
  store — pre-existing limitation, unchanged by Harvard.
- **`.bss`**: current `start.S` does not zero `.bss`; code must keep initialized
  state in `.data`. Confirm `.bss` is empty for the quicksort build (else add a
  zeroing loop in `start.S` or place `.bss` after `.data` with explicit init).
- **I-mem pipelining**: single-outstanding native I-mem ≈ same per-word latency
  as the old bridge (~2 cyc) but *uncontended*. A pipelined 1-cyc/instr I-mem is a
  later fetch-throughput optimization (BSRAM supports pipelined reads; needs
  backpressure skid). Out of scope here.