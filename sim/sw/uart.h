#ifndef UART_INIT_H
#define UART_INIT_H

#define UART_BASE   0x10000000u
#define UART_TXDATA (*(volatile unsigned int *)(UART_BASE + 0x00))
#define UART_STATUS (*(volatile unsigned int *)(UART_BASE + 0x08))
#define UART_TX_READY_BIT 0x1u

#define UART_RXDATA        (*(volatile unsigned int *)(UART_BASE + 0x04))
#define UART_RX_READY_BIT  0x2u

static char uart_getc(void)
{
    while (!(UART_STATUS & UART_RX_READY_BIT))
        ;
    return (char)(UART_RXDATA & 0xFF);
}

/* UART_TX_PACED: send with a software delay instead of the TX_READY poll,
 * long enough that only one byte is ever in flight, so the TX FIFO never
 * becomes full and the poll loop is never entered.
 *
 * This exists as a board diagnostic. On silicon both the monitor and the
 * bring-up program stop producing output exactly when the TX FIFO first
 * fills -- 16 bytes into an uninterrupted burst -- while simulation, which
 * fills the same FIFO at the same baud, runs to completion. Paced output
 * removes both suspects at once: no full FIFO, and no polling. If the
 * output then completes, the fault is in the full/pop path of the
 * peripheral; if it still stops, the FIFO is exonerated and the bus or the
 * engine is the place to look.
 *
 * UART_TX_DELAY is in loop iterations, a few cycles each. The default is
 * comfortably longer than one 115200 frame at 25 MHz (2170 cycles). */
#ifndef UART_TX_PACED
#define UART_TX_PACED 0
#endif
#ifndef UART_TX_DELAY
#define UART_TX_DELAY 3000
#endif

static void uart_putc(char c)
{
#if UART_TX_PACED
    for (volatile int d = 0; d < UART_TX_DELAY; ++d)
        ;
    UART_TXDATA = (unsigned int)(unsigned char)c;
#else
    while (!(UART_STATUS & UART_TX_READY_BIT))
        ;
    UART_TXDATA = (unsigned int)(unsigned char)c;
#endif
}

static void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}

static void uart_put_hex32(unsigned int v)
{
    static const char hex[] = "0123456789ABCDEF";
    uart_puts("0x");
    for (int i = 28; i >= 0; i -= 4)
        uart_putc(hex[(v >> i) & 0xF]);
}

#endif /* UART_INIT_H */