#include <stdint.h>
#include "uart.h"

/*
 * ISA probe: check individual instructions on hardware without depending on
 * any of the instructions under test.
 *
 * Why it exists. On the board every hex value printed came out with the low
 * two bits of each nibble cleared (0x0123ABCD read back as 0x000088CC),
 * while simulation prints it correctly. The printer does
 * hex[(v >> i) & 0xF], so exactly two single faults explain that output and
 * they are indistinguishable from it: a c.andi whose immediate loses
 * imm[1:0] (15 acting as 12), or a variable srl that clears the low two
 * bits of its result. This program separates them, and covers the
 * neighbouring encodings while it is there.
 *
 * Two rules make the results trustworthy:
 *   - Results are reported as fixed strings ("OK" / "BAD"), never through
 *     the hex printer, which is the thing under suspicion.
 *   - The binary dump uses only register-register AND and mask doubling by
 *     addition -- no immediate AND, no shift of any kind. It prints
 *     least-significant bit first, which is unusual to read but keeps the
 *     dump free of every instruction being tested.
 */

/* Least-significant bit first: mask starts at 1 and doubles by addition, so
 * no shift is involved, and `v & mask` is an AND of two registers rather
 * than an AND with an immediate. */
static void put_bin32_lsb(uint32_t v)
{
    uint32_t mask = 1u;
    for (int i = 0; i < 32; i++) {
        uart_putc((v & mask) ? '1' : '0');
        mask = mask + mask;
    }
}

static void report(const char *name, uint32_t got, uint32_t want)
{
    uart_puts(name);
    if (got == want) {
        uart_puts(" OK\r\n");
    } else {
        uart_puts(" BAD got=");
        put_bin32_lsb(got);
        uart_puts(" want=");
        put_bin32_lsb(want);
        uart_puts("\r\n");
    }
}

/* Hand-encoded compressed ANDI, with the register pinned so the halfword is
 * exactly the encoding named. c.andi rd', imm: funct3=100, c[12]=imm[5],
 * c[11:10]=10, c[9:7]=rd' (111 -> a5), c[6:2]=imm[4:0], c[1:0]=01.
 *   imm=15 -> 0x8BBD    imm=7 -> 0x8B9D
 *   imm=3  -> 0x8B8D    imm=1 -> 0x8B85
 * The immediates 1 and 3 are the point: they live entirely in imm[1:0], so
 * if those bits are dropped the result is 0 instead of the operand. */
#define C_ANDI(enc)                                        \
    ({                                                     \
        register uint32_t x __asm__("a5") = 0xFFFFFFFFu;   \
        __asm__ volatile(".short " #enc : "+r"(x));         \
        x;                                                 \
    })

int main(void)
{
    uart_puts("\r\nISA PROBE\r\n");

    /* --- compressed ANDI, the prime suspect --- */
    report("c.andi15", C_ANDI(0x8BBD), 15u);
    report("c.andi7 ", C_ANDI(0x8B9D), 7u);
    report("c.andi3 ", C_ANDI(0x8B8D), 3u);
    report("c.andi1 ", C_ANDI(0x8B85), 1u);

    /* --- the same operation as a 32-bit ANDI: if this passes while the
     * compressed form fails, the fault is in c_expand, not in the ALU --- */
    {
        uint32_t in = 0xFFFFFFFFu, out;
        __asm__ volatile(".insn i 0x13, 0x7, %0, %1, 15" : "=r"(out) : "r"(in));
        report("andi15  ", out, 15u);
        __asm__ volatile(".insn i 0x13, 0x7, %0, %1, 3" : "=r"(out) : "r"(in));
        report("andi3   ", out, 3u);
    }

    /* --- the other candidate: shifts. A variable srl that cleared the low
     * two bits of its result would corrupt the printer identically. --- */
    {
        volatile uint32_t v = 0xFFFFFFFFu;
        volatile int sh = 8;
        uint32_t out;
        out = v >> sh;
        report("srl8    ", out, 0x00FFFFFFu);
        sh  = 1;
        out = v >> sh;
        report("srl1    ", out, 0x7FFFFFFFu);
        out = v >> 4;      /* srli, immediate form */
        report("srli4   ", out, 0x0FFFFFFFu);
        out = v >> 1;
        report("srli1   ", out, 0x7FFFFFFFu);
        out = v << 1;
        report("slli1   ", out, 0xFFFFFFFEu);
    }

    /* --- register-register AND and OR, for completeness: these are what the
     * binary dump above relies on, so a failure here invalidates the rest
     * rather than adding to it. --- */
    {
        volatile uint32_t a = 0xF0F0F0F0u, b = 0x3333CCCCu;
        report("and.rr  ", a & b, 0x3030C0C0u);
        report("or.rr   ", a | b, 0xF3F3FCFCu);
    }

    /* --- a byte load at each lane of a word, which is the other way the
     * printer could have lost the low index bits --- */
    {
        static uint8_t lanes[4] __attribute__((section(".data"))) = {
            0x11u, 0x22u, 0x33u, 0x44u
        };
        volatile int i;
        uint32_t got = 0, want = 0x44332211u;
        for (i = 3; i >= 0; i--) {
            got = got + got;  /* x16 without a shift: doubled four times */
            got = got + got;
            got = got + got;
            got = got + got;
            got = got + got;
            got = got + got;
            got = got + got;
            got = got + got;
            got = got + lanes[i];
        }
        report("lbu.lane", got, want);
    }

    /* --- the table itself. A third fault predicts the same corrupted
     * output as the two above: if each word of the loaded image held its
     * byte 0 replicated across all four lanes, the hex table would read
     * "0000444488888CCCC" and hex[15] would be 'C', hex[11] '8', hex[5]
     * '4' -- exactly what the board printed. So read a known table back
     * byte by byte and say which indices are wrong, as a 16-character
     * map: '.' correct, 'X' wrong. One copy in .rodata (where the printer's
     * table lives) and one in .data, because they are loaded the same way
     * but addressed differently. --- */
    {
        static const char ro_tab[17] = "0123456789ABCDEF";
        static char rw_tab[17] __attribute__((section(".data"))) =
            "0123456789ABCDEF";
        volatile int i;

        uart_puts("rodata  ");
        for (i = 0; i < 16; i++) uart_putc(ro_tab[i] == "0123456789ABCDEF"[i] ? '.' : 'X');
        uart_puts("\r\n");
        uart_puts("rodata2 ");
        for (i = 0; i < 16; i++) uart_putc(ro_tab[i]);
        uart_puts("\r\n");
        uart_puts("data    ");
        for (i = 0; i < 16; i++) uart_putc(rw_tab[i]);
        uart_puts("\r\n");
    }

    /* --- memory access matrix ---------------------------------------
     * The earlier lane test bundled four loads, a shift and three adds
     * into one verdict, which is useless when the verdict disagrees with
     * another test. This takes one known word in .rodata and one in
     * .data and reads it every way the compiler ever emits, one check per
     * line:
     *
     *   lw            the whole word
     *   lbu imm       byte, constant offset in the instruction
     *   lbu reg       byte, address computed with an add (what indexing a
     *                 table with a variable produces)
     *   lhu imm       halfword, both halves
     *
     * If the constant-offset byte loads pass while the computed-address
     * ones fail, the fault is in address formation, not in the memory. If
     * lw passes while every byte load fails, it is sub-word extraction.
     * If lw itself is wrong, the word is not what the image says and the
     * question moves to how the memory was initialised. --- */
    {
        static const uint32_t ro_word = 0x44332211u;
        static uint32_t rw_word __attribute__((section(".data"))) = 0x44332211u;

        const uint8_t *rb = (const uint8_t *)&ro_word;
        const uint8_t *wb = (const uint8_t *)&rw_word;
        volatile int k;

        uart_puts("-- .rodata word --\r\n");
        report("lw      ", ro_word, 0x44332211u);
        report("lbu.i0  ", rb[0], 0x11u);
        report("lbu.i1  ", rb[1], 0x22u);
        report("lbu.i2  ", rb[2], 0x33u);
        report("lbu.i3  ", rb[3], 0x44u);
        k = 0; report("lbu.r0  ", rb[k], 0x11u);
        k = 1; report("lbu.r1  ", rb[k], 0x22u);
        k = 2; report("lbu.r2  ", rb[k], 0x33u);
        k = 3; report("lbu.r3  ", rb[k], 0x44u);
        report("lhu.i0  ", ((const uint16_t *)&ro_word)[0], 0x2211u);
        report("lhu.i2  ", ((const uint16_t *)&ro_word)[1], 0x4433u);

        uart_puts("-- .data word --\r\n");
        report("Dlw     ", rw_word, 0x44332211u);
        report("Dlbu.i1 ", wb[1], 0x22u);
        report("Dlbu.i3 ", wb[3], 0x44u);
        k = 1; report("Dlbu.r1 ", wb[k], 0x22u);
        k = 3; report("Dlbu.r3 ", wb[k], 0x44u);

        /* Store the byte lanes back and read them again: this is the only
         * check here that exercises a sub-word STORE, which is a separate
         * path (byte strobes) from any load. */
        uint8_t *wbw = (uint8_t *)&rw_word;
        wbw[0] = 0xAAu;
        wbw[1] = 0xBBu;
        wbw[2] = 0xCCu;
        wbw[3] = 0xDDu;
        report("sb.word ", rw_word, 0xDDCCBBAAu);
        k = 2; report("sb.r2   ", wbw[k], 0xCCu);
    }

    uart_puts("PROBE END\r\n");
    for (;;) { /* park */ }
}
