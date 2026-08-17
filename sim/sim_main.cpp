// Verilator C++ testbench for sim_top.
//
// Drives clk/rst, holds reset for a few cycles, then clocks the design
// and logs (per stage: pc / instr / valid), each in its own reset+run
// pass so the three logs stay aligned (each stage lags the previous by
// one cycle):
//   - every instruction word the fetch stage delivers to the F/D
//     register (fetch log),
//   - every decoded instruction the decode stage latches into the D/E
//     register (decode log), and
//   - every operation the execute stage retires into the E/M register
//     (execute log), WITH the writeback value (wb_en / wb_addr / wb_data).
//
// The CPU no longer exports debug ports: the per-stage taps are internal
// nets inside the CPU (fe_pc_w / de_pc_w / ex_pc_w / wb_en / wb_addr /
// wb_data, ...). The sim is built with --public-flat-rw, so this harness
// reaches them as flat C++ members of the sim_top model
// (TAP(fe_pc_w), ...). sim_top itself carries only clk /
// rst / led.
//
// Writeback is sampled on the clock low half (before the edge that
// commits it) so the value lines up with the retiring op; ex_valid
// (registered) is sampled after the edge. A VCD waveform (sim_top.vcd)
// is written for GTKWave.
//
// Build: make   (in sim/)
// Run:   make run   (or ./obj_dir/Vsim_top from sim/)

#include "Vsim_top.h"
#include "Vsim_top___024root.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include <cstdint>
#include <cstdio>

// CPU-internal debug taps are reached through the Verilator root object.
// The sim is built with --public-flat-rw, which exposes every net as a
// flat public member of the root class, named with the full hierarchy:
// sim_top__DOT__u_cpu__DOT__<sig>. The CPU itself exports no debug ports.
#define TAP(field) (top->rootp->sim_top__DOT__u_cpu__DOT__##field)

static vluint64_t sim_time = 0;

// One full clock period: low half then high half, dumping the waveform
// at each step. Outputs are sampled after the rising edge.
static void tick(Vsim_top* top, VerilatedVcdC* tfp) {
    top->clk_i = 0;
    top->eval();
    tfp->dump(sim_time++);
    top->clk_i = 1;
    top->eval();
    tfp->dump(sim_time++);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    Vsim_top* top = new Vsim_top;
    VerilatedVcdC* tfp = new VerilatedVcdC;
    Verilated::traceEverOn(true);
    top->trace(tfp, 99);
    tfp->open("sim_top.vcd");

    printf("=== RV32 fetch + decode + execute (LSU) sim ===\n");

    // Reset (async, active-low): hold rstn_i=0 for a few cycles, then
    // release. We set rstn_i (and the initial clk_i) WITHOUT a standalone
    // eval+dump: dumping with clk_i unchanged repeats the last tick's clock
    // level and stretches the clock to two half-cycles at one level (a
    // "plateau"). Instead the next tick's low-half eval carries the reset
    // change, keeping the clock a clean 0/1/0/1 throughout.
    top->clk_i  = 0;
    top->rstn_i = 0;
    for (int i = 0; i < 4; ++i) tick(top, tfp);

    // Release reset: carried by the run loop's first tick below.
    top->rstn_i = 1;

    // ----- Fetch log (one line per F/D-valid word) -----
    //
    // Fetch is WORD-granular: it always advances by 4, never by 2 (the
    // +2 upper-half case is owned by decode's hold buffer). So the check
    // here is that consecutive fetched words step by 4. is-compressed
    // (c) is derived from instr[1:0] -- fetch no longer exports it.
    printf("--- fetch (fe) ---\n");
    printf("cycle  pc          instr       c\n");
    printf("-----  ----------  ----------  -\n");

    int fetched   = 0;
    int decoded   = 0;
    int max_fetch = 1000;      // stop after this many fetched words
    int max_instr = 1000;      // cap for the decode / execute retire logs
    int max_cyc   = 1000;     // safety bound (mem ops add cycles)
    uint32_t prev_fe_pc = 0;
    bool     have_prev_fe = false;
    int      fe_pc_checked = 0, fe_pc_ok = 0, fe_pc_bad = 0;

    for (int cyc = 0; cyc < max_cyc && fetched < max_fetch; ++cyc) {
        tick(top, tfp);

        if (TAP(fe_valid_w)) {
            uint32_t pc    = TAP(fe_pc_w);
            uint32_t instr = TAP(fe_instr_w);
            int      c     = (instr & 3u) != 3u;
            printf("%5d  0x%08x  0x%08x  %c\n",
                   cyc, pc, instr, c ? 'C' : '.');
            if (have_prev_fe) {
                ++fe_pc_checked;
                if (pc == prev_fe_pc + 4u) ++fe_pc_ok; else ++fe_pc_bad;
            }
            prev_fe_pc = pc;
            have_prev_fe = true;
            ++fetched;
        }
    }

    printf("-----  ----------  ----------  -\n");
    printf("fetched %d words in %d cycles | word-advance +4: %d ok / %d bad\n",
           fetched, max_cyc, fe_pc_ok, fe_pc_bad);

    // ----- Decode log (one line per D/E-valid instr) -----
    // Re-run a fresh pass: reset again so decode sees the program from
    // the top (the D/E register lags F/D by one cycle, and we want the
    // decode log aligned with the fetch log above). A second reset+run
    // keeps both logs independent and simple.
    top->rstn_i = 0;
    for (int i = 0; i < 4; ++i) tick(top, tfp);
    top->rstn_i = 1;

    printf("--- decode (de) ---\n");
    printf("cyc  pc          instr\n");
    printf("---  ----------  ----------\n");

    // Only pc / instr / valid are observed. de_instr is the 32-bit word
    // decode TREATED (native or RVC-expanded), so is-compressed cannot be
    // recovered from it.
    for (int cyc = 0; cyc < max_cyc && decoded < max_instr; ++cyc) {
        tick(top, tfp);

        if (TAP(de_valid_w)) {
            uint32_t pc    = TAP(de_pc_w);
            uint32_t instr = TAP(de_instr_w);  // word decode treated
            printf("%3d  0x%08x  0x%08x\n", cyc, pc, instr);
            ++decoded;
        }
    }

    printf("---  ----------  ----------\n");
    printf("decoded %d instructions in %d cycles\n", decoded, max_cyc);

    // ----- Execute retire + writeback log -----
    // A third reset+run pass, so the retire log is aligned with the fetch
    // and decode logs above. ex_* is the E/M register: it latches the PC /
    // instr / valid of the operation that retired this cycle (single-cycle
    // ALU ops retire the cycle they are valid; DIV/REM retire when the ALU
    // asserts result_valid_o; loads/stores retire when the mem response
    // arrives). Illegal ops do not retire (ex_valid stays 0).
    //
    // Writeback (wb) is logged alongside: wb_en / wb_addr / wb_data are the
    // reg-file write port, combinational from the D/E register (de_q). They
    // are sampled on the clock LOW half — before the rising edge that
    // commits the write — so the value lines up with the op retiring at
    // that edge (ex_valid, registered, is sampled after the edge). This
    // makes the RAW interlock and the LSU load-use path verifiable: a
    // dependent op should write the correct (fresh) value, and a one-cycle
    // bubble (no wb, no ex_valid) appears between a producer and a
    // hazard-stalled consumer.
    top->rstn_i = 0;
    for (int i = 0; i < 4; ++i) tick(top, tfp);
    top->rstn_i = 1;

    printf("--- execute (ex) + writeback (wb) ---\n");
    printf("cyc  kind  pc / value\n");
    printf("---  ----  -----------------------\n");

    int retired = 0;
    for (int cyc = 0; cyc < max_cyc && retired < max_instr; ++cyc) {
        // Low half: de_q holds the op about to retire at this edge; sample
        // its writeback before the edge commits it.
        top->clk_i = 0;
        top->eval();
        tfp->dump(sim_time++);
        uint32_t wb_addr = TAP(wb_addr);
        uint32_t wb_data = TAP(wb_data);
        bool     wb_en   = TAP(wb_en);

        // High half: the posedge commits the writeback and updates ex_valid.
        top->clk_i = 1;
        top->eval();
        tfp->dump(sim_time++);

        if (wb_en) {
            printf("%3d  wb    x%-2u = 0x%08x\n", cyc, wb_addr, wb_data);
        }
        if (TAP(ex_valid_w)) {
            uint32_t pc    = TAP(ex_pc_w);
            uint32_t instr = TAP(ex_instr_w);
            printf("%3d  ex    0x%08x  0x%08x\n", cyc, pc, instr);
            ++retired;
        }
    }

    printf("---  ----  -----------------------\n");
    printf("retired %d instructions in %d cycles\n", retired, max_cyc);

    // Let a few final cycles ripple for the waveform tail.
    for (int i = 0; i < 4; ++i) tick(top, tfp);

    tfp->close();
    delete top;
    delete tfp;
    return 0;
}