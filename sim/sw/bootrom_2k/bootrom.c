/*
 * YARV32-uC boot ROM.
 *
 * Minimal firmware whose only job is to announce the core on the UART and
 * then park. It exists to fit in a 2 KiB instruction memory (see
 * bootrom_link.ld), so it deliberately pulls in nothing beyond uart.h's
 * inline helpers -- no printf, no hex formatting, no monitor loop.
 *
 * The banner text lives in .rodata, which the linker places in the D-mem:
 * this core is Harvard, so a fetch can never read a data byte and the
 * string cannot sit next to the code that prints it.
 */

#include "uart.h"

int main(void)
{
    uart_puts("YARV32-uC bootrom\r\n");

    /* Nothing follows the banner: return to _start's parking loop. */
    return 0;
}
