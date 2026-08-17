// Verilator C++ testbench for sim_top.
//
// Drives clk/rst, holds reset for a few cycles, then clocks the design
// and logs every stage in ONE pass:
//   - every instruction word the fetch stage delivers to the F/D
//     register (fetch log),
//   - every decoded instruction the decode stage latches into the D/E
//     register (decode log), and
//   - every operation the execute stage retires into the E/M register
//     (execute log), WITH the writeback value (wb_en / wb_addr / wb_data).
//
// The three logs are recorded in a single run, so they show the honest
// pipeline view (each stage lags the previous by one cycle -- a fetch
// word at cycle N retires a few cycles later in the execute log). The
// previous harness reset+reran the program three times to force the
// three logs cycle-aligned; that was gratuitous and made the core appear
// to "keep rerunning" instead of parking.
//
// The run STOPS EARLY once the core parks: when the retire stream sees
// the same pc+instr for PARK_N consecutive retires (a single-instruction
// self-loop, e.g. start.S `1: j 1b`). This avoids churning ~900 cycles of
// the parked `j` after the program finishes. A max_cyc safety bound
// covers programs that never park (long computes, infinite loops of
// changing state). Park detection on RETIRES (not cycles) means a
// multi-cycle DIV/LSU stall (no retires) never false-triggers, and a
// two-instruction tight loop (alternating instrs) never matches either.
//
// The CPU exports no debug ports: the per-stage taps are internal nets
// inside the CPU (fe_pc_w / de_pc_w / ex_pc_w / wb_en / wb_addr /
// wb_data, ...). The sim is built with --public-flat-rw, so this harness
// reaches them as flat C++ members of the sim_top model
// (TAP(fe_pc_w), ...). sim_top itself carries only clk / rst / led.
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
#include <cstdlib>
#include <string>
#include <vector>

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

    // -----------------------------------------------------------------
    // Single pass: record the three stage logs, stop once parked.
    // -----------------------------------------------------------------
    const int PARK_N  = 8;     // consecutive identical retires => parked
    // Safety bound for programs that don't park. Override with the MAX_CYC
    // env var (e.g. MAX_CYC=20000 make run) for longer-running programs.
    const int max_cyc = [] {
        const char *e = getenv("MAX_CYC");
        return e ? atoi(e) : 4000;
    }();

    std::vector<std::string> fe_log, de_log, ex_log;
    int fetched = 0, decoded = 0, retired = 0;
    uint32_t prev_fe_pc = 0;
    bool have_prev_fe = false;
    int fe_pc_checked = 0, fe_pc_ok = 0, fe_pc_bad = 0;

    // Park detection on the retire stream.
    uint32_t last_ex_pc = 0, last_ex_instr = 0;
    int same_ret = 0;
    int park_cyc = -1;  // cycle the core was first detected parked

    char line[96];
    int cyc;
    for (cyc = 0; cyc < max_cyc; ++cyc) {
        // Low half: de_q holds the op about to retire at this edge; sample
        // its writeback before the edge commits it (wb is combinational
        // from de_q, so the pre-edge value lines up with this retire).
        top->clk_i = 0;
        top->eval();
        tfp->dump(sim_time++);
        bool     wb_en  = TAP(wb_en);
        uint32_t wb_addr = TAP(wb_addr);
        uint32_t wb_data = TAP(wb_data);

        // High half: the posedge commits the writeback and updates the
        // stage registers. fe/de/ex valid are sampled post-edge.
        top->clk_i = 1;
        top->eval();
        tfp->dump(sim_time++);

        // ---- fetch log (one line per cycle fe_valid is high) ----
        // Fetch is WORD-granular: it always advances by 4, never by 2 (the
        // +2 upper-half / spanning case is owned by decode's hold buffer).
        // is-compressed (c) is derived from instr[1:0] -- fetch no longer
        // exports it. fe_valid is a held level, so a stall (DIV/LSU busy)
        // repeats the same word for several cycles -- that is the stall,
        // not a bug.
        if (TAP(fe_valid_w)) {
            uint32_t pc    = TAP(fe_pc_w);
            uint32_t instr = TAP(fe_instr_w);
            int      c     = (instr & 3u) != 3u;
            snprintf(line, sizeof(line), "%5d  0x%08x  0x%08x  %c",
                     cyc, pc, instr, c ? 'C' : '.');
            fe_log.push_back(line);
            if (have_prev_fe) {
                ++fe_pc_checked;
                if (pc == prev_fe_pc + 4u) ++fe_pc_ok; else ++fe_pc_bad;
            }
            prev_fe_pc = pc;
            have_prev_fe = true;
            ++fetched;
        }

        // ---- decode log (one line per cycle de_valid is high) ----
        // de_instr is the 32-bit word decode TREATED (native or
        // RVC-expanded), so is-compressed cannot be recovered from it.
        if (TAP(de_valid_w)) {
            uint32_t pc    = TAP(de_pc_w);
            uint32_t instr = TAP(de_instr_w);
            snprintf(line, sizeof(line), "%3d  0x%08x  0x%08x", cyc, pc, instr);
            de_log.push_back(line);
            ++decoded;
        }

        // ---- execute retire + writeback log ----
        // ex_* is the E/M register: it latches the PC / instr / valid of
        // the operation that retired this cycle (single-cycle ALU ops
        // retire the cycle they are valid; DIV/REM retire when the ALU
        // asserts result_valid_o; loads/stores retire when the mem
        // response arrives). Illegal ops do not retire (ex_valid stays 0).
        if (wb_en) {
            snprintf(line, sizeof(line), "%3d  wb    x%-2u = 0x%08x", cyc, wb_addr, wb_data);
            ex_log.push_back(line);
        }
        if (TAP(ex_valid_w)) {
            uint32_t pc    = TAP(ex_pc_w);
            uint32_t instr = TAP(ex_instr_w);
            snprintf(line, sizeof(line), "%3d  ex    0x%08x  0x%08x", cyc, pc, instr);
            ex_log.push_back(line);
            ++retired;

            // Park detection: N consecutive IDENTICAL retires => the
            // core is spinning on a single-instruction self-loop.
            if (pc == last_ex_pc && instr == last_ex_instr) {
                ++same_ret;
            } else {
                same_ret = 1;
            }
            last_ex_pc    = pc;
            last_ex_instr = instr;
            if (same_ret >= PARK_N && park_cyc < 0) {
                park_cyc = cyc;
                break;
            }
        }
    }

    // -----------------------------------------------------------------
    // Print the three log sections.
    // -----------------------------------------------------------------
    printf("--- fetch (fe) ---\n");
    printf("cycle  pc          instr       c\n");
    printf("-----  ----------  ----------  -\n");
    for (const std::string& s : fe_log) printf("%s\n", s.c_str());
    printf("-----  ----------  ----------  -\n");
    printf("fetched %d words in %d cycles | word-advance +4: %d ok / %d bad\n",
           fetched, cyc, fe_pc_ok, fe_pc_bad);

    printf("--- decode (de) ---\n");
    printf("cyc  pc          instr\n");
    printf("---  ----------  ----------\n");
    for (const std::string& s : de_log) printf("%s\n", s.c_str());
    printf("---  ----------  ----------\n");
    printf("decoded %d instructions in %d cycles\n", decoded, cyc);

    printf("--- execute (ex) + writeback (wb) ---\n");
    printf("cyc  kind  pc / value\n");
    printf("---  ----  -----------------------\n");
    for (const std::string& s : ex_log) printf("%s\n", s.c_str());
    printf("---  ----  -----------------------\n");
    if (park_cyc >= 0) {
        printf("retired %d instructions in %d cycles (parked at cyc %d: "
               "self-loop detected after %d identical retires)\n",
               retired, cyc, park_cyc, PARK_N);
    } else {
        printf("retired %d instructions in %d cycles (no park: hit %d-cycle safety bound)\n",
               retired, cyc, max_cyc);
    }

    // Let a few final cycles ripple for the waveform tail.
    for (int i = 0; i < 4; ++i) tick(top, tfp);

    tfp->close();
    delete top;
    delete tfp;
    return 0;
}