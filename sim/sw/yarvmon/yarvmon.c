#include <stdint.h>
#include "uart.h"

/*
 * RV32 YarvMon — port of Steve Wozniak's Apple 1 monitor.
 *
 * Differences vs the original (forced by this core's Harvard memory):
 *   - Addresses are 32-bit (8 hex digits), not 16-bit.
 *   - Examine (XAM) and deposit (STOR/':') only reach dmem/peripherals
 *     (the LSU's address space). They CANNOT touch imem: there is no
 *     store path to instruction memory on this core.
 *   - 'R' jumps to the last-examined address via a function-pointer
 *     call. It only makes sense as an address already present in imem
 *     (e.g. a function linked into the firmware image) — it is NOT a
 *     load-and-run: bytes deposited via ':' live in dmem and are never
 *     seen by fetch.
 *   - Backspace: '_' (Apple 1 convention) or 0x08/0x7F.
 */

#define IN_BUF_SIZE 132

typedef enum { MODE_XAM, MODE_STOR, MODE_BLOCK } mode_t;

static char     in_buf[IN_BUF_SIZE];
static uint32_t xam;      /* last examined address */
static uint32_t st_addr;  /* current store address */

static void print_nibble(unsigned v)
{
    uart_putc("0123456789ABCDEF"[v & 0xF]);
}

static void print_hex32(uint32_t v)
{
    for (int i = 28; i >= 0; i -= 4) print_nibble(v >> i);
}

static void print_hex8(uint8_t v)
{
    print_nibble(v >> 4);
    print_nibble(v);
}

static void newline(void)
{
    uart_putc('\r');
    uart_putc('\n');
}

static int is_hex_digit(char c, unsigned *val)
{
    if (c >= '0' && c <= '9') { *val = (unsigned)(c - '0');      return 1; }
    if (c >= 'A' && c <= 'F') { *val = (unsigned)(c - 'A' + 10); return 1; }
    if (c >= 'a' && c <= 'f') { *val = (unsigned)(c - 'a' + 10); return 1; }
    return 0;
}

/* Read one line, echoing; returns length. Backspace edits in place. */
static int get_line(void)
{
    int idx = 0;
    for (;;) {
        char c = uart_getc();

        if (c == '\r' || c == '\n') { newline(); return idx; }

        if (c == '_' || c == 0x08 || c == 0x7F) {
            if (idx > 0) { idx--; uart_puts("\b \b"); }
            continue;
        }
        if (idx >= IN_BUF_SIZE - 1) continue;  /* drop overflow */

        in_buf[idx++] = c;
        uart_putc(c);
    }
}

static void print_addr_prefix(uint32_t addr)
{
    newline();
    print_hex32(addr);
    uart_putc(':');
}

void yarvmon(void)
{
    uart_puts("\r\nRV32 YARV-Mon\r\n");

    for (;;) {
        uart_putc('\\');
        newline();

        int len = get_line();
        int y = 0;
        mode_t mode = MODE_XAM;

        while (y < len) {
            /* skip delimiters / consume mode-setting chars */
            while (y < len) {
                char c = in_buf[y];
                if (c == '.') { mode = MODE_BLOCK; y++; continue; }
                if (c == ':') { mode = MODE_STOR;  y++; continue; }
                if (c == ' ') { y++; continue; }
                if (c == 'R' || c == 'r') {
                    void (*fn)(void) = (void (*)(void))xam;
                    fn();
                    y = len;  /* end this line */
                    break;
                }
                break;
            }
            if (y >= len) break;

            unsigned  v;
            uint32_t  hex_val = 0;
            int       digits  = 0;
            while (y < len && is_hex_digit(in_buf[y], &v)) {
                hex_val = (hex_val << 4) | v;
                digits++;
                y++;
            }
            if (digits == 0) break;  /* syntax error: reprompt */

            if (mode == MODE_STOR) {
                *(volatile uint8_t *)st_addr = (uint8_t)hex_val;
                st_addr++;
                continue;
            }

            if (mode == MODE_BLOCK) {
                uint32_t end = hex_val;
                print_addr_prefix(xam);
                uart_putc(' ');
                for (;;) {
                    print_hex8(*(volatile uint8_t *)xam);
                    if (xam == end) break;
                    xam++;
                    if ((xam & 0x7) == 0) print_addr_prefix(xam);
                    else                  uart_putc(' ');
                }
                mode = MODE_XAM;
                continue;
            }

            /* MODE_XAM: single examine */
            xam     = hex_val;
            st_addr = hex_val;
            print_addr_prefix(xam);
            uart_putc(' ');
            print_hex8(*(volatile uint8_t *)xam);
        }
    }
}

int main(void)
{
    yarvmon();
    return 0;
}