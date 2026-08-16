// Verilator C++ testbench for sim_top.
//
// Drives clk/rst, holds reset for a few cycles, then clocks the design
// and logs (per stage: pc / instr / valid — the only debug taps the CPU
// exports now):
//   - every instruction word the fetch stage delivers to the F/D
//     register (fetch log), and
//   - every decoded instruction the decode stage latches into the D/E
//     register (decode log). Decode control / operands / immediates are
//     no longer exported; add taps back when they need verifying.
//
// A VCD waveform (sim_top.vcd) is written for GTKWave.
//
// Build: make   (in sim/)
// Run:   make run   (or ./obj_dir/Vsim_top from sim/)

#include "Vsim_top.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include <cstdint>
#include <cstdio>

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

    printf("=== RV32 fetch + decode sim ===\n");

    // Reset (async, active-low): hold rstn_i=0 for a few cycles.
    top->clk_i  = 0;
    top->rstn_i = 0;
    top->eval();
    tfp->dump(sim_time++);
    for (int i = 0; i < 4; ++i) tick(top, tfp);

    // Release reset.
    top->rstn_i = 1;
    top->eval();
    tfp->dump(sim_time++);

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
    int max_fetch = 16;      // stop after this many fetched words
    int max_cyc   = 400;     // safety bound
    uint32_t prev_fe_pc = 0;
    bool     have_prev_fe = false;
    int      fe_pc_checked = 0, fe_pc_ok = 0, fe_pc_bad = 0;

    for (int cyc = 0; cyc < max_cyc && fetched < max_fetch; ++cyc) {
        tick(top, tfp);

        if (top->fe_valid_dbg_o) {
            uint32_t pc    = top->fe_pc_dbg_o;
            uint32_t instr = top->fe_instr_dbg_o;
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
    top->eval();
    tfp->dump(sim_time++);
    for (int i = 0; i < 4; ++i) tick(top, tfp);
    top->rstn_i = 1;
    top->eval();
    tfp->dump(sim_time++);

    printf("--- decode (de) ---\n");
    printf("cyc  pc          instr\n");
    printf("---  ----------  ----------\n");

    // Only pc / instr / valid are exported now. de_instr is the 32-bit word
    // decode TREATED (native or RVC-expanded), so is-compressed cannot be
    // recovered from it, and the instruction-stream PC advance (+2 / +4)
    // is not checkable here without an is-compressed tap. Add taps back
    // when decode control / compressed-ness need verifying.
    for (int cyc = 0; cyc < max_cyc && decoded < max_fetch * 2; ++cyc) {
        tick(top, tfp);

        if (top->de_valid_dbg_o) {
            uint32_t pc    = top->de_pc_dbg_o;
            uint32_t instr = top->de_instr_dbg_o;  // 32-bit word decode treated
            printf("%3d  0x%08x  0x%08x\n", cyc, pc, instr);
            ++decoded;
        }
    }

    printf("---  ----------  ----------\n");
    printf("decoded %d instructions in %d cycles\n", decoded, max_cyc);

    // Let a few final cycles ripple for the waveform tail.
    for (int i = 0; i < 4; ++i) tick(top, tfp);

    tfp->close();
    delete top;
    delete tfp;
    return 0;
}