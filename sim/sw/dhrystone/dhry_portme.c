/*
 * Dhrystone 2.1 port layer for this core.
 *
 * sifive/ is the benchmark, vendored verbatim (see sifive/UPSTREAM.md).
 * Everything the workload assumes a hosted system provides lives here:
 *
 *   - main()     wraps the benchmark so a port summary can be printed
 *                after it (see the -Dmain=dhry_main note below)
 *   - time()     the one hosted service dhry_1.c calls, backed by mcycle
 *   - malloc()   a two-allocation bump allocator; Dhrystone calls it twice,
 *                at startup, and never frees
 *   - strcpy()   inside the measurement loop, so it is part of the score
 *   - memcpy/memset  gcc emits calls to these for structure assignment and
 *                array initialisation even under -nostdlib
 *
 * printf comes from ../common/ee_printf.c (shared with the CoreMark port);
 * strcmp comes from sifive/strcmp.S, which is part of what SiFive vendored.
 *
 * WHY main IS RENAMED. The Makefile compiles dhry_1.c -- and only dhry_1.c
 * -- with `-Dmain=dhry_main`, so the benchmark's `main()` becomes
 * `dhry_main()` without a character of the vendored file changing, and this
 * file provides the real main(). That is the only way to get a line printed
 * *after* the benchmark's own report: start.S calls main and then spins
 * forever, there is no exit path and no atexit, and Dhrystone -- unlike
 * CoreMark -- has no portable_fini() hook of its own.
 */

#include "uart.h"

/* DHRY_ITERS / CLK_HZ come from the Makefile. Defaults here only so this
 * file is readable on its own; the build always defines both. */
#ifndef DHRY_ITERS
#define DHRY_ITERS 2000
#endif
#ifndef CLK_HZ
#define CLK_HZ 50000000u
#endif

extern void dhry_main(void);

/* ------------------------------------------------------------------ time */

/* mcycle is the only cycle counter on this core (there is no mcycleh), so
 * the timed region must stay under 2^32 cycles -- about 86 s at 50 MHz.
 * csr_regfile returns the value as of the previous cycle, a constant
 * one-cycle offset that cancels in the stop-minus-start difference. */
static inline unsigned rdcycle(void)
{
    unsigned v;
    __asm__ volatile("csrr %0, mcycle" : "=r"(v));
    return v;
}

/* dhry_1.c brackets the measurement loop with two time() calls and nothing
 * else calls it, so the first is Begin_Time and the second is End_Time.
 * The return value is whole seconds, which is all the K&R interface offers
 * and is what upstream's own arithmetic expects (Too_Small_Time is 2
 * seconds). The cycle counts recorded on the side are what the port
 * summary reports: seconds are far too coarse for a simulation run, where
 * the whole benchmark is a fraction of one. */
static unsigned t_begin_cycles, t_end_cycles;
static int      t_calls;

long time(long *unused)
{
    unsigned c = rdcycle();
    (void)unused;
    if (t_calls++ == 0)
        t_begin_cycles = c;
    else
        t_end_cycles = c;
    return (long)(c / (unsigned)CLK_HZ);
}

/* ----------------------------------------------------------------- heap */

/* Dhrystone allocates two Rec_Type records at startup and never frees. A
 * bump allocator over a static block is the whole requirement; a real heap
 * would cost D-mem this program has none of (Arr_2_Glob already takes
 * 10 000 of the 16 384 bytes). Overflow returns 0, which Dhrystone would
 * dereference -- but the pool is sized from sizeof(Rec_Type) at the two
 * call sites, so it cannot happen without an edit to the workload.
 *
 * The pool is in .bss, at the far end of the D-mem from .rodata, so no
 * pointer handed out is ever 0 -- Proc_3 compares Ptr_Glob against Null. */
#define HEAP_BYTES 256
static unsigned long heap[HEAP_BYTES / sizeof(unsigned long)];
static unsigned      heap_used;

/* Defined against dhry_1.c's own K&R `extern char *malloc ();`, which is
 * why stdio.h here does not declare it -- see the note there. */
void *malloc(unsigned long n)
{
    n = (n + (sizeof(unsigned long) - 1)) & ~(unsigned long)(sizeof(unsigned long) - 1);
    if (heap_used + n > HEAP_BYTES) return 0;
    void *p = (char *)heap + heap_used;
    heap_used += (unsigned)n;
    return p;
}

/* ---------------------------------------------------------------- string */

/* strcpy runs INSIDE the measurement loop -- three calls per iteration, on
 * 30-character strings -- so this implementation is part of the score, not
 * just of the setup. That is the well-known thing about Dhrystone: the
 * number says as much about the C library as about the core, which is why
 * SiFive's tree ships its own strcmp.S rather than trusting whatever
 * strcmp the target links. This port states what it links, in the source
 * next to the number it produces.
 *
 * Word-at-a-time, with the same shape as that strcmp.S: proceed a word at a
 * time only while both pointers share an alignment, and byte-copy the word
 * that contains the terminator instead of storing past it (dst is a
 * `char [31]`, and a full-word store of the last word would write one byte
 * beyond the array). -mstrict-align is on and this core traps rather than
 * fixing a misaligned access up, so the alignment test is load-bearing, not
 * an optimisation.
 *
 * A plain byte loop here costs 891 cycles per iteration against this one's
 * 686 -- 0.63 DMIPS/MHz against 0.82. Both were measured on this core, at
 * DHRY_ITERS=2000, with nothing else changed. Neither figure is wrong; they are
 * measurements of two different libraries on the same core. The faster one
 * is the one comparable with published scores, which are quoted against
 * newlib or an equivalent.
 *
 * may_alias: the two buffers are char arrays and are read here through
 * unsigned, which -fstrict-aliasing (implied by -O3) would otherwise be
 * entitled to assume cannot happen. The attribute is local to this file --
 * turning strict aliasing off globally would also change how the workload
 * itself is compiled, and so the score. */
typedef unsigned __attribute__((may_alias)) uword;

/* Non-zero if w contains a zero byte. The standard bit trick: subtracting 1
 * from a zero byte borrows into its top bit, and ~w keeps only the bytes
 * that were not already >= 0x80. */
#define HAS_ZERO_BYTE(w) (((w) - 0x01010101u) & ~(w) & 0x80808080u)

char *strcpy(char *dst, const char *src)
{
    char *d = dst;

    if ((((unsigned)(unsigned long)d ^ (unsigned)(unsigned long)src) & 3u) == 0u) {
        /* Same phase: byte-copy up to the first word boundary, then run
         * word-wise until the word holding the terminator. */
        while (((unsigned)(unsigned long)src & 3u) != 0u) {
            if ((*d++ = *src++) == '\0') return dst;
        }
        {
            const uword *ws = (const uword *)src;
            uword       *wd = (uword *)d;
            uword        w;
            /* The load is its own statement: HAS_ZERO_BYTE names its
             * argument three times, so an assignment inside it would be
             * three modifications between sequence points. */
            for (;;) {
                w = *ws;
                if (HAS_ZERO_BYTE(w)) break;
                *wd++ = w;
                ++ws;
            }
            d   = (char *)wd;
            src = (const char *)ws;
        }
    }

    /* Different phases, or the tail word that holds the terminator. */
    while ((*d++ = *src++) != '\0')
        ;
    return dst;
}

/* -nostdlib: gcc still emits calls to these for structure assignment
 * (Dhrystone's structassign is a plain `d = s` on a 48-byte record) and for
 * array initialisation. */
void *memcpy(void *dst, const void *src, unsigned long n)
{
    char       *d = (char *)dst;
    const char *s = (const char *)src;
    while (n--) *d++ = *s++;
    return dst;
}

void *memset(void *dst, int c, unsigned long n)
{
    char *d = (char *)dst;
    while (n--) *d++ = (char)c;
    return dst;
}

/* --------------------------------------------------------------- report */

static void print_x100(unsigned whole, unsigned hundredths)
{
    printf("%u.%02u", whole, hundredths);
}

/* One Dhrystone MIPS is 1757 Dhrystones per second: the VAX 11/780, the
 * machine the unit is defined against, ran the benchmark 1757 times a
 * second and was rated at 1 MIPS. DMIPS/MHz divides that by the clock, so
 * with cycles measured directly it reduces to
 *
 *     DMIPS/MHz = 1e6 / (cycles_per_iteration * 1757)
 *
 * and no clock frequency enters it -- the figure holds whatever CLK_HZ is
 * set to, exactly as CoreMark/MHz does. Everything below is 32-bit
 * arithmetic; per_iter * 1757 stays well inside it for any run this
 * memory can hold. */
#define VAX_DHRY_PER_SEC 1757u

static void report_port_summary(void)
{
    unsigned ticks = t_end_cycles - t_begin_cycles;
    unsigned iters = (unsigned)DHRY_ITERS;

    printf("\n");
    printf("  Ticks (core cycles) : %u\n", ticks);

    if (ticks == 0 || iters == 0) return;

    unsigned per_iter = ticks / iters;
    printf("  Cycles / iteration  : %u\n", per_iter);

    printf("  Total time (secs)   : ");
    print_x100(ticks / (unsigned)CLK_HZ,
               (ticks % (unsigned)CLK_HZ) / ((unsigned)CLK_HZ / 100u));
    printf("\n");

    if (per_iter == 0) return;

    /* Dhrystones per second at CLK_HZ. This one *does* depend on the clock;
     * it is the raw rate, the figure DMIPS is derived from. */
    unsigned dhry_per_sec = (unsigned)CLK_HZ / per_iter;
    printf("  Dhrystones / sec    : %u\n", dhry_per_sec);

    unsigned dmips100 = (dhry_per_sec * 100u) / VAX_DHRY_PER_SEC;
    printf("  DMIPS               : ");
    print_x100(dmips100 / 100u, dmips100 % 100u);
    printf("\n");

    unsigned dmips_mhz100 = 100000000u / (per_iter * VAX_DHRY_PER_SEC);
    printf("  DMIPS / MHz         : ");
    print_x100(dmips_mhz100 / 100u, dmips_mhz100 % 100u);
    printf("\n");
}

/* ----------------------------------------------------------------- main */

int main(void)
{
    /* A banner before the run, for the same reason the CoreMark port has
     * one: at a reportable iteration count the board prints nothing for
     * tens of seconds and looks hung. */
    printf("\n");
    printf("  YARV32-uC  --  RV32IMAC Zicsr Zifencei\n");
    printf("  Dhrystone 2.1  --  %u runs\n", (unsigned)DHRY_ITERS);
    printf("  ------------------------------------------\n");
    printf("  Core clock : %u Hz\n", (unsigned)CLK_HZ);
#ifdef CYCLES_PER_ITER
    {
        /* A compile-time constant divided by the clock: it says what to
         * expect, it measures nothing. At a simulation-sized DHRY_ITERS the
         * quotient is 0, and printing "~0 s" reads like a broken counter --
         * say "under 1 s" instead. */
        unsigned expect_s = (unsigned)(((unsigned long long)DHRY_ITERS
                                        * CYCLES_PER_ITER) / (unsigned)CLK_HZ);
        if (expect_s)
            printf("  Expected   : ~%u s\n", expect_s);
        else
            printf("  Expected   : under 1 s (short run: Dhrystone wants 2 s)\n");
    }
#endif
    printf("\n  running...\n");

    dhry_main();
    report_port_summary();
    return 0;
}
