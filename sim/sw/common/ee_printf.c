/*
 * Minimal integer printf over the UART. Shared by the harnesses that link a
 * vendored benchmark whose sources call printf and are not ours to edit
 * (coremark/, dhrystone/); everything else in the tree writes through
 * uart.h directly.
 *
 * Supports %d %u %x %s %c %% with an optional zero/width field and any
 * number of `l` length modifiers (CoreMark prints %lu / %04x). No %f:
 * neither port asks for one -- CoreMark builds with HAS_FLOAT 0, and the
 * Dhrystone port prints the two float results through a %d cast that
 * upstream already applies.
 *
 * Newlines are expanded to CR+LF. Both benchmarks' format strings end in a
 * bare "\n", and a serial terminal takes that as line feed only -- the
 * cursor stays in its column, so every line after the first starts where
 * the previous one ended and the report comes out as a staircase. Nothing
 * else in the tree hits this because the other programs write "\r\n" in
 * their own strings; here the strings are upstream's and are not ours to
 * edit.
 */

#include <stdarg.h>
#include "uart.h"

static void put_char(char c)
{
    if (c == '\n') uart_putc('\r');
    uart_putc(c);
}

static void put_str(const char *s)
{
    while (*s) put_char(*s++);
}

static void put_dec(unsigned long v, int is_signed, int width)
{
    char buf[12];
    int  i = 0;
    if (is_signed && (long)v < 0) {
        put_char('-');
        v = (unsigned long)(-(long)v);
    }
    do {
        buf[i++] = (char)('0' + (v % 10u));
        v /= 10u;
    } while (v);
    /* Zero-padded width, not just for looks: the report prints hundredths
     * as "%u.%02u", and without the padding 0.01 comes out as "0.1". */
    while (i < width && i < (int)sizeof(buf)) buf[i++] = '0';
    while (i--) put_char(buf[i]);
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
    while (i--) put_char(buf[i]);
}

int printf(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);

    while (*fmt) {
        if (*fmt != '%') {
            put_char(*fmt++);
            continue;
        }
        ++fmt;
        int width = 0;
        while (*fmt >= '0' && *fmt <= '9') width = width * 10 + (*fmt++ - '0');
        while (*fmt == 'l') ++fmt;
        switch (*fmt++) {
            case 'd': put_dec((unsigned long)va_arg(ap, long), 1, width); break;
            case 'u': put_dec(va_arg(ap, unsigned long), 0, width); break;
            case 'x': put_hex(va_arg(ap, unsigned long), width); break;
            case 's': put_str(va_arg(ap, const char *)); break;
            case 'c': put_char((char)va_arg(ap, int)); break;
            case '%': put_char('%'); break;
            default: break;
        }
    }

    va_end(ap);
    return 0;
}
