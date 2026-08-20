`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
 * Execute stage (DRAFT) — consumes the D/E control word (de_i) from
 * decode and:
 *
 *   - selects the ALU operands (rs1 / rs2 / pc / imm / pc4 / rs1-shifted)
 *     per de_i.alu_src_a / alu_src_b;
 *   - drives the ALU (base RV32I + M + Zilx EA), launching the
 *     multi-cycle DIV/REM with start_i and stalling the pipe until the
 *     ALU asserts result_valid_o;
 *   - writes back ALU / PC4 / load (MEM) results to the register file
 *     (stores carry no reg writeback); loads retire via WB_MEM once the
 *     read response arrives;
 *   - resolves branches and redirects fetch (branch_valid_o /
 *     branch_addr_o), flushing decode's D/E register on a taken branch;
 *   - drives the native mem_req_o / mem_rsp_i port (the LSU) toward the
 *     peri bridge: loads/stores/Zilx indexed loads launch, stall the pipe
 *     until the response, and retire.
 *
 * The CPU top used to tie the reg-file write port, the fetch redirect,
 * and decode's stall/flush to inert constants; this stage now drives
 * them. fe_* (fetch) / de_* (decode) / ex_* (execute) taps follow the
 * stage-sigil convention: ex_* is the E/M register — pc / instr / valid
 * of the retired operation.
 *
 * Memory (LSU): loads / stores / Zilx indexed loads launch on the native
 * mem_req_o / mem_rsp_i port (the peri bridge). A unified FSM extends the
 * DIV/REM busy state with EX_MEM_WAIT: a mem op launches the cycle it is
 * valid in EX_IDLE (wvalid=1, bridge wready=1 in its idle), then the pipe
 * stalls in EX_MEM_WAIT until the read response (rvalid, load) or the
 * write-ack (bvalid, store) retires it. Loads write back via WB_MEM with
 * sub-word extract + sign/zero extension; stores carry pre-shifted data
 * and byte strobes (no reg writeback). The decode stall-on-RAW interlock
 * then covers load-use: a consumer right behind a load is held in decode
 * while the load occupies execute, and bubbles the cycle the load's wb_en
 * pulses — so it re-reads the fresh loaded value (one bubble, no bypass).
 *
 * Known DRAFT limitations:
 *
 *   - No bypass path. Register RAW hazards are resolved by decode's
 *     stall-on-RAW interlock (one bubble), not by forwarding. Load-use is
 *     covered the same way (the load's extra execute cycles hold the
 *     consumer in decode; the wb_en pulse triggers the bubble). No
 *     forwarding means each dependent op pays the bubble.
 *
 *   - No trap / exception support. A misaligned access (LH/LHU at
 *     addr[0]=1, LW at addr[1:0]!=0, or the SH/SW equivalents) is
 *     SUPPRESSED — not launched, not retired, no writeback — rather than
 *     trapping. Cross-word sub-word accesses that would need two beats
 *     are not handled. The Zicsr CSR RMW is in (CSRRW/S/C + immediate
 *     variants retire via csr_regfile), but ecall/ebreak/mret/wfi and
 *     trap entry/return are still absent — add the exception pipeline
 *     before relying on aligned-only code.
 *
 *   - DIV/REM result is not bypassed (see hazard note): a consumer in
 *     the slot right after the div reads the stale value — resolved by
 *     the interlock's bubble, not forwarding.
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

    // Misaligned access: suppressed (no trap / exception support yet).
    // LH/LHU needs addr[0]=0; LW/SW needs addr[1:0]=00. A sub-word that
    // would cross a word boundary needs two beats and is not handled.
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
    assign alu_start = de_i.valid & is_div_op & (ex_state_q == EX_IDLE) & ~stall_i;

    logic            alu_result_valid;
    logic [XLEN-1:0] alu_result;

    // Mem launch: assert wvalid for one cycle in EX_IDLE on a valid,
    // aligned mem op. The bridge is idle (wready=1) whenever the LSU is
    // idle (single-outstanding), so the launch handshakes the same cycle
    // and the FSM moves to EX_MEM_WAIT.
    logic            mem_launch;
    assign
        mem_launch = de_i.valid & is_mem_op & ~mem_misaligned & (ex_state_q == EX_IDLE) & ~stall_i;
    wire  mem_launch_hs = mem_launch & mem_rsp_i.wready;

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
    assign mem_done = (ex_state_q == EX_MEM_WAIT) & mem_rsp_i.rvalid;

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
    assign stall_o     = alu_start | div_running | mem_launch | mem_running | stall_i;

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
    // Writeback (ALU / PC4 / MEM). A load retires via WB_MEM with sub-word
    // extract + sign/zero extension; stores have reg_write=0 (no wb).
    // =================================================================
    // Load alignment: the peri RAM returns the containing word; shift the
    // addressed bytes down to bit 0, then sign/zero-extend per mem_size
    // and mem_unsigned. The result is sampled the cycle mem_done (rvalid)
    // pulses, when rdata is valid.
    logic [XLEN-1:0] load_shifted;
    logic [XLEN-1:0] load_data;
    assign load_shifted = mem_rsp_i.rdata >> {alu_result[1:0], 3'b000};
    always_comb begin
        unique case (de_i.mem_size)
            MS_B:
            load_data = de_i.mem_unsigned ?
                {24'b0, load_shifted[7:0]} : {{24{load_shifted[7]}}, load_shifted[7:0]};
            MS_H:
            load_data = de_i.mem_unsigned ?
                {16'b0, load_shifted[15:0]} : {{16{load_shifted[15]}}, load_shifted[15:0]};
            MS_W: load_data = mem_rsp_i.rdata;
            default: load_data = mem_rsp_i.rdata;
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

    assign wb_en_o = de_i.valid & de_i.reg_write & ~de_i.illegal & ~stall_i &
        result_ready & ~mem_misaligned;

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
    assign csr_op_valid = de_i.valid & de_i.csr_wren & ~de_i.illegal & ~stall_i &
        result_ready & ~mem_misaligned;

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

    always_comb begin
        mem_req_o.wvalid = mem_launch;  // launch one cycle in EX_IDLE
        mem_req_o.we     = de_i.mem_write;
        mem_req_o.addr   = alu_result;  // EA
        mem_req_o.wdata  = store_wdata;
        mem_req_o.wstrb  = store_wstrb;
        mem_req_o.rready = (ex_state_q == EX_MEM_WAIT) & de_i.mem_read;
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

    assign branch_addr_o = (de_i.branch_type == BR_JALR) ?
        (de_i.rs1_data + de_i.imm) & 32'hFFFF_FFFE : (de_i.pc + de_i.imm);

    // Branches are single-cycle (ALU placeholder op, result_valid=1), so
    // alu_result_valid is always 1 for them; gate on it anyway for safety.
    assign branch_valid_o = de_i.valid & ~de_i.illegal & (de_i.branch_type != BR_NONE) &
        branch_taken & ~stall_i & alu_result_valid;
    assign flush_o = branch_valid_o;

    // =================================================================
    // E/M debug taps (retired instruction)
    // =================================================================
    logic [XLEN-1:0] ex_pc_q, ex_pc_d;
    logic [XLEN-1:0] ex_instr_q, ex_instr_d;
    logic ex_valid_q, ex_valid_d;

    // An op retires when it is valid, not illegal, and its result is ready
    // (alu_result_valid for ALU/DIV, mem_done for a load/store). A
    // misaligned mem op is suppressed — it never reaches EX_MEM_WAIT, so
    // its result_ready stays 0 and it does not retire. Single-cycle ops
    // retire the cycle they are valid; DIV/REM on alu_result_valid; mem
    // ops on mem_done.
    logic op_retires;
    assign op_retires = de_i.valid & ~de_i.illegal & ~stall_i & result_ready & ~mem_misaligned;

    assign ex_pc_d    = op_retires ? de_i.pc : ex_pc_q;
    assign ex_instr_d = op_retires ? de_i.instr : ex_instr_q;
    assign ex_valid_d = op_retires;

    assign ex_pc_o    = ex_pc_q;
    assign ex_instr_o = ex_instr_q;
    assign ex_valid_o = ex_valid_q;

    // =================================================================
    // Sequential
    // =================================================================
    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            ex_state_q <= EX_IDLE;
            ex_pc_q    <= '0;
            ex_instr_q <= '0;
            ex_valid_q <= 1'b0;
        end else begin
            ex_state_q <= ex_state_d;
            ex_pc_q    <= ex_pc_d;
            ex_instr_q <= ex_instr_d;
            ex_valid_q <= ex_valid_d;
        end
    end

endmodule

`resetall
