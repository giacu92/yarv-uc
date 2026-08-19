`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
* CSR register file — machine-mode Zicsr subset.
*
* One async read port (decode/execute drives the address via de_t.csr_addr)
* and one sync write port (posedge, whole-word write) driven by execute's
* CSR RMW result (csr_wdata / csr_wren).
*
* Implemented CSRs (machine mode): mstatus, misa, mie, mtvec, mscratch,
* mepc, mcause, mtval, mip. Unimplemented CSR addresses read as 0 and
* ignore writes (no illegal-instruction trap yet, so a read of an
* unimplemented CSR returns 0 rather than trapping).
*
* Storage is FF + LUT mux, NOT a BSRAM: the implemented CSRs occupy a
* sparse, small slice of the 12-bit CSR address space (0x300..0x344), so
* they are selected by a case statement on csr_addr_i, not by direct array
* indexing. A BSRAM async read needs a contiguous index, which the sparse
* CSR map does not provide, so `(* ram_style = "block" *)` would be ignored
* anyway (and was misleading). 9 registers is cheap as flops. Unlike the
* GPR file, these CSRs ARE reset: machine-mode CSRs have architected reset
* values, and with only 9 entries a sync reset loop is trivial (no BSRAM
* single-write-port constraint, no DO->DI timing issue).
*
* Naming: ports *_i/_o; internal signals no prefix. The storage array is
* `regs` (one flop per implemented CSR); no _q/_d (array, not single flop).
*/

module csr_regfile (
    input wire clk_i,
    input wire rstn_i,

    // One async read port (decode/execute drives the address).
    input  wire [    11:0] csr_addr_i,
    output wire [XLEN-1:0] csr_data_o,

    // One sync write port (driven by execute's CSR RMW result).
    input wire            csr_wren_i,
    input wire [XLEN-1:0] csr_data_i,

    // Instruction stats
    input wire instr_retire_i,  // instruction retired (commit)
    input wire instr_branch_i,  // instruction retired was a branch
    input wire instr_pc_i       // instruction retired was a jump
);
    // Index map: implemented CSRs packed into a 9-entry array. The case
    // statements below translate the 12-bit CSR address to/from this index.
    localparam int unsigned NCSR = 11;
    logic [XLEN-1:0] regs[NCSR-1:0];
    logic [XLEN-1:0] csr_rdata;

    // Architected reset values (M-mode). misa = RV32 I/M/A/C:
    //   MXL[31:30]=1 (RV32), A=bit0, C=bit2, I=bit8, M=bit13.
    localparam logic [XLEN-1:0] MISA_RESET = 32'h4000_2105;

    always_comb begin
        case (csr_addr_i)
            CSR_ADDR_MSTATUS:  csr_rdata = regs[0];
            CSR_ADDR_MISA:     csr_rdata = regs[1];
            CSR_ADDR_MIE:      csr_rdata = regs[2];
            CSR_ADDR_MTVEC:    csr_rdata = regs[3];
            CSR_ADDR_MSCRATCH: csr_rdata = regs[4];
            CSR_ADDR_MEPC:     csr_rdata = regs[5];
            CSR_ADDR_MCAUSE:   csr_rdata = regs[6];
            CSR_ADDR_MTVAL:    csr_rdata = regs[7];
            CSR_ADDR_MIP:      csr_rdata = regs[8];
            CSR_ADDR_MCYCLE:   csr_rdata = regs[9];
            CSR_ADDR_MINSTRET: csr_rdata = regs[10];
            default:           csr_rdata = '0;  // Unimplemented CSRs read as 0
        endcase
    end

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            for (int i = 0; i < NCSR; i++) begin

                if (i == 1) begin
                    regs[i] <= MISA_RESET;  // misa is read-only WARL, so reset to RV32IMAC
                end else begin
                    regs[i] <= '0;
                end
            end
        end else begin

            // Update MCYCLE and MINSTRET on every cycle (increment by 1). These are
            // architected to be incremented every cycle, so they are not gated by
            // csr_wren_i. The other CSRs are only updated on a CSR write (csr_wren_i).
            regs[9]  <= regs[9] + 1;  // MCYCLE
            regs[10] <= instr_retire_i ? regs[10] + 1 : regs[10];  // MINSTRET

            if (csr_wren_i) begin
                case (csr_addr_i)
                    CSR_ADDR_MSTATUS:  regs[0] <= csr_data_i;
                    CSR_ADDR_MISA:     ;  // misa is read-only here (ignore writes)
                    CSR_ADDR_MIE:      regs[2] <= csr_data_i;
                    CSR_ADDR_MTVEC:    regs[3] <= csr_data_i;
                    CSR_ADDR_MSCRATCH: regs[4] <= csr_data_i;
                    CSR_ADDR_MEPC:     regs[5] <= csr_data_i;
                    CSR_ADDR_MCAUSE:   regs[6] <= csr_data_i;
                    CSR_ADDR_MTVAL:    regs[7] <= csr_data_i;
                    CSR_ADDR_MIP:      regs[8] <= csr_data_i;
                    CSR_ADDR_MCYCLE:   regs[9] <= csr_data_i;
                    CSR_ADDR_MINSTRET: regs[10] <= csr_data_i;
                    default:           ;  // Unimplemented CSRs ignore writes
                endcase
            end
        end
    end

    assign csr_data_o = csr_rdata;

`ifdef VERILATOR
    // Sim-only: mirror the reset values at time 0 so waveforms/logs do not
    // show X before the first reset edge. Matches the sync reset above.
    initial begin
        regs[0] = '0;
        regs[1] = MISA_RESET;
        regs[2] = '0;
        regs[3] = '0;
        regs[4] = '0;
        regs[5] = '0;
        regs[6] = '0;
        regs[7] = '0;
        regs[8] = '0;
    end
`endif

endmodule

`resetall
