`resetall
`timescale 1ns / 1ps
`default_nettype none

import rv32_pkg::*;

/**
* Machine software-interrupt peripheral (AXI4-Lite slave).
*
* A single 32-bit register at MSIP_PERI_ADDR (peri base 0x1000_0000).
* bit[0] is the MSIP pending bit: a write of bit[0]=1 sets the machine
* software interrupt pending, =0 clears it. Reads return {31'b0, msip}.
* The msip_o output feeds csr_regfile.msip_i (mip.MSIP).
*
* Protocol follows axi4_lite_ram: registered BVALID held until the B
* handshake, RVALID held until RREADY, single-outstanding (AWREADY /
* WREADY / ARREADY low while a response is pending). This is the only
* peri slave on axi_peri, so it accepts any peri address (the LSU only
* targets MSIP_PERI_ADDR for now; other peri addresses would also land
* here and touch the same bit).
*
* Reset is synchronous, active-low. msip_q clears on reset.
*
* Naming: ports *_i/_o; internals no prefix; flops _q, next-state _d.
*/

module msip_peri (
    input wire clk_i,
    input wire rstn_i,

    axi4_lite_if.slave axi,

    output wire msip_o
);

    localparam int DATA_W = axi.DATA_WIDTH;

    // =================================================================
    // Write path (AW + W independent; complete when both seen).
    // =================================================================
    logic aw_seen_q, w_seen_q;
    logic [DATA_W-1:0] wdata_q;
    logic              bvalid_q;

    assign axi.awready = !aw_seen_q && !bvalid_q;
    assign axi.wready  = !w_seen_q && !bvalid_q;

    wire aw_hs = axi.awvalid && axi.awready;
    wire w_hs = axi.wvalid && axi.wready;

    wire aw_present = aw_seen_q || aw_hs;
    wire w_present = w_seen_q || w_hs;
    wire do_write = aw_present && w_present && !bvalid_q;

    wire [DATA_W-1:0] wdata_eff = w_hs ? axi.wdata : wdata_q;

    assign axi.bvalid = bvalid_q;
    assign axi.bresp  = 2'b00;  // OKAY
    wire  b_hs = axi.bvalid && axi.bready;

    // msip pending bit.
    logic msip_q;

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            aw_seen_q <= 1'b0;
            w_seen_q  <= 1'b0;
            wdata_q   <= '0;
            bvalid_q  <= 1'b0;
            msip_q    <= 1'b0;
        end else begin
            if (aw_hs) begin
                aw_seen_q <= 1'b1;
            end
            if (w_hs) begin
                w_seen_q <= 1'b1;
                wdata_q  <= axi.wdata;
            end

            // Both phases present: latch bit[0] and raise BVALID.
            if (do_write) begin
                aw_seen_q <= 1'b0;
                w_seen_q  <= 1'b0;
                bvalid_q  <= 1'b1;
                msip_q    <= wdata_eff[0];
            end

            if (b_hs) begin
                bvalid_q <= 1'b0;
            end
        end
    end

    // =================================================================
    // Read path (1-cycle registered latency).
    // =================================================================
    logic              rvalid_q;
    logic [DATA_W-1:0] rdata_q;

    assign axi.arready = !rvalid_q || (rvalid_q && axi.rready);
    wire ar_hs = axi.arvalid && axi.arready;

    assign axi.rvalid = rvalid_q;
    assign axi.rdata  = rdata_q;
    assign axi.rresp  = 2'b00;  // OKAY

    always_ff @(posedge clk_i) begin
        if (!rstn_i) begin
            rvalid_q <= 1'b0;
            rdata_q  <= '0;
        end else begin
            if (ar_hs) begin
                rvalid_q <= 1'b1;
                rdata_q  <= {{(DATA_W - 1) {1'b0}}, msip_q};
            end else if (rvalid_q && axi.rready) begin
                rvalid_q <= 1'b0;
            end
        end
    end

    assign msip_o = msip_q;

endmodule

`resetall
