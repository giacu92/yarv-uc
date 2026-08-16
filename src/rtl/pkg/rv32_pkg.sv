package rv32_pkg;

    localparam int unsigned XLEN       = 32;
    localparam int unsigned STRB_WIDTH = XLEN / 8;
    localparam int unsigned AXI4_LEN   = 32;

    typedef logic [STRB_WIDTH-1:0] strb_t;

    // ---------------------------------------------------------------
    // Native memory interface — split per DIREZIONE (stile AXI):
    // ogni bundle e' una sola direzione, cosi' e' legale come packed
    // struct passata come singola porta. I canali (request / read
    // response) sono mischiati dentro ciascun bundle.
    //
    // Handshake richiesta (launch): req.wvalid && rsp.wready.
    // Handshake read response:       rsp.rvalid && req.rready.
    // ---------------------------------------------------------------

    // master -> bridge  (tutti gli OUTPUT del master)
    typedef struct packed {
        logic                  wvalid;  // request valid (launch)
        logic                  we;      // 1 = write, 0 = read
        logic [XLEN-1:0]       addr;    // byte address
        logic [XLEN-1:0]       wdata;   // write data (ignored if we=0)
        logic [STRB_WIDTH-1:0] wstrb;   // byte strobes; all-1 on a word store
        logic                  rready;  // master ready to accept read data
    } mem_req_t;

    // bridge -> master  (tutti gli INPUT del master)
    typedef struct packed {
        logic            wready;  // bridge accepts the request (= idle)
        logic            rvalid;  // read data valid this cycle
        logic [XLEN-1:0] rdata;   // read data
        // TODO(LSU): add bvalid (write-ack, bridge->master). The fetch
        // is read-only so it is not needed yet; the peri bridge is tied
        // off and no write is ever launched today.
    } mem_rsp_t;

    // ---------------------------------------------------------------
    // Convenience: request-launch predicate (req.wvalid && rsp.wready).
    // ---------------------------------------------------------------
    function automatic logic req_handshake(input mem_req_t req, input mem_rsp_t rsp);
        return req.wvalid && rsp.wready;
    endfunction

    // ---------------------------------------------------------------
    // Decode: opcodes, ALU/branch/source enums, and the D/E control
    // struct. Phase 1 decodes RV32I + M + C; the A (LSU), Zicsr (CSR
    // file) and Zifencei (fence) opcodes are present here so the
    // decoder can flag them illegal, but they are not executed yet.
    // ---------------------------------------------------------------

    // Major opcodes (instr[6:0]).
    localparam logic [6:0] OPC_LUI      = 7'b0110111;
    localparam logic [6:0] OPC_AUIPC    = 7'b0010111;
    localparam logic [6:0] OPC_JAL      = 7'b1101111;
    localparam logic [6:0] OPC_JALR     = 7'b1100111;
    localparam logic [6:0] OPC_BRANCH   = 7'b1100011;
    localparam logic [6:0] OPC_LOAD     = 7'b0000011;
    localparam logic [6:0] OPC_STORE    = 7'b0100011;
    localparam logic [6:0] OPC_OP_IMM   = 7'b0010011;
    localparam logic [6:0] OPC_OP       = 7'b0110011;  // M is OPC_OP with funct7=0000001
    localparam logic [6:0] OPC_MISC_MEM = 7'b0001111;  // fence / fence.i (Zifencei) -> illegal
    localparam logic [6:0] OPC_SYSTEM   = 7'b1110011;  // CSR / ecall / ebreak (Zicsr) -> illegal
    localparam logic [6:0] OPC_AMO      = 7'b0101111;  // A extension (Zam) -> illegal

    // ALU operation (base RV32I + M extension + Zilx EA). 19 values -> 5 bits.
    typedef enum logic [4:0] {
        // -------- Base ALU operations --------
        ALU_ADD,
        ALU_SUB,
        ALU_SLL,
        ALU_SLT,
        ALU_SLTU,
        ALU_XOR,
        ALU_SRL,
        ALU_SRA,
        ALU_OR,
        ALU_AND,

        // -------- M extension (funct7 == 0000001) --------
        ALU_MUL,
        ALU_MULH,
        ALU_MULHSU,
        ALU_MULHU,
        ALU_DIV,
        ALU_DIVU,
        ALU_REM,
        ALU_REMU,

        // -------- Zilx indexed-load EA (RV32) --------
        // EA = base + (index << shamt). operand_a = rs2_data (base),
        // operand_b = rs1_data (index); shamt comes from de_t.mem_shamt
        // (0 unscaled, log2(access_size) scaled). The load itself is the
        // LSU's job (mem_read / WB_MEM); ALU_LX computes the address only.
        ALU_LX
    } alu_op_t;

    // Branch / jump type (JAL/JALR encoded here too — no separate flags).
    typedef enum logic [3:0] {
        BR_NONE,
        BR_BEQ,
        BR_BNE,
        BR_BLT,
        BR_BGE,
        BR_BLTU,
        BR_BGEU,
        BR_JAL,
        BR_JALR
    } branch_t;

    // ALU operand-A source.
    typedef enum logic [1:0] {
        ALU_A_RS1,
        ALU_A_PC,
        ALU_A_RS2   // Zilx base (spec: rs2 = base, rs1 = index)
    } alu_src_a_t;
    // ALU operand-B source.
    typedef enum logic [2:0] {
        ALU_B_IMM,
        ALU_B_RS2,
        ALU_B_PC4,
        ALU_B_ZERO,
        ALU_B_RS1_SH  // Zilx index (rs1), shifted by de_t.mem_shamt inside the ALU
    } alu_src_b_t;
    // Write-back source.
    typedef enum logic [1:0] {
        WB_ALU,
        WB_MEM,
        WB_PC4
    } wb_src_t;
    // Memory access size.
    typedef enum logic [1:0] {
        MS_B,
        MS_H,
        MS_W
    } mem_size_t;

    // D/E pipeline register: everything decode produces for a (future)
    // execute stage. Single-direction packed struct, legal as one port
    // (matches the mem_req_t / mem_rsp_t convention).
    typedef struct packed {
        logic            valid;          // a decoded instr is held this cycle
        logic [XLEN-1:0] pc;             // instr PC (P for low/32-bit, P+2 for upper half)
        logic [XLEN-1:0] instr;          // 32-bit word decode treated (native or RVC-expanded)
        logic            is_compressed;  // source was a 16-bit RVC instr
        logic [4:0]      rs1_addr;
        logic [4:0]      rs2_addr;
        logic [XLEN-1:0] rs1_data;       // operand captured at decode (async read)
        logic [XLEN-1:0] rs2_data;
        logic [XLEN-1:0] imm;            // sign-extended I/S/B/U/J immediate
        logic [4:0]      rd;
        logic            reg_write;      // write back to rd
        alu_op_t         alu_op;
        alu_src_a_t      alu_src_a;
        alu_src_b_t      alu_src_b;
        logic            mem_read;
        logic            mem_write;
        mem_size_t       mem_size;
        logic            mem_unsigned;   // load zero-extend (LBU/LHU)
        logic [1:0]      mem_shamt;      // Zilx index scale (0 unscaled, log2 size scaled)
        wb_src_t         wb_src;
        branch_t         branch_type;
        logic            illegal;        // opcode/encoding not decoded this phase
    } de_t;

endpackage
