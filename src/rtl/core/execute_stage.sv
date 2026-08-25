`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
 * Execute stage — consumes the D/E control word (de_i) from decode and:
 *
 *   - selects the ALU operands (rs1 / rs2 / pc / imm / pc4 / rs1-shifted)
 *     per de_i.alu_src_a / alu_src_b;
 *   - drives the ALU (base RV32I + M + Zilx EA), launching the
 *     multi-cycle DIV/REM with start_i and stalling the pipe until the
 *     ALU asserts result_valid_o;
 *   - writes back ALU / PC4 / load (MEM) / old-CSR results to the
 *     register file (stores carry no reg writeback); loads retire via
 *     WB_MEM once the read response arrives;
 *   - exports ex_wb_en_o / ex_wb_addr_o / ex_wb_data_o to decode the
 *     same cycle a writeback retires, so decode's fwd_rs1/fwd_rs2
 *     forward the fresh value directly into the D/E register instead
 *     of re-reading the regfile — RAW hazards at distance-1 (including
 *     load-use and DIV/REM) cost zero bubbles;
 *   - resolves branches and redirects fetch (branch_valid_o /
 *     branch_addr_o), flushing decode's D/E register on a taken branch;
 *   - resolves sync traps / mret / interrupts at the commit point and
 *     drives the trap unit interface;
 *   - drives the native mem_req_o / mem_rsp_i port (the LSU) toward the
 *     peri bridge: loads/stores/Zilx indexed loads launch, stall the
 *     pipe until the response (loads) or retire on launch-accept
 *     (posted stores), and retire.
 *
 * fe_* (fetch) / de_* (decode) / ex_* (execute) taps follow the
 * stage-sigil convention: ex_* is the E/M register — pc / instr / valid
 * of the retired operation.
 *
 * Memory (LSU): loads / stores / Zilx indexed loads launch on the native
 * mem_req_o / mem_rsp_i (or peri_req_o / peri_rsp_i) port. A unified FSM
 * extends the DIV/REM busy state with EX_MEM_WAIT: a mem op launches the
 * cycle it is valid in EX_IDLE (wvalid=1, bridge wready=1 in its idle),
 * then the pipe stalls in EX_MEM_WAIT until the read response (rvalid,
 * load) retires it. Stores are posted: they retire the same cycle as
 * launch-accept, not on bvalid — the bridge owns the write->B round
 * trip and naturally stalls any following mem op via wready until the
 * store actually completes (RAW-through-memory ordering preserved
 * there). Loads write back via WB_MEM with sub-word extract +
 * sign/zero extension.
 *
 * Current limitations:
 *
 *   - No trap delegation / PMP / S-U mode (machine mode only).
 *   - A misaligned access (LH/LHU at addr[0]=1, LW/SW at addr[1:0]!=0)
 *     raises a load/store-address-misaligned sync trap; a sub-word
 *     access crossing a word boundary is not handled.
 *   - DIV/REM overflow (INT_MIN / -1) is not handled (see alu.sv).
 *
 * Naming: ports *_i/_o; internals no prefix; flops _q/_d; instances u_*.
 */

module execute_stage (
    input wire clk_i,
    input wire rstn_i,

    // D/E control word from decode.
    input de_t de_i,

    // CSR Regfile
    input  wire [XLEN-1:0] csr_rdata_i,  // read CSR value (old)
    output wire [XLEN-1:0] csr_wdata_o,  // write CSR value (new, RMW result)
    output wire            csr_wren_o,   // CSR write enable (execute-qualified)

    // Trap unit interface (trap unit lives at the CPU top, a peer of the
    // execute stage). Execute = "exception logic": it detects the triggers
    // and resolves cause/tval/pc from de_i + the EA, and exports them; the
    // trap unit consumes them, drives the CSR trap-write bundle + the fetch
    // redirect, and reports the pending+enabled interrupt back here.
    //
    // A pending+enabled machine interrupt (from the trap unit's read of
    // mstatus.MIE / mip / mie): MSIP and/or MTIP. Read to decide
    // take_interrupt and to wake WFI halt.
    input wire            int_pending_i,
    // The trap unit's resolved interrupt cause (MSI > MTI priority), used
    // as the mcause when an interrupt is taken.
    input wire [XLEN-1:0] int_cause_i,
    // The trap unit's resolved fetch target (mtvec vector for traps /
    // interrupts, mepc for mret). Merged with the normal branch redirect.
    input wire [XLEN-1:0] trap_redirect_addr_i,

    // Triggers + payload to the trap unit.
    output wire            sync_trap_req_o,   // sync exception entry
    output wire            mret_req_o,        // mret return
    output wire            take_interrupt_o,  // async interrupt entry
    output wire [XLEN-1:0] trap_cause_o,      // mcause value
    output wire [XLEN-1:0] trap_tval_o,       // mtval value
    output wire [XLEN-1:0] trap_pc_o,         // mepc value

    // Back-pressure from a future downstream stage (tied 0 now).
    input wire stall_i,

    // Back-pressure to decode: stall the D/E register while a DIV/REM
    // is running (and the launch cycle).
    output wire stall_o,

    // Flush decode's D/E register on a taken branch.
    output wire flush_o,

    // Writeback to the register file. wb_data_o is driven procedurally in
    // the writeback always_comb below, so it must be a variable (logic),
    // not a wire — a wire/net cannot take a procedural assignment
    // (GowinSynthesis EX3900). The assign-driven wb_addr_o / wb_en_o stay
    // wire.
    output wire  [     4:0] wb_addr_o,
    output logic [XLEN-1:0] wb_data_o,
    output wire             wb_en_o,

    // Branch redirect to fetch.
    output wire            branch_valid_o,
    output wire [XLEN-1:0] branch_addr_o,

    // Native memory interface (LSU): loads/stores/Zilx launch here.
    output mem_req_t mem_req_o,
    input  mem_rsp_t mem_rsp_i,
    // Native memory interface for peripherals
    output mem_req_t peri_req_o,
    input  mem_rsp_t peri_rsp_i,

    // ex_* per-stage taps (E/M register): pc / instr / valid of the retired
    // op. Named like fetch's fe_*_o (no _dbg suffix) so every pipeline stage
    // exposes a uniform pc / instr / valid output.
    output wire [XLEN-1:0] ex_pc_o,
    output wire [XLEN-1:0] ex_instr_o,
    output wire            ex_valid_o
);

    // =================================================================
    // Operand selection + PC-link (PC+2 compressed / PC+4)
    // =================================================================
    logic [XLEN-1:0] pc_link;
    assign pc_link = de_i.pc + (de_i.is_compressed ? 32'd2 : 32'd4);

    logic [XLEN-1:0] operand_a, operand_b;

    always_comb begin
        unique case (de_i.alu_src_a)
            ALU_A_RS1: operand_a = de_i.rs1_data;
            ALU_A_PC:  operand_a = de_i.pc;
            ALU_A_CSR: operand_a = csr_rdata_i;  // read CSR value
            ALU_A_RS2: operand_a = de_i.rs2_data;
            default:   operand_a = '0;
        endcase
        unique case (de_i.alu_src_b)
            ALU_B_RS1:  operand_b = de_i.rs1_data;
            ALU_B_IMM:  operand_b = de_i.imm;
            ALU_B_RS2:  operand_b = de_i.rs2_data;
            ALU_B_PC4:  operand_b = pc_link;
            ALU_B_ZERO: operand_b = '0;
            default:    operand_b = '0;
        endcase
    end

    // =================================================================
    // Multi-cycle op control: DIV/REM and memory (LSU) share one FSM.
    //
    // EX_IDLE    : ready. A DIV/REM launches (alu_start) -> EX_DIV_BUSY.
    //              A mem op launches (mem_launch: wvalid=1 && bridge
    //              wready) -> EX_MEM_WAIT. Single-cycle ALU/branch ops
    //              retire the same cycle and stay in EX_IDLE.
    // EX_DIV_BUSY: hold the pipe until the ALU asserts result_valid_o.
    // EX_MEM_WAIT: hold the pipe until the load read response (rvalid) or
    //              the store write-ack (bvalid) retires the op.
    //
    // de_i is held stable across the busy/wait states by decode's stall
    // (stall_o below holds decode's D/E register), so the ALU result (EA)
    // and the mem op fields stay valid through EX_MEM_WAIT. The done cycle
    // drops the stall so decode advances and the op is not relaunched
    // (ex_state_q is still BUSY/WAIT at done, so alu_start / mem_launch
    // are 0; it clears to IDLE for the next cycle's new de_i).
    // =================================================================
    logic is_div_op;
    assign is_div_op = de_i.alu_op inside {ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU};

    logic is_mem_op;
    assign is_mem_op = de_i.mem_read | de_i.mem_write;

    // Misaligned access: raises a precise sync trap (LAD_MIS / SAD_MIS)
    // below; the access never launches.
    // LH/LHU needs addr[0]=0; LW/SW needs addr[1:0]=00. Because every
    // misaligned case traps here, no access that reaches the LSU can cross a
    // word boundary, so the single-beat slaves are always sufficient.
    // Byte accesses (LB/LBU/SB) are always within a word. Only mem ops
    // can be misaligned — non-mem ops reuse mem_size as a don't-care
    // decode default (MS_W) and must NOT be suppressed, so gate on
    // is_mem_op.
    logic mem_misaligned;
    always_comb begin
        if (!is_mem_op) begin
            mem_misaligned = 1'b0;
        end else begin
            unique case (de_i.mem_size)
                MS_B:    mem_misaligned = 1'b0;
                MS_H:    mem_misaligned = alu_result[0];
                MS_W:    mem_misaligned = |alu_result[1:0];
                default: mem_misaligned = 1'b1;
            endcase
        end
    end

    typedef enum logic [1:0] {
        EX_IDLE,
        EX_DIV_BUSY,
        EX_MEM_WAIT
    } ex_state_e;
    ex_state_e ex_state_q, ex_state_d;

    logic alu_start;
    assign
        alu_start = de_i.valid & is_div_op & (ex_state_q == EX_IDLE) & ~freeze & ~trap_redirect_req;

    logic            alu_result_valid;
    logic [XLEN-1:0] alu_result;

    // Mem launch: assert wvalid for one cycle in EX_IDLE on a valid,
    // aligned mem op. The bridge is idle (wready=1) whenever the LSU is
    // idle (single-outstanding), so the launch handshakes the same cycle
    // and the FSM moves to EX_MEM_WAIT.
    logic            mem_launch;
    assign mem_launch = de_i.valid & is_mem_op & ~mem_misaligned &
        (ex_state_q == EX_IDLE) & ~freeze & ~trap_redirect_req;

    // Effective address selects the LSU target: D-mem (addr[PERI_ADDR_BIT]=0)
    // or the peri bridge (=1). alu_result (the EA) is held stable through
    // EX_MEM_WAIT (decode stalls de_i), so this one combinational bit drives
    // both the request target and the response source — no tracking flops
    // needed (the LSU is single-outstanding).
    wire is_peri = alu_result[PERI_ADDR_BIT];

    // Effective LSU response: the selected target's rsp (Harvard dmem/peri).
    // All launch/done/load logic reads this so a peri op does not falsely
    // retire on the D-mem's wready/rvalid (the bug from splitting only the
    // request side).
    mem_rsp_t lsu_rsp;
    assign lsu_rsp = is_peri ? peri_rsp_i : mem_rsp_i;

    wire  mem_launch_hs = mem_launch & lsu_rsp.wready;

    // Posted store: once the bridge accepts AW+W (mem_launch_hs on a
    // write), it owns the write->B round trip on its own; the LSU
    // retires the same cycle instead of waiting for bvalid. Correctness:
    // the bridge is single-outstanding and only re-asserts wready once B
    // completes, so any *following* mem op still naturally stalls
    // (wready low) until the store has actually finished at the bridge -
    // RAW-through-memory ordering is preserved there, not by the LSU
    // waiting here. Loads still need EX_MEM_WAIT: data isn't available
    // until rvalid.
    logic mem_done;
    assign mem_done = (ex_state_q == EX_MEM_WAIT) & lsu_rsp.rvalid;

    logic store_done;
    assign store_done = mem_launch_hs & de_i.mem_write;

    // Unified mem-op retire pulse: rvalid cycle for loads, launch-accept
    // cycle for (posted) stores.
    logic mem_op_done;
    assign mem_op_done = de_i.mem_read ? mem_done : store_done;

    logic div_running;
    assign div_running = (ex_state_q == EX_DIV_BUSY) & ~alu_result_valid;
    // Stall the launch + busy/wait cycles; the done cycle drops the stall
    // so decode advances (mem_running falls away the cycle mem_done=1).
    logic mem_running;
    assign mem_running = (ex_state_q == EX_MEM_WAIT) & ~mem_done;
    assign stall_o = alu_start | div_running | (mem_launch & ~store_done) | mem_running | stall_i |
        wfi_stall;

    always_comb begin
        ex_state_d = ex_state_q;
        unique case (ex_state_q)
            EX_IDLE: begin
                if (alu_start) ex_state_d = EX_DIV_BUSY;
                else if (mem_launch_hs)
                    ex_state_d = de_i.mem_read ? EX_MEM_WAIT : EX_IDLE;  // store retires now
            end
            EX_DIV_BUSY: if (alu_result_valid) ex_state_d = EX_IDLE;
            EX_MEM_WAIT: if (mem_done) ex_state_d = EX_IDLE;
            default:     ex_state_d = EX_IDLE;
        endcase
    end

    // =================================================================
    // ALU instance
    // =================================================================
    alu u_alu (
        .clk_i         (clk_i),
        .rst_ni        (rstn_i),
        .operand_a_i   (operand_a),
        .operand_b_i   (operand_b),
        .alu_op_i      (de_i.alu_op),
        .shamt_i       (de_i.mem_shamt),
        .start_i       (alu_start),
        .result_valid_o(alu_result_valid),
        .result_o      (alu_result)
    );

    // =================================================================
    // Trap / interrupt / mret (precise, at the commit point).
    //
    // Sync traps (illegal / ecall / ebreak / misaligned) fire in EX_IDLE the
    // cycle the faulting op would retire; the op commits as a trap (ex_valid
    // pulses, counts to minstret). mret commits and redirects to mepc. A
    // pending machine software interrupt is taken instead of retiring the
    // next normal instruction (suppressed, re-runs after mret) OR on a WFI
    // wake; it does NOT count as a retire. All three flush decode (kill
    // younger in-flight) and redirect fetch via branch_valid_o / branch_addr_o
    // (the trap unit's redirect merges with the normal branch redirect).
    //
    // Priority: sync trap > interrupt > mret > normal branch. Traps/mret/
    // interrupt never coincide with a normal branch (a branch is squashed by
    // take_interrupt; an illegal branch already trapped at decode).
    //
    // `freeze` extends the downstream stall with the WFI-halt freeze so a
    // held instruction does not retire/launch while waiting for a pending
    // interrupt. take_interrupt clears wfi_stall the cycle it fires, so
    // freeze drops out and the interrupt proceeds.
    // =================================================================
    wire is_wfi_op = (de_i.sys_op == SYS_WFI);
    wire is_mret_op = (de_i.sys_op == SYS_MRET);

    // WFI halt state. Declared early: wfi_stall / freeze gate the trap
    // predicates below, and freeze extends the downstream stall.
    // int_pending_i comes from the trap unit at the CPU top (combinational
    // from the CSR taps); trap_redirect_addr_i is the trap unit's resolved
    // fetch target (mtvec vector / mepc), merged with the normal branch
    // redirect in branch_valid_o / branch_addr_o below.
    logic wfi_halt_q;
    logic [XLEN-1:0] wfi_next_pc_q;
    wire wfi_stall = wfi_halt_q & ~int_pending_i;
    wire freeze = stall_i | wfi_stall;

    // Sync trap request: illegal/ecall/ebreak (decode exception) OR a
    // misaligned load/store detected here (needs the EA). Fires only in
    // EX_IDLE (misaligned never launches; system traps are single-cycle).
    wire sync_trap_req = de_i.valid & ~freeze & (ex_state_q == EX_IDLE) &
        (de_i.exception | mem_misaligned);

    wire mret_req = de_i.valid & ~freeze & (ex_state_q == EX_IDLE) & is_mret_op;

    // A normal instruction eligible to be squashed by an interrupt (any
    // non-trap, non-mret, non-wfi valid op in EX_IDLE). WFI is excluded: it
    // retires (commit) then halts; the interrupt is taken on the WFI wake
    // path (wfi_halt_q) with mepc = wfi.pc + size.
    wire normal_int_eligible = de_i.valid & ~is_wfi_op & ~de_i.exception &
        (ex_state_q == EX_IDLE) & ~freeze;

    wire take_interrupt = int_pending_i & ~sync_trap_req & ~mret_req &
        (normal_int_eligible | wfi_halt_q);

    wire trap_redirect_req = sync_trap_req | mret_req | take_interrupt;

    // Payload resolved for the trap unit (at the CPU top). A misaligned
    // access overrides the decode cause/tval (bad EA); an interrupt forces
    // the MSI cause / tval=0. The trap unit consumes these as cause_i /
    // tval_i / pc_i and produces the redirect + CSR trap-write bundle.
    wire [XLEN-1:0] sync_cause = mem_misaligned ?
        (de_i.mem_write ? MCAUSE_SAD_MIS : MCAUSE_LAD_MIS) : de_i.exception_cause;
    wire [XLEN-1:0] sync_tval = mem_misaligned ? alu_result : de_i.exception_tval;
    wire [XLEN-1:0] trap_cause = take_interrupt ? int_cause_i : sync_cause;
    wire [XLEN-1:0] trap_tval = take_interrupt ? 32'd0 : sync_tval;
    // mepc: faulting instr pc (sync trap), or the suppressed instr pc
    // (interrupt), or the WFI-wake pc (interrupt taken after WFI).
    wire [XLEN-1:0] wfi_next_pc = de_i.pc + (de_i.is_compressed ? 32'd2 : 32'd4);
    wire [XLEN-1:0] trap_mepc = wfi_halt_q ? wfi_next_pc_q : de_i.pc;

    // Export the triggers + payload to the trap unit (CPU top).
    assign sync_trap_req_o  = sync_trap_req;
    assign mret_req_o       = mret_req;
    assign take_interrupt_o = take_interrupt;
    assign trap_cause_o     = trap_cause;
    assign trap_tval_o      = trap_tval;
    assign trap_pc_o        = trap_mepc;

    // -----------------------------------------------------------------
    // WFI halt. WFI retires (commit) once, then freezes the pipe until a
    // pending+enabled interrupt wakes it. The interrupt is taken on the
    // wake via the wfi_halt_q branch of take_interrupt, with mepc =
    // wfi.pc + size (the instruction that will execute after the handler).
    // freeze = the downstream stall OR the WFI wait; take_interrupt clears
    // wfi_stall the cycle it fires (int_pending high -> wfi_stall low), so
    // freeze drops out and the interrupt proceeds.
    // -----------------------------------------------------------------
    wire wfi_retire = de_i.valid & (ex_state_q == EX_IDLE) &
        is_wfi_op & ~trap_redirect_req & ~stall_i;

    logic wfi_halt_d;
    logic [XLEN-1:0] wfi_next_pc_d;

    // =================================================================
    // Writeback (ALU / PC4 / MEM). A load retires via WB_MEM with sub-word
    // extract + sign/zero extension; stores have reg_write=0 (no wb).
    // =================================================================
    // Load alignment: the memory returns the containing word; shift the
    // addressed bytes down to bit 0, then sign/zero-extend per mem_size
    // and mem_unsigned. The result is sampled the cycle mem_done (rvalid)
    // pulses, when rdata is valid.
    //
    // The byte offset comes from a copy of the effective address latched at
    // launch, NOT from the live alu_result. alu_result is combinational out
    // of the D/E operands, and those operands can be fed by the
    // execute->decode forward path, so reading it a cycle (or several)
    // later means the byte select depends on the whole
    // regfile -> forward mux -> adder chain still being settled and
    // unchanged at response time. That is the design's critical path, and
    // on hardware it was not settled: a load whose address came from a
    // distance-1 forward (an `add` immediately followed by `lbu`, which is
    // what indexing a table with a computed index compiles to) selected
    // byte 0 instead of the addressed byte, while the same load with the
    // address already committed in the regfile was correct. It read the
    // right word every time -- only the byte select was wrong -- so
    // hex[(v >> i) & 0xF] returned hex[i & ~3] and every hex value printed
    // on the board came out with the low two bits of each nibble cleared.
    // Simulation could not show it: there the chain settles inside the
    // cycle regardless of its depth.
    //
    // Latching also shortens the response-cycle path to a flop output.
    logic [1:0] mem_addr_lo_q;

    // Latched on the accept handshake, not on the request being asserted:
    // the request can be held for several cycles while the slave is busy,
    // and the accept edge is the one the memory samples the address on.
    always_ff @(posedge clk_i) begin
        if (!rstn_i) mem_addr_lo_q <= 2'b00;
        else if (mem_launch_hs) mem_addr_lo_q <= alu_result[1:0];
    end

`ifdef VERILATOR
    // The flop is only correct because a read response never arrives in the
    // same cycle as the accept: every slave in the tree registers rdata, so
    // rvalid is at least one cycle later. Check it rather than trust it.
    always_ff @(posedge clk_i) begin
        if (rstn_i && mem_launch_hs && de_i.mem_read) begin
            assert (!lsu_rsp.rvalid)
            else $fatal(1, "load response in the accept cycle: latched byte offset is stale");
        end
    end
`endif

    logic [XLEN-1:0] load_shifted;
    logic [XLEN-1:0] load_data;
    assign load_shifted = lsu_rsp.rdata >> {mem_addr_lo_q, 3'b000};
    always_comb begin
        unique case (de_i.mem_size)
            MS_B:
            load_data = de_i.mem_unsigned ?
                {24'b0, load_shifted[7:0]} : {{24{load_shifted[7]}}, load_shifted[7:0]};
            MS_H:
            load_data = de_i.mem_unsigned ?
                {16'b0, load_shifted[15:0]} : {{16{load_shifted[15]}}, load_shifted[15:0]};
            MS_W: load_data = lsu_rsp.rdata;
            default: load_data = lsu_rsp.rdata;
        endcase
    end

    always_comb begin
        unique case (de_i.wb_src)
            WB_ALU:  wb_data_o = alu_result;
            WB_PC4:  wb_data_o = pc_link;
            WB_MEM:  wb_data_o = load_data;
            WB_CSR:  wb_data_o = csr_rdata_i;  // rd <- old CSR value
            default: wb_data_o = '0;
        endcase
    end
    assign wb_addr_o = de_i.rd;

    // Result ready: single-cycle ALU/branch and the mem launch cycle have
    // alu_result_valid=1 (combinational ALU); DIV/REM on alu_result_valid;
    // a load on mem_done (rvalid). Stores have reg_write=0 so their
    // result_ready is don't-care for the regfile write.
    logic result_ready;
    assign result_ready = is_mem_op ? mem_op_done : alu_result_valid;

    assign wb_en_o = de_i.valid & de_i.reg_write & ~de_i.illegal & ~freeze &
        result_ready & ~mem_misaligned & ~trap_redirect_req;

    // =================================================================
    // CSR read-modify-write (Zicsr). The old CSR value is csr_rdata_i
    // (async read of de_i.csr_addr in the CSR file); rd <- old via
    // WB_CSR (above). The new value (csr_wdata_o) is the RMW result,
    // written to the CSR file when csr_wren_o pulses. The ALU result is
    // unused for CSR ops. CSRRS/CSRRC (and their immediate forms) do not
    // write the CSR when the source is zero; CSRRW always writes. A CSR
    // op is single-cycle (combinational ALU => result_ready=1).
    // =================================================================
    logic [XLEN-1:0] csr_src;
    logic [XLEN-1:0] csr_new;
    logic            csr_op_valid;
    logic            csr_we;

    // Source: rs1 for the register forms, zero-extended 5-bit zimm
    // (carried in de_i.imm by decode) for the immediate forms.
    always_comb begin
        if (de_i.csr_op inside {CSR_RWI, CSR_RSI, CSR_RCI}) csr_src = de_i.imm;
        else csr_src = de_i.rs1_data;
    end

    // Same retire predicate as the regfile writeback (result_ready=1 for
    // a CSR op). de_i.csr_wren is decode's "CSR op present" flag, already
    // squashed by illegal in decode.
    assign csr_op_valid = de_i.valid & de_i.csr_wren & ~de_i.illegal & ~freeze &
        result_ready & ~mem_misaligned & ~trap_redirect_req;

    always_comb begin
        unique case (de_i.csr_op)
            CSR_RW, CSR_RWI: begin
                csr_new = csr_src;
                csr_we  = csr_op_valid;  // CSRRW always writes
            end
            CSR_RS, CSR_RSI: begin
                csr_new = csr_rdata_i | csr_src;
                csr_we  = csr_op_valid & (csr_src != '0);  // no write if src==0
            end
            CSR_RC, CSR_RCI: begin
                csr_new = csr_rdata_i & ~csr_src;
                csr_we  = csr_op_valid & (csr_src != '0);  // no write if src==0
            end
            default: begin
                csr_new = '0;
                csr_we  = 1'b0;
            end
        endcase
    end

    assign csr_wdata_o = csr_new;
    assign csr_wren_o  = csr_we;

    // =================================================================
    // Memory interface (LSU). The effective address (Zilx indexed or
    // base+offset) is the ALU result. A store's data is pre-shifted into
    // the byte lanes selected by wstrb (the slave writes wdata[byte] when
    // wstrb[byte]). rready is asserted in EX_MEM_WAIT on a load so the
    // bridge forwards it to the AXI R channel and the read completes.
    // =================================================================
    logic [STRB_WIDTH-1:0] store_wstrb;
    always_comb begin
        // Byte strobes for a store of de_i.mem_size at alu_result.
        unique case (de_i.mem_size)
            MS_B: store_wstrb = 4'b0001 << alu_result[1:0];
            MS_H: store_wstrb = 4'b0011 << {alu_result[1], 1'b0};
            MS_W: store_wstrb = 4'b1111;
            default: store_wstrb = 4'b1111;
        endcase
    end

    logic [XLEN-1:0] store_wdata;
    assign store_wdata = de_i.rs2_data << {alu_result[1:0], 3'b000};

    // Harvard: steer the launch to D-mem (is_peri=0) or the peri bridge
    // (is_peri=1). Both ports get full defaults so the non-selected port is
    // cleanly idle (no latch / no stray wvalid).
    always_comb begin
        mem_req_o.wvalid  = 1'b0;
        mem_req_o.we      = 1'b0;
        mem_req_o.addr    = '0;
        mem_req_o.wdata   = '0;
        mem_req_o.wstrb   = '0;
        mem_req_o.rready  = 1'b0;
        peri_req_o.wvalid = 1'b0;
        peri_req_o.we     = 1'b0;
        peri_req_o.addr   = '0;
        peri_req_o.wdata  = '0;
        peri_req_o.wstrb  = '0;
        peri_req_o.rready = 1'b0;
        if (is_peri) begin
            peri_req_o.wvalid = mem_launch;  // launch one cycle in EX_IDLE
            peri_req_o.we     = de_i.mem_write;
            peri_req_o.addr   = alu_result;  // EA
            peri_req_o.wdata  = store_wdata;
            peri_req_o.wstrb  = store_wstrb;
            peri_req_o.rready = (ex_state_q == EX_MEM_WAIT) & de_i.mem_read;
        end else begin
            mem_req_o.wvalid = mem_launch;  // launch one cycle in EX_IDLE
            mem_req_o.we     = de_i.mem_write;
            mem_req_o.addr   = alu_result;  // EA
            mem_req_o.wdata  = store_wdata;
            mem_req_o.wstrb  = store_wstrb;
            mem_req_o.rready = (ex_state_q == EX_MEM_WAIT) & de_i.mem_read;
        end
    end

    // =================================================================
    // Branch resolve + redirect
    // =================================================================
    logic branch_taken;
    always_comb begin
        unique case (de_i.branch_type)
            BR_BEQ:  branch_taken = (de_i.rs1_data == de_i.rs2_data);
            BR_BNE:  branch_taken = (de_i.rs1_data != de_i.rs2_data);
            BR_BLT:  branch_taken = ($signed(de_i.rs1_data) < $signed(de_i.rs2_data));
            BR_BGE:  branch_taken = ($signed(de_i.rs1_data) >= $signed(de_i.rs2_data));
            BR_BLTU: branch_taken = (de_i.rs1_data < de_i.rs2_data);
            BR_BGEU: branch_taken = (de_i.rs1_data >= de_i.rs2_data);
            BR_JAL:  branch_taken = 1'b1;
            BR_JALR: branch_taken = 1'b1;
            default: branch_taken = 1'b0;  // BR_NONE
        endcase
    end

    // Normal branch target / request (a taken JAL/JALR/branch). Gated by
    // ~trap_redirect_req: a branch squashed by an interrupt re-runs after
    // mret instead of redirecting now.
    wire [XLEN-1:0] branch_target = (de_i.branch_type == BR_JALR) ?
        (de_i.rs1_data + de_i.imm) & 32'hFFFF_FFFE : (de_i.pc + de_i.imm);

    wire branch_redirect_req = de_i.valid & ~de_i.illegal & (de_i.branch_type != BR_NONE) &
        branch_taken & ~freeze & alu_result_valid & ~trap_redirect_req;

    // Combined fetch redirect: a normal branch OR a trap / mret / interrupt.
    // The trap unit's redirect_addr (from the CPU top) wins when a
    // trap/mret/interrupt fires.
    assign branch_valid_o = branch_redirect_req | trap_redirect_req;
    assign branch_addr_o  = trap_redirect_req ? trap_redirect_addr_i : branch_target;
    assign flush_o        = branch_valid_o;

    // =================================================================
    // E/M debug taps (retired instruction)
    // =================================================================
    logic [XLEN-1:0] ex_pc_q, ex_pc_d;
    logic [XLEN-1:0] ex_instr_q, ex_instr_d;
    logic ex_valid_q, ex_valid_d;

    // An op commits (retires -> ex_valid pulses, counts to minstret, logged
    // by the sim retire trace) when it retires normally, OR when an mret
    // retires. A sync trap does NOT commit: the faulting instruction is not
    // retired (it raised an exception before committing -- per the RISC-V
    // spec and Spike's --log-commits, which does not emit a commit line for
    // a trapping instruction). An interrupt does NOT commit either: the
    // squashed instruction re-runs after mret. WFI retires once (normal
    // path, result_ready=1 for the ALU-hint op) then halts. A misaligned
    // mem op is NOT in the normal path -- it raises a sync trap and does
    // not commit. The trap machinery itself (CSR trap-write bundle, fetch
    // redirect) is independent of ex_valid, so traps still fire correctly;
    // only the retire count is suppressed.
    logic op_commits;
    assign op_commits = take_interrupt ? 1'b0 : sync_trap_req ? 1'b0 :
        mret_req ? 1'b1 : (de_i.valid & ~de_i.illegal & ~freeze & result_ready & ~mem_misaligned);

    assign ex_pc_d = op_commits ? de_i.pc : ex_pc_q;
    assign ex_instr_d = op_commits ? de_i.instr : ex_instr_q;
    assign ex_valid_d = op_commits;

    assign ex_pc_o = ex_pc_q;
    assign ex_instr_o = ex_instr_q;
    assign ex_valid_o = ex_valid_q;

    // WFI halt next-state: set when WFI retires, cleared as soon as an
    // interrupt is pending+enabled. wfi_next_pc holds the return PC for the
    // wake.
    //
    // The clear condition is int_pending_i, NOT take_interrupt: take_interrupt
    // loses priority to sync_trap_req / mret_req (see the take_interrupt term
    // above), so clearing on it would leave wfi_halt_q stuck when the
    // instruction behind the WFI faults. A stuck wfi_halt_q re-raises
    // wfi_stall the moment trap entry clears mstatus.MIE (int_pending falls),
    // freezing the pipe inside the handler with no way to retire the CSR write
    // that would re-enable interrupts -- an unrecoverable deadlock. Clearing
    // on int_pending_i releases the halt whichever event actually wins.
    assign wfi_halt_d = wfi_retire | (wfi_halt_q & ~int_pending_i);
    assign wfi_next_pc_d = wfi_retire ? wfi_next_pc : wfi_next_pc_q;

    // =================================================================
    // Sequential
    // =================================================================
    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            ex_state_q    <= EX_IDLE;
            ex_pc_q       <= '0;
            ex_instr_q    <= '0;
            ex_valid_q    <= 1'b0;
            wfi_halt_q    <= 1'b0;
            wfi_next_pc_q <= '0;
        end else begin
            ex_state_q    <= ex_state_d;
            ex_pc_q       <= ex_pc_d;
            ex_instr_q    <= ex_instr_d;
            ex_valid_q    <= ex_valid_d;
            wfi_halt_q    <= wfi_halt_d;
            wfi_next_pc_q <= wfi_next_pc_d;
        end
    end

endmodule

`resetall
