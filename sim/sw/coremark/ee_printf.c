/*
 * Minimal integer printf over the UART for CoreMark.
 *
 * Supports %d %u %x %s %c %% with an optional zero/width field and any
 * number of `l` length modifiers (CoreMark prints %lu / %04x). No %f:
 * HAS_FLOAT is 0 in core_portme.h, so CoreMark never asks for one.
 */

#include <stdarg.h>
#include "uart.h"

static void put_dec(unsigned long v, int is_signed)
{
    char buf[12];
    int  i = 0;
    if (is_signed && (long)v < 0) {
        uart_putc('-');
        v = (unsigned long)(-(long)v);
    }
    do {
        buf[i++] = (char)('0' + (v % 10u));
        v /= 10u;
    } while (v);
    while (i--) uart_putc(buf[i]);
}

static void put_hex(unsigned long v, int width)
{
    static const char hex[] = "0123456789abcdef";
    char              buf[8];
    int               i = 0;
    do {
        buf[i++] = hex[v & 0xFu];
        v >>= 4;
    } while (v);
    while (i < width && i < (int)sizeof(buf)) buf[i++] = '0';
    while (i--) uart_putc(buf[i]);
}

int printf(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);

    while (*fmt) {
        if (*fmt != '%') {
            uart_putc(*fmt++);
            continue;
        }
        ++fmt;
        int width = 0;
        while (*fmt >= '0' && *fmt <= '9') width = width * 10 + (*fmt++ - '0');
        while (*fmt == 'l') ++fmt;
        switch (*fmt++) {
            case 'd': put_dec((unsigned long)va_arg(ap, long), 1); break;
            case 'u': put_dec(va_arg(ap, unsigned long), 0); break;
            case 'x': put_hex(va_arg(ap, unsigned long), width); break;
            case 's': uart_puts(va_arg(ap, const char *)); break;
            case 'c': uart_putc((char)va_arg(ap, int)); break;
            case '%': uart_putc('%'); break;
            default: break;
        }
    }

    va_end(ap);
    return 0;
}
