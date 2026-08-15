// Verilator C++ BFM for the AXI4-Lite RAM compliance test.
//
// Drives ram_tb as an AXI4-Lite master and verifies:
//   - BVALID is registered and held high until BREADY (the key fix): the
//     master deliberately keeps BREADY low for several cycles after
//     BVALID rises; BVALID must not drop.
//   - AW and W may arrive in either order (AW-first and W-first).
//   - Byte-strobed writes are read back correctly.
//   - RVALID is held until RREADY (read back with a delayed rready).
//
// Build: make   (in sim/ram_tb/)
// Run:   make run   (or ./obj_dir/Vram_tb)

#include "Vram_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>

static vluint64_t sim_time = 0;
static Vram_tb* top;

static int fails = 0;
static int checks = 0;

#define CHECK(cond, msg)                               \
    do {                                               \
        ++checks;                                     \
        if (!(cond)) {                                \
            printf("FAIL [%s:%d]: %s\n", __FILE__, __LINE__, msg); \
            ++fails;                                  \
        }                                             \
    } while (0)

// One clock edge: low half, eval; high half, eval. Combinational outputs
// (awready/wready/arready, and the registered bvalid/rvalid reflecting
// pre-edge state) settle on the low eval; the rising edge updates the
// RAM's registers.
static void tick() {
    top->clk_i = 0;
    top->eval();
    sim_time++;
    top->clk_i = 1;
    top->eval();
    sim_time++;
}

// Quiesce all master valids (ready signals left high so the slave is not
// blocked if it has a pending response).
static void idle() {
    top->awvalid = 0;
    top->wvalid = 0;
    top->arvalid = 0;
    top->bready = 1;
    top->rready = 1;
    top->eval();
}

// Drive AW + W (both up). Returns once both have handshaked. bready is
// kept LOW here so B is not consumed (caller controls B acceptance).
static void push_aw_w(uint32_t addr, uint32_t data, uint8_t strb) {
    top->awaddr = addr;
    top->awvalid = 1;
    top->wdata = data;
    top->wstrb = strb;
    top->wvalid = 1;
    top->bready = 0;
    int aw_done = 0, w_done = 0;
    int guard = 0;
    while (!(aw_done && w_done)) {
        top->eval();  // settle readys for this cycle
        if (top->awvalid && top->awready) aw_done = 1;
        if (top->wvalid && top->wready) w_done = 1;
        tick();
        if (aw_done) top->awvalid = 0;
        if (w_done) top->wvalid = 0;
        if (++guard > 20) {
            printf("TIMEOUT in push_aw_w\n");
            ++fails;
            return;
        }
    }
}

// Drive only AW (address first). BREADY low.
static void push_aw(uint32_t addr) {
    top->awaddr = addr;
    top->awvalid = 1;
    top->bready = 0;
    int guard = 0;
    while (1) {
        top->eval();
        if (top->awvalid && top->awready) {
            tick();
            top->awvalid = 0;
            break;
        }
        tick();
        if (++guard > 20) { printf("TIMEOUT push_aw\n"); ++fails; return; }
    }
}

// Drive only W (data first). BREADY low.
static void push_w(uint32_t data, uint8_t strb) {
    top->wdata = data;
    top->wstrb = strb;
    top->wvalid = 1;
    top->bready = 0;
    int guard = 0;
    while (1) {
        top->eval();
        if (top->wvalid && top->wready) {
            tick();
            top->wvalid = 0;
            break;
        }
        tick();
        if (++guard > 20) { printf("TIMEOUT push_w\n"); ++fails; return; }
    }
}

// After AW+W are both seen, BVALID should rise (next cycle) and stay high
// while BREADY is low. This waits for BVALID, holds BREADY low for
// `hold` cycles (asserting BVALID never drops), then accepts B and
// asserts BVALID clears the cycle after the handshake.
static void accept_b_held(int hold) {
    int guard = 0;
    while (!top->bvalid) {
        tick();
        if (++guard > 20) { printf("TIMEOUT waiting for bvalid\n"); ++fails; return; }
    }
    // BVALID is up; keep BREADY low for `hold` cycles -> BVALID must stay.
    for (int i = 0; i < hold; ++i) {
        top->bready = 0;
        top->eval();
        CHECK(top->bvalid, "BVALID dropped while BREADY=0 (must be held)");
        tick();
    }
    // Now accept B.
    top->bready = 1;
    top->eval();
    CHECK(top->bvalid, "BVALID dropped before B handshake");
    tick();  // rising edge with bready=1 && bvalid=1 -> b_hs
    // After the handshake edge, BVALID should be low.
    top->bready = 0;
    top->eval();
    CHECK(!top->bvalid, "BVALID stayed high after B handshake");
}

// Issue a write transaction (AW and W together) and accept B with a
// `b_hold`-cycle delayed BREADY.
static void write_together(uint32_t addr, uint32_t data, uint8_t strb, int b_hold) {
    idle();
    push_aw_w(addr, data, strb);
    accept_b_held(b_hold);
    idle();
}

// Write with AW first, then W.
static void write_aw_first(uint32_t addr, uint32_t data, uint8_t strb, int b_hold) {
    idle();
    push_aw(addr);
    push_w(data, strb);
    accept_b_held(b_hold);
    idle();
}

// Write with W first, then AW.
static void write_w_first(uint32_t addr, uint32_t data, uint8_t strb, int b_hold) {
    idle();
    push_w(data, strb);
    push_aw(addr);
    accept_b_held(b_hold);
    idle();
}

// Read `addr`; returns rdata. Optionally delays RREADY by `r_hold`
// cycles after RVALID rises to verify RVALID is held.
static uint32_t read_from(uint32_t addr, int r_hold) {
    idle();
    top->araddr = addr;
    top->arvalid = 1;
    top->rready = 0;
    int guard = 0;
    while (1) {
        top->eval();
        if (top->arvalid && top->arready) {
            tick();
            top->arvalid = 0;
            break;
        }
        tick();
        if (++guard > 20) { printf("TIMEOUT read AR\n"); ++fails; return 0xDEAD; }
    }
    // Wait for RVALID.
    guard = 0;
    while (!top->rvalid) {
        tick();
        if (++guard > 20) { printf("TIMEOUT waiting rvalid\n"); ++fails; return 0xDEAD; }
    }
    // Hold RREADY low; RVALID must stay.
    for (int i = 0; i < r_hold; ++i) {
        top->rready = 0;
        top->eval();
        CHECK(top->rvalid, "RVALID dropped while RREADY=0 (must be held)");
        tick();
    }
    top->rready = 1;
    top->eval();
    CHECK(top->rvalid, "RVALID dropped before R handshake");
    uint32_t rd = top->rdata;
    tick();  // r_hs edge
    top->rready = 0;
    top->eval();
    CHECK(!top->rvalid, "RVALID stayed high after R handshake");
    idle();
    return rd;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    top = new Vram_tb;

    // Reset (async-active-low here just means hold rstn=0 a few cycles;
    // the RAM uses synchronous reset, so this clears the control flops
    // on the rising edges while rstn=0).
    top->clk_i = 0;
    top->rstn_i = 0;
    idle();
    top->eval();
    for (int i = 0; i < 4; ++i) tick();
    top->rstn_i = 1;
    top->eval();
    tick();

    printf("=== AXI4-Lite RAM compliance test ===\n");

    // --- 1. Write (AW+W together) with delayed BREADY, read back ---
    write_together(0x0000, 0xDEADBEEF, 0xF, /*b_hold=*/3);
    uint32_t r = read_from(0x0000, /*r_hold=*/2);
    CHECK(r == 0xDEADBEEF, "readback after write_together");
    printf("write_together + readback: 0x%08x\n", r);

    // --- 2. AW-first ordering, delayed BREADY, read back ---
    write_aw_first(0x0010, 0x12345678, 0xF, /*b_hold=*/4);
    r = read_from(0x0010, /*r_hold=*/0);
    CHECK(r == 0x12345678, "readback after write_aw_first");
    printf("write_aw_first + readback: 0x%08x\n", r);

    // --- 3. W-first ordering, delayed BREADY, read back ---
    write_w_first(0x0020, 0xAABBCCDD, 0xF, /*b_hold=*/4);
    r = read_from(0x0020, /*r_hold=*/0);
    CHECK(r == 0xAABBCCDD, "readback after write_w_first");
    printf("write_w_first + readback: 0x%08x\n", r);

    // --- 4. Byte strobes: write only the low 2 bytes of a known word ---
    // Pre-fill 0x0030 with 0xFFFFFFFF via a full write.
    write_together(0x0030, 0xFFFFFFFF, 0xF, /*b_hold=*/2);
    // Now overwrite low 2 bytes with 0x0000, strb=0b0011.
    write_together(0x0030, 0x00000000, 0x3, /*b_hold=*/2);
    r = read_from(0x0030, /*r_hold=*/0);
    CHECK(r == 0xFFFF0000, "byte strobe partial write (low 2 bytes)");
    printf("byte-strobe write + readback: 0x%08x (exp 0xFFFF0000)\n", r);

    // --- 5. Byte strobes: high byte only ---
    write_together(0x0040, 0x00000000, 0xF, /*b_hold=*/2);
    // strb bit3 selects byte 3 ([31:24]); data must carry 0xAB in that byte.
    write_together(0x0040, 0xAB000000, 0x8, /*b_hold=*/2);
    r = read_from(0x0040, /*r_hold=*/0);
    CHECK(r == 0xAB000000, "byte strobe partial write (high byte)");
    printf("byte-strobe high-byte + readback: 0x%08x (exp 0xAB000000)\n", r);

    // --- 6. Back-to-back writes to distinct addresses ---
    write_together(0x0050, 0x11111111, 0xF, /*b_hold=*/0);
    write_together(0x0054, 0x22222222, 0xF, /*b_hold=*/0);
    CHECK(read_from(0x0050, 0) == 0x11111111, "back-to-back addr 0x50");
    CHECK(read_from(0x0054, 0) == 0x22222222, "back-to-back addr 0x54");
    printf("back-to-back writes: ok\n");

    // --- 7. Single-outstanding check: while B is pending (bready=0),
    //     AWREADY and WREADY must be low. ---
    idle();
    push_aw_w(0x0060, 0x33333333, 0xF);
    // bvalid should now rise; keep bready low and assert no new AW/W is
    // accepted.
    int guard = 0;
    while (!top->bvalid) { tick(); if (++guard > 20) break; }
    top->awvalid = 1; top->awaddr = 0x0070;
    top->wvalid = 1; top->wdata = 0x44444444; top->wstrb = 0xF;
    top->bready = 0;
    top->eval();
    CHECK(top->awready == 0, "AWREADY high while B pending (single outstanding)");
    CHECK(top->wready == 0, "WREADY high while B pending (single outstanding)");
    tick();
    // accept the pending B and finish the second write
    top->awvalid = 0; top->wvalid = 0;
    top->bready = 1;
    top->eval();
    tick();
    top->bready = 0;
    top->eval();
    CHECK(!top->bvalid, "B cleared after accepting pending response");
    idle();

    printf("\n=== results: %d checks, %d failures ===\n", checks, fails);

    delete top;
    return fails ? 1 : 0;
}