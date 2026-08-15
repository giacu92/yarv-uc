// Verilator C++ testbench for sim_top.
//
// Drives clk/rst, holds reset for a few cycles, then clocks the design
// and logs every instruction the fetch stage delivers to the F/D
// register. A VCD waveform (sim_top.vcd) is written for GTKWave.
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

    printf("=== RV32 fetch sim ===\n");

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

    printf("cycle  pc          instr       c  note\n");
    printf("-----  ----------  ----------  -  ----\n");

    int fetched   = 0;
    int max_fetch = 16;      // stop after this many delivered instrs
    int max_cyc   = 300;     // safety bound

    for (int cyc = 0; cyc < max_cyc && fetched < max_fetch; ++cyc) {
        tick(top, tfp);

        if (top->fd_valid_dbg_o) {
            uint32_t pc    = top->fd_pc_full_dbg_o;
            uint32_t instr = top->fd_instr_dbg_o;
            int      c     = top->fd_is_compressed_dbg_o;
            uint32_t npc   = top->next_pc_dbg_o;
            printf("%5d  0x%08x  0x%08x  %c  next_pc=0x%08x\n",
                   cyc, pc, instr, c ? 'C' : '.', npc);
            ++fetched;
        }
    }

    printf("-----  ----------  ----------  -  ----\n");
    printf("fetched %d instructions in %d cycles\n", fetched, max_cyc);

    // Let a few final cycles ripple for the waveform tail.
    for (int i = 0; i < 4; ++i) tick(top, tfp);

    tfp->close();
    delete top;
    delete tfp;
    return 0;
}