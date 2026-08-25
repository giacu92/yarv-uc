#include <stdint.h>
#include "../sw/uart.h"

/*
 * UART echo + external-interrupt (MEIP) oracle.
 *
 * Two phases, so a failure says *where* the RX path broke:
 *
 *   Phase 1 (polling)  : echo PHASE_CHARS bytes read with uart_getc().
 *   Phase 2 (interrupt): enable CTRL.RX_IE + mie.MEIE + mstatus.MIE, then
 *                        sleep in wfi. The handler drains the RX FIFO,
 *                        echoes each byte and counts it. This is the only
 *                        test in the tree that exercises MEIP end to end:
 *                        uart_irq_o -> meip_i -> mip.MEIP -> trap_unit ->
 *                        interrupt entry, plus the wfi wake on an external
 *                        interrupt.
 *
 * Result marker: 0x600D (pass) / 0xBAD (fail) written to D-mem 0x3000.
 * 0x3000 rather than 0x2000 because .rodata is linked at 0x2000 -- writing
 * there would clobber the strings this program prints.
 *
 * Echo also makes it a hardware bring-up aid: type 8 characters on the
 * board and the first PHASE_CHARS come back by polling, the rest by
 * interrupt. Silence in phase 1 means bytes never reach the CPU (pin,
 * baud, sampling); silence only in phase 2 means the interrupt path is
 * broken while the data path works.
 */

#define UART_CTRL (*(volatile unsigned int *)(UART_BASE + 0x0C))
#define CTRL_RX_IE 0x2u

#define MSTATUS_MIE (1u << 3)
#define MIE_MEIE    (1u << 11)
#define MIP_MEIP    (1u << 11)
#define MCAUSE_MEI  0x8000000Bu
#define MCAUSE_ECALL_M 11u

#define PHASE_CHARS 4

/* .bss is not zeroed by start.S, so anything needing a known initial
 * value lives in .data (an explicit initialiser puts it there). */
static volatile uint32_t irq_chars = 0;  /* bytes echoed by the handler */
static volatile uint32_t sync_traps = 0; /* ecall traps taken */
static volatile uint32_t bad_cause = 0;  /* unexpected mcause, if any */

static volatile uint32_t *const result = (volatile uint32_t *)0x3000;

static inline uint32_t read_mcause(void)
{
    uint32_t v;
    __asm__ volatile("csrr %0, mcause" : "=r"(v));
    return v;
}

static inline uint32_t read_mip(void)
{
    uint32_t v;
    __asm__ volatile("csrr %0, mip" : "=r"(v));
    return v;
}

static inline uint32_t read_mie(void)
{
    uint32_t v;
    __asm__ volatile("csrr %0, mie" : "=r"(v));
    return v;
}

static inline uint32_t read_mstatus(void)
{
    uint32_t v;
    __asm__ volatile("csrr %0, mstatus" : "=r"(v));
    return v;
}

/* GCC's machine-interrupt attribute emits the register save/restore and
 * the mret for us; mtvec is programmed to this address in direct mode.
 *
 * aligned(4) is not cosmetic: mtvec holds BASE in bits [31:2] and MODE in
 * [1:0], so a write masks the low two bits away. With RVC enabled a
 * function can land on a 2-byte boundary, and mtvec would then point two
 * bytes BELOW the handler -- into the middle of the preceding
 * instruction. The core would vector into garbage on the first interrupt,
 * with no output and no way to tell it from a dead interrupt path. */
__attribute__((interrupt("machine"), aligned(4))) void trap_handler(void)
{
    uint32_t cause = read_mcause();

    if (cause == MCAUSE_ECALL_M) {
        /* Sync-trap probe (see main). mret returns to mepc, which points
         * AT the ecall, so step over it or we would trap forever. ecall is
         * always the 4-byte encoding. */
        uint32_t epc;
        __asm__ volatile("csrr %0, mepc" : "=r"(epc));
        __asm__ volatile("csrw mepc, %0" ::"r"(epc + 4));
        sync_traps = sync_traps + 1;
        return;
    }

    if (cause != MCAUSE_MEI) {
        /* Not the external interrupt: record it and mask everything so we
         * cannot spin in a trap storm. */
        bad_cause = cause;
        __asm__ volatile("csrci mstatus, %0" ::"i"(MSTATUS_MIE));
        return;
    }

    /* Drain the RX FIFO. The IRQ is level-sensitive: leaving a byte queued
     * would re-enter the handler immediately (correct, but pointless). */
    while (UART_STATUS & UART_RX_READY_BIT) {
        char c = (char)(UART_RXDATA & 0xFF);
        uart_putc(c);
        irq_chars = irq_chars + 1;
    }
}

int main(void)
{
    uart_puts("\r\nECHO\r\n");

    /* ---- Phase 1: polling ---- */
    for (int i = 0; i < PHASE_CHARS; ++i) uart_putc(uart_getc());
    uart_puts("\r\nIRQ\r\n");

    /* ---- Phase 2: interrupt-driven ----
     *
     * Split into three observable steps, so a board that stops here says
     * WHICH link of the chain is broken instead of just going quiet:
     *
     *   2a: enable CTRL.RX_IE and mie.MEIE but leave mstatus.MIE clear,
     *       then poll mip. This walks uart_irq_o -> meip_i -> mip.MEIP
     *       with traps still globally disabled, so nothing about trap
     *       entry can be blamed. Prints the mip value it saw.
     *   2b: enable mstatus.MIE with that byte still sitting unread in the
     *       RX FIFO. The IRQ is level-sensitive, so the interrupt must be
     *       taken immediately -- no wfi involved. This isolates trap entry
     *       and the handler from the wfi wake.
     *   2c: sleep in wfi for the remaining bytes, which is the wfi-wake
     *       path.
     */
    UART_CTRL = CTRL_RX_IE;
    __asm__ volatile("csrw mtvec, %0" ::"r"((uint32_t)&trap_handler));
    __asm__ volatile("csrs mie, %0" ::"r"(MIE_MEIE));

    /* 2a -- send one byte now; it stays queued (nothing reads RXDATA). */
    while (!(read_mip() & MIP_MEIP)) { /* spin */ }
    uart_puts("MIP ");
    uart_put_hex32(read_mip());
    uart_puts(" MIE ");
    uart_put_hex32(read_mie());
    uart_puts(" MST ");
    uart_put_hex32(read_mstatus());
    uart_puts("\r\n");

    /* 2a' -- does trap entry work AT ALL? A synchronous ecall does not
     * depend on mstatus.MIE, mie or the interrupt arbitration, only on
     * mtvec and the redirect. If this prints FAIL the ecall retired
     * without trapping; if nothing prints at all, the vector landed
     * somewhere that never comes back -- either way the interrupt path is
     * not the thing to look at. */
    __asm__ volatile("ecall");
    uart_puts(sync_traps ? "TRAP OK\r\n" : "TRAP FAIL\r\n");

    /* 2b + 2c */
    __asm__ volatile("csrsi mstatus, %0" ::"i"(MSTATUS_MIE));

    /* With a byte already queued and the IRQ level-high, the interrupt is
     * taken before this line runs, so the echoed byte appears BEFORE this
     * print. Reading mstatus back here is the last discriminator: if it
     * shows MIE set and no byte was echoed, then mip, mie, mstatus and
     * trap entry are all provably fine and the interrupt simply is not
     * being taken -- which points at the arbitration/timing, not the
     * peripheral. */
    uart_puts("MST2 ");
    uart_put_hex32(read_mstatus());
    uart_puts("\r\n");

    while (irq_chars < PHASE_CHARS && !bad_cause) __asm__ volatile("wfi");

    /* Mask before reporting, so the marker store cannot race a handler. */
    __asm__ volatile("csrci mstatus, %0" ::"i"(MSTATUS_MIE));
    UART_CTRL = 0;

    if (bad_cause || irq_chars < PHASE_CHARS) {
        *result = 0xBAD;
        uart_puts("BAD\r\n");
    } else {
        *result = 0x600D;
        uart_puts("GOOD\r\n");
    }

    /* Park in a self-loop, not in wfi: the sim harness stops on 8 identical
     * retires, and a wfi with every interrupt masked would instead trip its
     * "halt with no wake" liveness check (legal per spec, useless here). */
    __asm__ volatile("1: j 1b");
    __builtin_unreachable();
}
