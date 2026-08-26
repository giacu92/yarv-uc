// Verilator C++ BFM for the 64-bit / 2-outstanding / read-only native_ram
// compliance test — the configuration the widened I-mem fetch port uses.
// Drives native_ram64_tb and verifies:
//   - Two back-to-back reads are BOTH accepted (OUTSTANDING=2): the second
//     read launches the cycle the first one's data lands, without draining.
//   - A third read is NOT accepted while two responses are held (skid full):
//     wready stays low until one is drained.
//   - RVALID is registered and held until RREADY (the master keeps RREADY low
//     for several cycles after RVALID rises; RVALID must not drop).
//   - 64-bit read data: each access returns the full 8-byte word (low 32 bits
//     = word at the byte address, high 32 bits = +4), preloaded with
//     distinct low/high halves so a width or lane-swap bug reads back wrong.
//
// Build: make   (in sim/hw/native_ram64_tb/)
// Run:   make run   (or ./obj_dir/Vnative_ram64_tb)

#include "Vnative_ram64_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>

static vluint64_t sim_time = 0;
static Vnative_ram64_tb* top;

static int fails = 0;
static int checks = 0;

#define CHECK(cond, msg)                               \
    do {                                               \
        ++checks;                                      \
        if (!(cond)) {                                \
            printf("FAIL [%s:%d]: %s\n", __FILE__, __LINE__, msg); \
            ++fails;                                  \
        }                                             \
    } while (0)

// One clock edge: low half, eval; high half, eval.
static void tick() {
    top->clk_i = 0;
    top->eval();
    sim_time++;
    top->clk_i = 1;
    top->eval();
    sim_time++;
}

static void idle() {
    top->i_valid = 0;
    top->i_addr = 0;
    top->i_rready = 0;
    top->eval();
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    top = new Vnative_ram64_tb;

    const uint64_t W0 = 0xDEADBEEFCAFEBABEULL;
    const uint64_t W1 = 0x0BADF00D12345678ULL;
    const uint64_t W2 = 0xAAAABBBBCCCCDDDDULL;

    // Reset (synchronous): hold rstn=0 a few cycles, then release.
    top->clk_i = 0;
    top->rstn_i = 0;
    idle();
    top->eval();
    for (int i = 0; i < 4; ++i) tick();
    top->rstn_i = 1;
    top->eval();
    tick();

    printf("=== native_ram 64-bit / 2-outstanding / RO compliance test ===\n");

    // --- 1. Launch read A (addr 0). Skid empty -> accepted at once. ---
    top->i_valid = 1;
    top->i_addr = 0x0000;
    top->i_rready = 0;
    top->eval();
    CHECK(top->i_ready == 1, "read A accepted (skid empty)");
    tick();  // rising edge: A in flight (rif<=1, rd_d_q<=mem[0])
    idle();

    // --- 2. Launch read B (addr 8) the cycle A's data lands. With
    //     OUTSTANDING=2 the skid still has room -> B accepted, A stored. ---
    top->i_valid = 1;
    top->i_addr = 0x0008;
    top->i_rready = 0;
    top->eval();
    CHECK(top->i_ready == 1, "read B accepted while read A in flight (2-outstanding)");
    CHECK(top->i_rvalid == 1, "RVALID up when read A data lands");
    CHECK(top->i_rdata == W0, "read A data at head when B launches");
    tick();  // B in flight, A -> skid[0], count=1
    idle();

    // --- 3. Try read C (addr 16). B's data lands this cycle (rif=1) and A
    //     is still queued (count=1) -> new_count=2 -> wready=0: C is blocked
    //     until one response is drained. ---
    top->i_valid = 1;
    top->i_addr = 0x0010;
    top->i_rready = 0;
    top->eval();
    CHECK(top->i_ready == 0, "read C blocked while two responses held (skid full)");
    CHECK(top->i_rvalid == 1, "RVALID held while C blocked");
    CHECK(top->i_rdata == W0, "read A still at head while C blocked");
    tick();  // C NOT launched (wready=0). B -> skid[1], count=2, rif=0.
    idle();

    // --- 4. RVALID held under delayed RREADY (the compliance point): keep
    //     RREADY low for several cycles; RVALID must not drop, head must not
    //     change. ---
    for (int i = 0; i < 4; ++i) {
        top->i_rready = 0;
        top->eval();
        CHECK(top->i_rvalid == 1, "RVALID dropped while RREADY=0 (must be held)");
        CHECK(top->i_rdata == W0, "head data changed while RREADY=0");
        tick();
        top->eval();
    }

    // --- 5. Drain A. After the pop, count=1 (B at head) and C can launch. ---
    top->i_rready = 1;
    top->eval();
    CHECK(top->i_rvalid == 1, "RVALID dropped before R handshake (drain A)");
    CHECK(top->i_rdata == W0, "drain read A data");
    tick();  // A popped, skid[0]<=B, count=1
    top->i_rready = 0;
    top->eval();

    // --- 6. Launch read C now that one slot is free. ---
    top->i_valid = 1;
    top->i_addr = 0x0010;
    top->i_rready = 0;
    top->eval();
    CHECK(top->i_ready == 1, "read C accepted after one response drained");
    tick();  // C in flight
    idle();

    // --- 7. Drain B. C's data lands as B is popped -> C becomes the head. ---
    top->i_rready = 1;
    top->eval();
    CHECK(top->i_rvalid == 1, "RVALID dropped before R handshake (drain B)");
    CHECK(top->i_rdata == W1, "drain read B data");
    tick();  // B popped, C -> skid[0], count=1
    top->i_rready = 0;
    top->eval();

    // --- 8. Drain C. ---
    top->i_rready = 1;
    top->eval();
    CHECK(top->i_rvalid == 1, "RVALID dropped before R handshake (drain C)");
    CHECK(top->i_rdata == W2, "drain read C data");
    tick();  // C popped, count=0
    top->i_rready = 0;
    top->eval();
    CHECK(top->i_rvalid == 0, "RVALID stayed high after all responses drained");

    printf("\n=== results: %d checks, %d failures ===\n", checks, fails);

    delete top;
    return fails ? 1 : 0;
}