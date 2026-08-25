// Verilator C++ BFM for the axi4_lite_uart FIFO + IRQ compliance test.
//
// The bug this test was written for: with a single-byte RX buffer, a
// terminal that ships a typed line in one burst loses every byte that
// arrives while software is busy echoing the previous one (echo is a whole
// frame time). YarvMon on hardware looked like it ignored all input. So
// the checks here are about the FIFOs, not just the AXI handshake:
//
//   - TX FIFO: N writes with no polling in between ship N frames, in
//     order, back-to-back.
//   - TX_READY drops when the TX FIFO is full, and a write to a full FIFO
//     is held until room appears rather than dropped: it takes far longer
//     than an ordinary write and the byte still ships, in order.
//   - RX FIFO: N frames arriving back-to-back with no software read are
//     all retained, in order, with RX_OVERRUN clear.
//   - RX overrun: the frame that arrives with the FIFO full is dropped and
//     latches RX_OVERRUN; the bytes already queued are untouched.
//   - Reading RXDATA on an empty FIFO pops nothing (no pointer underflow).
//   - IRQ is level-sensitive and gated by CTRL: no interrupt until the
//     enable is written, asserted while the condition holds, deasserted
//     when software drains it.
//
// Build: make   (in sim/hw/uart_tb/)
// Run:   make run   (or ./obj_dir/Vuart_tb)

#include "Vuart_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <vector>

// Register offsets (byte addresses within the peripheral window).
static const uint32_t REG_TXDATA  = 0x00;
static const uint32_t REG_RXDATA  = 0x04;
static const uint32_t REG_STATUS  = 0x08;
static const uint32_t REG_CTRL    = 0x0C;

static const uint32_t ST_TX_READY   = 0x1;
static const uint32_t ST_RX_READY    = 0x2;
static const uint32_t ST_RX_OVERRUN  = 0x4;

static const uint32_t CTRL_TX_IE = 0x1;
static const uint32_t CTRL_RX_IE = 0x2;

// Must match uart_tb.sv's CLK_FREQ_HZ / BAUD_RATE.
static const int BIT_CYCLES = 10;
// The UART's own FIFO depths (uart_tb.sv defaults).
static const int FIFO_DEPTH = 16;

static Vuart_tb* top;
static int fails = 0;
static int checks = 0;

#define CHECK(cond, msg)                                               \
    do {                                                               \
        ++checks;                                                      \
        if (!(cond)) {                                                 \
            printf("FAIL [%s:%d]: %s\n", __FILE__, __LINE__, msg);     \
            ++fails;                                                   \
        }                                                              \
    } while (0)

#define CHECK_EQ(got, want, msg)                                       \
    do {                                                               \
        ++checks;                                                      \
        if ((uint32_t)(got) != (uint32_t)(want)) {                      \
            printf("FAIL [%s:%d]: %s (got 0x%x, want 0x%x)\n",          \
                   __FILE__, __LINE__, msg, (unsigned)(got),            \
                   (unsigned)(want));                                   \
            ++fails;                                                    \
        }                                                               \
    } while (0)

// ---------------------------------------------------------------------
// Continuous TX line monitor.
//
// It runs on every clock edge (from tick()), not on demand: by the time a
// test has finished issuing its AXI writes the engine is already several
// bits into the first frame, so a decoder that starts looking only when
// asked would latch onto the middle of a byte. Bits are sampled at
// mid-bit, which tolerates the +/-1 cycle of start-edge detection error.
// ---------------------------------------------------------------------
static std::vector<int> tx_bytes;  // every byte seen on txd_o, in order

static int mon_state = 0;  // 0 = armed, 1 = sampling, 2 = awaiting idle line
static int mon_cnt = 0, mon_bit = 0, mon_byte = 0, mon_target = 0;

static void tx_monitor() {
    if (mon_state == 0) {
        if (!top->txd_o) {  // start bit
            mon_state  = 1;
            mon_cnt    = 0;
            mon_bit    = 0;
            mon_byte   = 0;
            mon_target = BIT_CYCLES + BIT_CYCLES / 2;  // middle of bit 0
        }
    } else if (mon_state == 1) {
        ++mon_cnt;
        if (mon_cnt == mon_target) {
            if (top->txd_o) mon_byte |= 1 << mon_bit;
            ++mon_bit;
            mon_target += BIT_CYCLES;
            if (mon_bit == 8) {
                tx_bytes.push_back(mon_byte);
                mon_state = 2;
            }
        }
    } else {  // 2: re-arm only once the line is high again (stop bit)
        if (top->txd_o) mon_state = 0;
    }
}

static void tick() {
    top->clk_i = 0;
    top->eval();
    top->clk_i = 1;
    top->eval();
    tx_monitor();
}

static void idle() {
    top->awvalid = 0;
    top->wvalid  = 0;
    top->arvalid = 0;
    top->bready  = 1;
    top->rready  = 1;
    top->eval();
}

// Single-beat AXI4-Lite write, AW and W together, B consumed.
// Returns the number of cycles the transaction took, so a test can tell a
// write that completed immediately from one the peripheral held.
static int axi_write_timed(uint32_t addr, uint32_t data, int guard_cycles) {
    top->awaddr  = addr;
    top->awvalid = 1;
    top->wdata   = data;
    top->wstrb   = 0xF;
    top->wvalid  = 1;
    top->bready  = 1;
    bool aw = false, w = false, b = false;
    int cycles = 0;
    for (int guard = 0; guard < guard_cycles && !(aw && w && b); ++guard) {
        top->eval();
        if (top->awvalid && top->awready) aw = true;
        if (top->wvalid && top->wready) w = true;
        if (top->bvalid && top->bready) b = true;
        tick();
        ++cycles;
        if (aw) top->awvalid = 0;
        if (w) top->wvalid = 0;
    }
    CHECK(aw && w && b, "axi_write did not complete");
    idle();
    return cycles;
}

static void axi_write(uint32_t addr, uint32_t data) {
    axi_write_timed(addr, data, 32);
}

// Single-beat AXI4-Lite read.
static uint32_t axi_read(uint32_t addr) {
    top->araddr  = addr;
    top->arvalid = 1;
    top->rready  = 1;
    uint32_t val = 0;
    bool ar = false, r = false;
    for (int guard = 0; guard < 32 && !(ar && r); ++guard) {
        top->eval();
        if (top->arvalid && top->arready) ar = true;
        if (top->rvalid && top->rready) {
            val = top->rdata;
            r   = true;
        }
        tick();
        if (ar) top->arvalid = 0;
    }
    CHECK(ar && r, "axi_read did not complete");
    idle();
    return val;
}

// Drive one 8N1 frame into rxd_i. No inter-frame gap: called back-to-back
// this is exactly the burst a line-buffered terminal produces.
static void rx_frame(uint8_t byte) {
    auto drive = [](int level, int cycles) {
        top->rxd_i = level;
        for (int i = 0; i < cycles; ++i) tick();
    };
    drive(0, BIT_CYCLES);  // start
    for (int b = 0; b < 8; ++b) drive((byte >> b) & 1, BIT_CYCLES);
    drive(1, BIT_CYCLES);  // stop
}

// Next byte the monitor has decoded off txd_o, waiting for it if the frame
// is still in flight. Returns -1 on timeout.
static size_t tx_taken = 0;

static int tx_frame(int timeout = 4000) {
    for (int waited = 0; tx_bytes.size() <= tx_taken; ++waited) {
        if (waited > timeout) return -1;
        tick();
    }
    return tx_bytes[tx_taken++];
}

// Bytes decoded but not yet consumed by a check.
static size_t tx_backlog() { return tx_bytes.size() - tx_taken; }

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    top = new Vuart_tb;

    top->clk_i  = 0;
    top->rstn_i = 0;
    top->rxd_i  = 1;  // idle line high
    idle();
    for (int i = 0; i < 4; ++i) tick();
    top->rstn_i = 1;
    tick();

    printf("=== axi4_lite_uart FIFO + IRQ compliance ===\n");

    // ---- 1. Reset state ------------------------------------------------
    uint32_t st = axi_read(REG_STATUS);
    CHECK_EQ(st & ST_TX_READY, ST_TX_READY, "TX_READY set out of reset");
    CHECK_EQ(st & ST_RX_READY, 0, "RX_READY clear out of reset");
    CHECK_EQ(st & ST_RX_OVERRUN, 0, "RX_OVERRUN clear out of reset");
    CHECK_EQ(top->uart_irq_o, 0, "IRQ masked out of reset (both IEs are 0)");

    // ---- 2. TX FIFO: queue 4 bytes with no polling ---------------------
    // Pre-FIFO this dropped 3 of the 4: the shift buffer was busy.
    const uint8_t tx_seq[4] = {0x41, 0x42, 0x43, 0x0D};
    for (uint8_t b : tx_seq) axi_write(REG_TXDATA, b);
    for (int i = 0; i < 4; ++i) {
        int got = tx_frame();
        CHECK_EQ(got, tx_seq[i], "queued TX byte shipped in order");
    }

    // ---- 3. TX_READY / drop on a full TX FIFO --------------------------
    // Push until the peripheral itself says it is full, rather than
    // assuming a byte count: a frame takes 100 cycles while a write takes
    // a handful, so the engine pops one or two bytes while we fill, and
    // the exact number that fits is a timing detail, not a contract.
    std::vector<int> queued;
    for (int i = 0; i < 4 * FIFO_DEPTH; ++i) {
        if (!(axi_read(REG_STATUS) & ST_TX_READY)) break;
        int byte = 0x30 + (int)queued.size();
        axi_write(REG_TXDATA, byte);
        queued.push_back(byte);
    }
    st = axi_read(REG_STATUS);
    CHECK_EQ(st & ST_TX_READY, 0, "TX_READY clear once the TX FIFO is full");
    CHECK(queued.size() >= (size_t)FIFO_DEPTH, "at least DEPTH bytes accepted");
    // A write to a full FIFO is held, not dropped: it completes only after
    // the engine ships a byte and frees a slot, so it takes far longer than
    // an ordinary write (a handful of cycles) and the byte survives.
    int held = axi_write_timed(REG_TXDATA, 0xFF, 40 * BIT_CYCLES);
    CHECK(held > 8, "write to a full TX FIFO is held until room appears");
    queued.push_back(0xFF);
    // Drain: every byte ships, in order, including the held one.
    for (size_t i = 0; i < queued.size(); ++i) {
        int got = tx_frame();
        CHECK_EQ(got, queued[i], "TX FIFO drains in order, held byte included");
    }
    st = axi_read(REG_STATUS);
    CHECK_EQ(st & ST_TX_READY, ST_TX_READY, "TX_READY back after the drain");
    for (int i = 0; i < 2 * BIT_CYCLES; ++i) tick();  // room for a stray frame
    CHECK_EQ(tx_backlog(), 0, "no extra frame beyond the queued bytes");

    // ---- 4. RX FIFO: burst with no reads -------------------------------
    // The regression case: 8 frames back-to-back, software asleep.
    const int burst = 8;
    for (int i = 0; i < burst; ++i) rx_frame(0x61 + i);
    st = axi_read(REG_STATUS);
    CHECK_EQ(st & ST_RX_READY, ST_RX_READY, "RX_READY set after the burst");
    CHECK_EQ(st & ST_RX_OVERRUN, 0, "no overrun for a burst inside the depth");
    for (int i = 0; i < burst; ++i) {
        uint32_t got = axi_read(REG_RXDATA);
        CHECK_EQ(got & 0xFF, 0x61 + i, "RX burst byte retained in order");
    }
    st = axi_read(REG_STATUS);
    CHECK_EQ(st & ST_RX_READY, 0, "RX_READY clear once the FIFO is drained");

    // ---- 5. Reading an empty RX FIFO pops nothing ----------------------
    uint32_t stale = axi_read(REG_RXDATA);
    (void)stale;  // value is undefined by contract; the pointers matter
    st = axi_read(REG_STATUS);
    CHECK_EQ(st & ST_RX_READY, 0, "empty read leaves RX_READY clear");
    rx_frame(0x5A);
    CHECK_EQ(axi_read(REG_RXDATA) & 0xFF, 0x5A,
             "FIFO still coherent after an empty read (no underflow)");

    // ---- 6. RX overrun -------------------------------------------------
    // One frame more than the depth: the extra byte is dropped and flagged,
    // the queued ones survive.
    for (int i = 0; i < FIFO_DEPTH + 1; ++i) rx_frame(0x10 + i);
    st = axi_read(REG_STATUS);
    CHECK_EQ(st & ST_RX_OVERRUN, ST_RX_OVERRUN, "RX_OVERRUN latched on drop");
    for (int i = 0; i < FIFO_DEPTH; ++i) {
        uint32_t got = axi_read(REG_RXDATA);
        CHECK_EQ(got & 0xFF, 0x10 + i, "queued bytes survive the overrun");
    }
    st = axi_read(REG_STATUS);
    CHECK_EQ(st & ST_RX_READY, 0, "FIFO empty after draining the overrun case");
    CHECK_EQ(st & ST_RX_OVERRUN, 0, "RX_OVERRUN cleared by an RXDATA read");

    // ---- 7. IRQ: level-sensitive, gated by CTRL ------------------------
    rx_frame(0x77);
    CHECK_EQ(top->uart_irq_o, 0, "RX byte pending but RX_IE=0: no IRQ");
    axi_write(REG_CTRL, CTRL_RX_IE);
    top->eval();
    CHECK_EQ(top->uart_irq_o, 1, "IRQ asserts once RX_IE is written");
    (void)axi_read(REG_RXDATA);
    top->eval();
    CHECK_EQ(top->uart_irq_o, 0, "IRQ deasserts when software drains RX");

    // TX_IE fires on "FIFO not full", i.e. immediately with an idle engine.
    axi_write(REG_CTRL, CTRL_TX_IE);
    top->eval();
    CHECK_EQ(top->uart_irq_o, 1, "TX_IE asserts while the TX FIFO has room");
    axi_write(REG_CTRL, 0);
    top->eval();
    CHECK_EQ(top->uart_irq_o, 0, "IRQ masked again with both IEs clear");

    printf("%d checks, %d failures\n", checks, fails);
    delete top;
    return fails ? 1 : 0;
}
