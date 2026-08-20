`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
 * Native mem_req_t / mem_rsp_t RAM slave. Harvard on-die memory for the
 * fetch (read-only I-mem) and LSU (byte-strobed D-mem) ports — no AXI.
 *
 * The native protocol is the one the pipeline stages already use:
 *   - Request launch : req.wvalid && rsp.wready   (rsp.wready = idle)
 *   - Read response  : rsp.rvalid && req.rready   (held until rready)
 * Single-outstanding: while an unread read response is held (rvalid_q=1
 * and the master has not yet asserted rready) wready stays low, so no
 * second request is accepted until the current response is consumed.
 *
 * Timing (mirrors axi4_lite_ram, the protocol-compliant gate):
 *   - Store: commits at the accept cycle (wvalid && wready && we). The
 *     byte-strobed BSRAM write fires that same clock edge. wready stays
 *     high the next cycle (no read pending), so back-to-back stores run
 *     at 1 cyc/store. The LSU's posted store retires on launch-accept
 *     (execute_stage.store_done = mem_launch_hs & we), so bvalid is not
 *     consumed here — mem_rsp_o.bvalid is held low (a native RAM has no
 *     B channel; the LSU does not wait on it).
 *   - Load : on a read accept the BSRAM read launches (registered) and
 *     rvalid is raised the NEXT cycle, then HELD until rready. This is the
 *     "rvalid held under delayed rready" compliance fix proven by ram_tb,
 *     not a one-cycle pulse — a master that is not ready the cycle rvalid
 *     rises does not lose the data. 1-cycle latency when rready is already
 *     high (the LSU holds rready=1 throughout EX_MEM_WAIT).
 *
 * No address latch is needed (unlike axi4_lite_master_bridge): both the
 * read-launch (rdata_q <= mem[word_addr]) and the write-commit happen AT
 * the accept cycle, when req.addr is valid by the launch handshake. The
 * slave never needs addr after accept, so a master that drops its request
 * the cycle after wready (allowed by the native convention, same as the
 * bridge tolerates) cannot corrupt the response.
 *
 * READ_ONLY gates the write path: an I-mem instance (READ_ONLY=1) ignores
 * we/wdata/wstrb and never writes storage. Fetch never asserts we, so the
 * gate is belt-and-braces. The read path is identical for both modes.
 *
 * Storage uses (* ram_style = "block" *) so Gowin infers a simple
 * dual-port BSRAM (one synchronous write port + one synchronous read
 * port, single clock). Byte-strobed writes use the BSRAM byte enables.
 * Storage contents are NOT reset (BSRAM has no clear); only the response
 * registers (rvalid_q) reset. Simulation preloads via INIT_FILE.
 *
 * Naming: ports use *_i/_o; internals no prefix; flops _q.
 */

module native_ram #(
    // Address width in bits (depth = 2^ADDR_W bytes).
    parameter int ADDR_W = 16,
    // Data width in bits (must match XLEN / the mem_req_t width).
    parameter int DATA_WIDTH = 32,
    // 1 = read-only I-mem (fetch); 0 = read/write D-mem (LSU, byte-strobed).
    parameter int READ_ONLY = 0,
    // Optional $readmemh init file (relative to simulation working dir).
    parameter string INIT_FILE = ""
) (
    input wire clk_i,
    input wire rstn_i,

    input  mem_req_t mem_req_i,
    output mem_rsp_t mem_rsp_o
);

    // -----------------------------------------------------------------
    // Local params
    // -----------------------------------------------------------------
    localparam int DATA_W      = DATA_WIDTH;
    localparam int STRB_W      = DATA_W / 8;        // bytes per word
    localparam int BYTES_W     = $clog2(STRB_W);    // byte-select bits
    localparam int WORD_ADDR_W = ADDR_W - BYTES_W;
    localparam int DEPTH_WORDS = 1 << WORD_ADDR_W;

`ifdef VERILATOR
    initial
        assert (STRB_WIDTH == $bits(mem_req_i.wstrb))
        else $fatal(1, "STRB_WIDTH mismatch: package vs mem_req_t.wstrb");
`endif

    // -----------------------------------------------------------------
    // Storage (BSRAM)
    // -----------------------------------------------------------------
    (* ram_style = "block" *)
    logic [DATA_W-1:0] mem[DEPTH_WORDS];

    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
        end
    end

    // -----------------------------------------------------------------
    // Address decode (byte address -> word index). Valid only at the
    // accept cycle (req.wvalid && wready); never sampled after.
    // -----------------------------------------------------------------
    wire  [WORD_ADDR_W-1:0] word_addr = mem_req_i.addr[ADDR_W-1:BYTES_W];

    // -----------------------------------------------------------------
    // Read response register: rvalid held until rready (compliance).
    // rvalid_q is also the single-outstanding busy flag for reads.
    // -----------------------------------------------------------------
    logic                   rvalid_q;
    logic [     DATA_W-1:0] rdata_q;

    // wready: accept a new request when no unread response is held, OR
    // while the master is draining the current one (back-to-back). Depends
    // on the rvalid_q flop and the master's rready only (the master's
    // rready never depends on this wready -> no combinational loop, same
    // property axi4_lite_ram's arready relies on).
    assign mem_rsp_o.wready = !rvalid_q || (rvalid_q && mem_req_i.rready);
    assign mem_rsp_o.rvalid = rvalid_q;
    assign mem_rsp_o.rdata  = rdata_q;
    assign mem_rsp_o.bvalid = 1'b0;  // native RAM: no B channel (LSU posted)

    // Launch handshake: req accepted this cycle.
    wire launch_hs = mem_req_i.wvalid && mem_rsp_o.wready;
    wire launch_read = launch_hs & ~mem_req_i.we;
    wire launch_write = launch_hs & mem_req_i.we;

    // Read response consumed: rvalid held, master ready, no new read
    // landing this same cycle (a new read overwrites rdata_q safely —
    // wready was high only because rready was, so the old response is
    // being drained).
    wire rsp_done = rvalid_q & mem_req_i.rready & ~launch_read;

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            rvalid_q <= 1'b0;
            rdata_q  <= '0;
        end else begin
            if (launch_read) begin
                // Launch the BSRAM read; data registered, rvalid next
                // cycle. Held until rready (rsp_done below clears it).
                rvalid_q <= 1'b1;
                rdata_q  <= mem[word_addr];
            end else if (rsp_done) begin
                rvalid_q <= 1'b0;
            end
        end
    end

    // -----------------------------------------------------------------
    // Write path (D-mem only). Commits at the accept cycle: the
    // byte-strobed BSRAM write fires the same clock edge as launch_hs,
    // so a posted store retires and the data lands together. READ_ONLY
    // gates it off entirely (I-mem never writes).
    // -----------------------------------------------------------------
    generate
        if (!READ_ONLY) begin : gen_write
            always_ff @(posedge clk_i) begin
                if (launch_write) begin
                    for (integer i = 0; i < STRB_W; i++) begin
                        if (mem_req_i.wstrb[i]) begin
                            mem[word_addr][8*i+:8] <= mem_req_i.wdata[8*i+:8];
                        end
                    end
                end
            end
        end
    endgenerate

endmodule

`resetall
