`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
 * Integer register file (GPR) — 32 x 32-bit registers (x0 hardwired to 0).
 *
 * Two asynchronous (combinational) read ports so the decode stage gets
 * rs1/rs2 operands in the same cycle, and one synchronous write port
 * (posedge, whole-word write) driven by the execute writeback.
 *
 * Storage is the unpacked array `logic [XLEN-1:0] regs[31:0]` (sync-write
 * + 2 async-read).
 *
 * Mapped to a Gowin BSRAM (async-read block-RAM) via
 * `(* ram_style = "block" *)`.
 *
 * *** BSRAM vs `registers`: MEASURED TWICE, BSRAM WINS. Do not try it a
 * third time. ***
 *   - A/B #1 (older design): `clk_core` Actual Fmax 50.151 MHz on BSRAM vs
 *     50.150 MHz on `syn_ramstyle = "registers"` — identical within PnR
 *     noise, so the regfile primitive was not the limiter.
 *   - A/B #2 (2026-08-28, this design, 65 MHz constraint so both runs return
 *     the router's free optimum and compare directly): BSRAM **49.590 MHz /
 *     20.130 ns / Logic Level 14 / TNS -2041.789 ns over 1038 endpoints** vs
 *     `registers` **47.557 MHz / 20.992 ns / Logic Level 16 / TNS -9766.680
 *     ns over 3449 endpoints**. Flops are **worse**, and not marginally.
 * A/B #2 was run precisely because the path composition had changed in a way
 * that made BSRAM look guilty — 13 of the 25 worst setup paths launched from
 * `regs_regs_0_0_s/DO[*]`, the read output being the *start* of the critical
 * path rather than a bystander. It was still the wrong suspect. Two reasons,
 * both visible in the `registers` report: the 32:1 LUT mux for an async read
 * is DEEPER than BSRAM's read access (worst path went 20.130 -> 20.992 ns and
 * levels 14 -> 16), and the single write port fans out to 32 distributed
 * RAMREG copies, so 9 of the 25 worst paths became
 * `de_q.is_compressed -> regs_regs_RAMREG_<n>/D` — pure new cost that BSRAM's
 * one real write port does not have. The lesson: a path *launching* from a
 * memory output does not mean the memory is what makes it long.
 *
 * `distributed_ram` (Gowin SSRAM) is excluded for a functional reason, not a
 * timing one: it is synchronous-read only (SUG949E §8.2 — registered output,
 * 1-cycle latency), which would break the same-cycle operand read (rs1/rs2
 * addresses are decoded and the operands latched into D/E in one cycle).
 *
 * NOTE — no runtime reset on `regs`. A BSRAM primitive has a single write
 * port, so it cannot honor a "clear all 32 words this cycle" reset the
 * way an `if (!rstn_i) for(...) regs[i] <= 0` loop implies; forcing that
 * behavior made GowinSynthesis fail to map cleanly onto one SDPB and
 * instead emit extra LUT/FF/SSRAM logic to fake the clear across the
 * duplicated read-port copies of the array, which showed up as spurious
 * DO->DI timing paths inside the memory primitive and blew setup timing.
 * In hardware the regfile relies on BSRAM power-up INIT + write-before-
 * read (standard for a regfile — architectural state is not meant to be
 * cleared on a warm reset anyway), so the reset branch is intentionally
 * omitted here. `rstn_i` is kept as a port for interface consistency and
 * future use, but is unused by this module.
 *
 * reads of x0 return 0 via an explicit mux.
 *
 * Naming: ports *_i/_o; internal signals have no prefix. The storage
 * array is `regs`; there is no _q/_d because it is an array, not a
 * single flop.
 */
module reg_file (
    input  wire            clk_i,
    input  wire            rstn_i,      // unused: BSRAM write port cannot be reset, see note above
    // Two async read ports (decode drives the addresses).
    input  wire [     4:0] rs1_addr_i,
    input  wire [     4:0] rs2_addr_i,
    output wire [XLEN-1:0] rs1_data_o,
    output wire [XLEN-1:0] rs2_data_o,
    // One sync write port (driven by execute writeback).
    input  wire [     4:0] wr_addr_i,
    input  wire [XLEN-1:0] wr_data_i,
    input  wire            wr_en_i
);
    // BSRAM (async-read block-RAM) — see the module header: `registers`
    // (FF + 32:1 LUT mux) was measured twice and is worse both times, most
    // recently 47.557 vs 49.590 MHz on this design.
    (* ram_style = "block" *)
    logic [XLEN-1:0] regs[31:0];

`ifdef VERILATOR
    // Sim-only deterministic zero-init (Verilator), so waveforms/logs
    // don't show X before the first write to each register. Does not
    // synthesize and does not affect the BSRAM mapping above.
    initial begin
        for (integer i = 0; i < 32; i++) begin
            regs[i] = '0;
        end
    end
`endif

    // -----------------------------------------------------------------
    // Write (sync, whole word, x0 ignored) — no reset, see module note.
    // -----------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (wr_en_i && wr_addr_i != 5'd0) begin
            regs[wr_addr_i] <= wr_data_i;
        end
    end

    // -----------------------------------------------------------------
    // Read (async, x0 reads as 0)
    // -----------------------------------------------------------------
    assign rs1_data_o = (rs1_addr_i == 5'd0) ? '0 : regs[rs1_addr_i];
    assign rs2_data_o = (rs2_addr_i == 5'd0) ? '0 : regs[rs2_addr_i];

endmodule

`resetall
