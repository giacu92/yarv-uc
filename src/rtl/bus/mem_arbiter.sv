`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
 * Native mem_req_t / mem_rsp_t arbiter: two masters share one slave
 * (the imem bridge / RAM). Von Neumann — fetch and the LSU (data) reach
 * the same memory through this single port.
 *
 * Master 1 (LSU) has FIXED priority over master 0 (fetch). The bridge is
 * single-outstanding, so a master cannot preempt a transaction the other
 * already owns; arbitration only happens the cycle the slave is free
 * (wready=1), i.e. ready to accept a new launch.
 *
 * Two states drive the mux / routing:
 *
 *   slave_free (slv_rsp_i.wready=1): the bridge is idle this cycle and a
 *     new launch can handshake. Grant by priority — LSU if it asserts
 *     wvalid, else fetch if it asserts wvalid. The granted master's req
 *     goes to the slave and its wready comes back; the other master is
 *     back-pressed (wready=0). Re-arbitrating every free cycle (NOT
 *     letting a previous owner auto-relaunch) is what keeps the LSU from
 *     starving behind fetch's continuous prefetch: fetch.wvalid is
 *     almost always 1, so a "owner relaunches if still wvalid" rule
 *     would hand the bridge back to fetch forever.
 *
 *   ~slave_free (bridge busy): an in-flight transaction is running. The
 *     REGISTERED owner (owner_is_lsu_q) routes the slave response back to
 *     the master that launched it and forwards that master's req (wvalid=0
 *     after launch, rready live for a read) to the slave. The owner was
 *     latched the cycle of the launch, so it is stable across the
 *     multi-cycle round-trip.
 *
 * owner_valid_q is "bridge busy serving owner": set the cycle a launch
 * handshakes on a free cycle, cleared when the slave is free again with no
 * new launch. It never gates a grant (the grant is recomputed every free
 * cycle by priority) — it only routes the response during the busy
 * stretch.
 *
 * No combinational loop: the grant / routing depend on the registered
 * owner and on the masters' req / the slave's rsp (whose wready depends
 * only on the bridge's registered state, never on this arbiter's req).
 *
 * Naming: ports *_i/_o; internals no prefix; flops _q/_d.
 */

module mem_arbiter (
    input wire clk_i,
    input wire rstn_i,

    // Master 0: fetch (lower priority).
    input  mem_req_t fetch_req_i,
    output mem_rsp_t fetch_rsp_o,

    // Master 1: LSU / data (higher priority).
    input  mem_req_t lsu_req_i,
    output mem_rsp_t lsu_rsp_o,

    // Slave: the shared imem bridge.
    output mem_req_t slv_req_o,
    input  mem_rsp_t slv_rsp_i
);

    // -----------------------------------------------------------------
    // Slave-free + priority grant (recomputed every free cycle)
    // -----------------------------------------------------------------
    // The bridge is wready only when idle, so slave_free means a launch
    // can handshake this cycle. Grant LSU first (fixed priority); fetch
    // only if the LSU is not requesting.
    wire  slave_free = slv_rsp_i.wready;
    wire  grant_lsu = slave_free & lsu_req_i.wvalid;
    wire  grant_fetch = slave_free & ~lsu_req_i.wvalid & fetch_req_i.wvalid;
    wire  grant_any = grant_lsu | grant_fetch;

    // -----------------------------------------------------------------
    // Owner tracking: routes the response during the busy stretch.
    // Set the cycle a launch handshakes (slave_free & grant); cleared when
    // the slave is free again with no new launch. Held while busy.
    // -----------------------------------------------------------------
    logic owner_valid_q;  // bridge busy serving an in-flight txn
    logic owner_is_lsu_q;  // 1 = LSU owns, 0 = fetch owns (when valid)

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            owner_valid_q  <= 1'b0;
            owner_is_lsu_q <= 1'b0;
        end else if (slave_free) begin
            // Re-arbitrate by priority: a launch keeps the bridge owned
            // by the granted master; no launch releases it.
            if (grant_lsu) begin
                owner_valid_q  <= 1'b1;
                owner_is_lsu_q <= 1'b1;
            end else if (grant_fetch) begin
                owner_valid_q  <= 1'b1;
                owner_is_lsu_q <= 1'b0;
            end else begin
                owner_valid_q <= 1'b0;
            end
        end
        // else (bridge busy): hold owner_valid_q / owner_is_lsu_q.
    end

    // -----------------------------------------------------------------
    // Request mux: on a free cycle forward the granted master's req (so
    // the launch handshakes); while busy forward the owner's req (wvalid=0
    // after launch, rready live for a read).
    // -----------------------------------------------------------------
    always_comb begin
        if (slave_free) begin
            if (grant_lsu) begin
                slv_req_o = lsu_req_i;
            end else if (grant_fetch) begin
                slv_req_o = fetch_req_i;
            end else begin
                slv_req_o = '{
                    wvalid: 1'b0,
                    we: 1'b0,
                    addr: '0,
                    wdata: '0,
                    wstrb: '0,
                    rready: 1'b0
                };
            end
        end else begin
            slv_req_o = owner_is_lsu_q ? lsu_req_i : fetch_req_i;
        end
    end

    // -----------------------------------------------------------------
    // Response routing: on a free cycle the granted master sees the slave
    // response (its wready to launch); while busy the owner sees it (the
    // in-flight rvalid / bvalid). The other master sees an idle response
    // so it can neither launch nor consume a stray read.
    // -----------------------------------------------------------------
    always_comb begin
        fetch_rsp_o = '{wready: 1'b0, rvalid: 1'b0, rdata: '0, bvalid: 1'b0};
        lsu_rsp_o   = '{wready: 1'b0, rvalid: 1'b0, rdata: '0, bvalid: 1'b0};
        if (slave_free) begin
            if (grant_lsu) begin
                lsu_rsp_o = slv_rsp_i;
            end else if (grant_fetch) begin
                fetch_rsp_o = slv_rsp_i;
            end
        end else if (owner_valid_q) begin
            if (owner_is_lsu_q) begin
                lsu_rsp_o = slv_rsp_i;
            end else begin
                fetch_rsp_o = slv_rsp_i;
            end
        end
    end

endmodule

`resetall
