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
#define MCAUSE_MEI  0x8000000Bu

#define PHASE_CHARS 4

/* .bss is not zeroed by start.S, so anything needing a known initial
 * value lives in .data (an explicit initialiser puts it there). */
static volatile uint32_t irq_chars = 0;  /* bytes echoed by the handler */
static volatile uint32_t bad_cause = 0;  /* unexpected mcause, if any */

static volatile uint32_t *const result = (volatile uint32_t *)0x3000;

static inline uint32_t read_mcause(void)
{
    uint32_t v;
    __asm__ volatile("csrr %0, mcause" : "=r"(v));
    return v;
}

/* GCC's machine-interrupt attribute emits the register save/restore and
 * the mret for us; mtvec is programmed to this address in direct mode. */
__attribute__((interrupt("machine"))) void trap_handler(void)
{
    uint32_t cause = read_mcause();

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

    /* ---- Phase 2: interrupt-driven ---- */
    UART_CTRL = CTRL_RX_IE;
    __asm__ volatile("csrw mtvec, %0" ::"r"((uint32_t)&trap_handler));
    __asm__ volatile("csrs mie, %0" ::"r"(MIE_MEIE));
    __asm__ volatile("csrsi mstatus, %0" ::"i"(MSTATUS_MIE));

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
