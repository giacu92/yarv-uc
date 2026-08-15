// Verilator C++ testbench for sim_top.
//
// Drives clk/rst, holds reset for a few cycles, then clocks the design
// and logs:
//   - every instruction word the fetch stage delivers to the F/D
//     register (fetch log), and
//   - every decoded instruction the decode stage latches into the D/E
//     register (decode log): control + operands + immediate.
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
    // exp_npc = the NEXT-INSTRUCTION PC the program stream expects:
    //           pc + 2 if the fetched word's low half is compressed
    //           (the next instr is the upper half of THIS word),
    //           else pc + 4 (a 32-bit instr, next is the next word).
    // fe_npc  = the fetch block's computed next fetch address
    //           (fe_next_pc = pc_q). Fetch is WORD-granular: it always
    //           advances by 4 and never by 2 -- the +2 upper-half case
    //           is owned by decode's hold buffer, not by fetch. So for a
    //           compressed-low-half word exp_npc = pc+2 but fe_npc = pc+4
    //           (a 2-byte "gap" that decode fills from the hold buffer,
    //           with NO stall -- not a fetch bug). For a 32-bit word the
    //           two agree. The decode log below proves the +2 advance
    //           actually happens at the instruction stream (de_pc).
    printf("--- fetch (fe) ---\n");
    printf("cycle  pc          instr       c  exp_npc    fe_npc     =\n");
    printf("-----  ----------  ----------  -  ---------- ----------  -\n");

    int fetched   = 0;
    int decoded   = 0;
    int max_fetch = 16;      // stop after this many fetched words
    int max_cyc   = 400;     // safety bound
    int npc_match = 0;
    int npc_diff  = 0;

    for (int cyc = 0; cyc < max_cyc && fetched < max_fetch; ++cyc) {
        tick(top, tfp);

        if (top->fe_valid_dbg_o) {
            uint32_t pc    = top->fe_pc_dbg_o;
            uint32_t instr = top->fe_instr_dbg_o;
            int      c     = top->fe_is_compressed_dbg_o;
            uint32_t npc   = top->fe_next_pc_dbg_o;
            uint32_t exp_npc = pc + (c ? 2u : 4u);  // instruction-stream next PC
            bool eq = (npc == exp_npc);
            if (eq) ++npc_match; else ++npc_diff;
            printf("%5d  0x%08x  0x%08x  %c  0x%08x 0x%08x  %c\n",
                   cyc, pc, instr, c ? 'C' : '.', exp_npc, npc, eq ? '=' : '!');
            ++fetched;
        }
    }

    printf("-----  ----------  ----------  -  ---------- ----------  -\n");
    printf("fetched %d words in %d cycles | exp_npc==fe_npc: %d | differ: %d "
           "(compressed-low-half words; fetch is word-granular, +2 in decode)\n",
           fetched, max_cyc, npc_match, npc_diff);

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
    printf("cyc  pc          C  instr       opc rd rs1 rs2  imm        r1d        r2d        rw alu br mr mw ms wu wb ill\n");
    printf("---  ----------  -  ----------  --- -- --- --  ---------- ---------- ----------  -- --- -- -- -- -- -- -- ---\n");

    // Track the instruction-stream PC advance between consecutive decoded
    // (non-illegal) entries: expected next = prev_pc + (prev compressed ?
    // 2 : 4). de_valid entries are in program order (idle cycles just gap,
    // they don't skip instrs), so prev de_valid is the previous instr.
    // Illegal entries are skipped on both sides (spanning/ecall/...).
    uint32_t prev_de_pc = 0;
    int      prev_de_c  = 0;
    bool     have_prev  = false;
    bool     prev_de_ill = false;
    int      de_pc_checked = 0, de_pc_ok = 0, de_pc_bad = 0;

    for (int cyc = 0; cyc < max_cyc && decoded < max_fetch * 2; ++cyc) {
        tick(top, tfp);

        if (top->de_valid_dbg_o) {
            uint32_t pc   = top->de_pc_dbg_o;
            uint32_t instr = top->de_instr_dbg_o;  // 32-bit word decode treated
            int      c    = top->de_is_compressed_dbg_o;
            // Opcode is not exposed as a tap; reconstruct it from the
            // D/E control for readability (best-effort, for logs only).
            uint32_t imm  = top->de_imm_dbg_o;
            int      rd   = top->de_rd_dbg_o;
            int      rs1  = top->de_rs1_addr_dbg_o;
            int      rs2  = top->de_rs2_addr_dbg_o;
            uint32_t r1d  = top->de_rs1_data_dbg_o;
            uint32_t r2d  = top->de_rs2_data_dbg_o;
            int      rw   = top->de_reg_write_dbg_o;
            int      alu  = top->de_alu_op_dbg_o;
            int      asa  = top->de_alu_src_a_dbg_o;
            int      asb  = top->de_alu_src_b_dbg_o;
            int      br   = top->de_branch_type_dbg_o;
            int      mr   = top->de_mem_read_dbg_o;
            int      mw   = top->de_mem_write_dbg_o;
            int      ms   = top->de_mem_size_dbg_o;
            int      wu   = top->de_mem_unsigned_dbg_o;
            int      wb   = top->de_wb_src_dbg_o;
            int      ill  = top->de_illegal_dbg_o;

            // Coarse opcode category from the control fields (log-only;
            // the raw numeric fields below are the verification source of
            // truth). LUI vs OP-IMM etc. are not distinguishable from
            // control taps alone (immediate type isn't exported), so the
            // ALU class is lumped as "alu".
            const char* opc = "?";
            if (ill)             opc = "ill";
            else if (br == 7)    opc = "jal";
            else if (br == 8)    opc = "jalr";
            else if (br != 0)    opc = "br";
            else if (mr)         opc = "ld";
            else if (mw)         opc = "st";
            else                 opc = "alu";

            printf("%3d  0x%08x  %c  0x%08x  %3s %2d %3d %3d  0x%08x 0x%08x 0x%08x  %d  %2d  %2d  %d  %d  %d  %d  %d  %d\n",
                   cyc, pc, c ? 'C' : '.', instr, opc, rd, rs1, rs2,
                   imm, r1d, r2d, rw, alu, br, mr, mw, ms, wu, wb, ill);

            // Instruction-stream PC advance vs the previous legal instr.
            if (have_prev && !prev_de_ill && !ill) {
                uint32_t exp_de = prev_de_pc + (uint32_t)(prev_de_c ? 2 : 4);
                ++de_pc_checked;
                if (pc == exp_de) ++de_pc_ok; else ++de_pc_bad;
            }
            prev_de_pc  = pc;
            prev_de_c   = c;
            have_prev   = true;
            prev_de_ill = ill;
            ++decoded;
        }
    }

    printf("---  ----------  -  ----------  --- -- --- --  ---------- ---------- ----------  -- --- -- -- -- -- -- -- ---\n");
    printf("decoded %d instructions in %d cycles\n", decoded, max_cyc);
    printf("decode PC-stream: %d legal transitions checked, %d ok (+2 compressed / +4 32-bit), %d bad\n",
           de_pc_checked, de_pc_ok, de_pc_bad);

    // Let a few final cycles ripple for the waveform tail.
    for (int i = 0; i < 4; ++i) tick(top, tfp);

    tfp->close();
    delete top;
    delete tfp;
    return 0;
}