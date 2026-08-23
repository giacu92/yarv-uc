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

static void uart_putc(char c)
{
    while (!(UART_STATUS & UART_TX_READY_BIT))
        ;
    UART_TXDATA = (unsigned int)(unsigned char)c;
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