#include "coremark.h"

#define CM_VERSION "CoreMark 1.0"

#if VALIDATION_RUN
#define RUN_NAME "validation"
#elif PROFILE_RUN
#define RUN_NAME "profile"
#else
#define RUN_NAME "performance"
#endif

ee_u32 default_num_contexts = 1;

/* PERFORMANCE_RUN / VALIDATION_RUN pick the seeds; the Makefile defines one. */
#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

/* mcycle is the only cycle counter here (no mcycleh), so the timed region
 * must stay under 2^32 cycles. csr_regfile returns the value as of the
 * previous cycle -- a constant one-cycle offset that cancels in the
 * stop-minus-start difference. */
static inline ee_u32 rdcycle(void)
{
#if COSIM
    /* The co-sim diffs every retire's register write against Spike, and a
     * cycle counter is the one register value that cannot match: Spike is
     * instruction-based and has no notion of this pipeline's cycles. The
     * co-sim build therefore reads no counter at all -- it measures nothing
     * and reports 0 ticks, which is fine, because what it checks is
     * architectural equivalence, not speed. Build without COSIM=1 for a
     * timed run. */
    return 0;
#else
    ee_u32 v;
    __asm__ volatile("csrr %0, mcycle" : "=r"(v));
    return v;
#endif
}

static CORE_TICKS start_ticks, stop_ticks;

void portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc;
    (void)argv;
    p->portable_id = 1;

#if !COSIM
    /* A banner before the run, because the whole benchmark is silent: at
     * the iteration count a valid score needs, the board prints nothing
     * for half a minute and looks hung. Suppressed in the co-sim build,
     * where the first UART access is where Spike stops being comparable
     * and printing here would end the diff before any work is done.
     *
     * The estimate is a compile-time constant (CYCLES_PER_ITER, measured
     * on this core) divided by the clock -- it says what to expect, it
     * does not measure anything. */
    printf("\n");
    printf("  YARV32-uC  --  RV32IMAC Zicsr Zifencei\n");
    /* CM_VERSION: the sources carry no version macro of their own -- the
     * only version the benchmark states about itself is the "CoreMark 1.0"
     * in its own report lines, so that is what this repeats. */
    printf("  %s  --  %u-byte %s run\n", CM_VERSION, (unsigned)TOTAL_DATA_SIZE,
           RUN_NAME);
    printf("  ------------------------------------------\n");
    printf("  Core clock : %u Hz\n", (unsigned)CLK_HZ);
    printf("  Iterations : %u\n", (unsigned)ITERATIONS);
    printf("  Expected   : ~%u s\n",
           (unsigned)(((unsigned long long)ITERATIONS * CYCLES_PER_ITER)
                      / CLK_HZ));
    printf("\n  running...\n\n");
#endif
}

void portable_fini(core_portable *p) { p->portable_id = 0; }

void start_time(void) { start_ticks = rdcycle(); }
void stop_time(void) { stop_ticks = rdcycle(); }

CORE_TICKS get_time(void) { return stop_ticks - start_ticks; }

/* HAS_FLOAT=0, so secs_ret is an integer: whole seconds at the core clock.
 * A short simulation run reports 0 here; the cycle count is the number to
 * read. CLK_HZ is set by the Makefile and must track the build's clock. */
secs_ret time_in_secs(CORE_TICKS ticks) { return (secs_ret)(ticks / CLK_HZ); }

/* Print a tick count as seconds with two decimals, and an iteration count
 * over a tick count as iterations per second with two decimals. Both
 * divide before scaling so nothing overflows 32 bits: ticks can reach
 * 2^32-1, and multiplying that by 100 first would not fit. */
static void print_x100(ee_u32 whole, ee_u32 hundredths)
{
    printf("%u.%02u", (unsigned)whole, (unsigned)hundredths);
}

void print_secs_x100(CORE_TICKS ticks)
{
    ee_u32 whole = (ee_u32)ticks / (ee_u32)CLK_HZ;
    ee_u32 rem   = (ee_u32)ticks % (ee_u32)CLK_HZ;
    /* CLK_HZ/100 is exact for any sane clock and keeps the numerator
     * small; the alternative (rem * 100) overflows above ~43 MHz. */
    print_x100(whole, rem / ((ee_u32)CLK_HZ / 100u));
}

void print_iters_per_sec_x100(ee_u32 iterations, CORE_TICKS ticks)
{
    ee_u32 per_iter = iterations ? (ee_u32)ticks / iterations : 0;
    if (per_iter == 0) {
        print_x100(0, 0);
        return;
    }
    print_x100((ee_u32)CLK_HZ / per_iter,
               (((ee_u32)CLK_HZ % per_iter) * 100u) / per_iter);
}

/* -nostdlib: gcc still emits calls to memcpy/memset for structure copies
 * and array initialisation, so the port has to provide them. */
void *memcpy(void *dst, const void *src, ee_size_t n)
{
    char       *d = (char *)dst;
    const char *s = (const char *)src;
    while (n--) *d++ = *s++;
    return dst;
}

void *memset(void *dst, int c, ee_size_t n)
{
    char *d = (char *)dst;
    while (n--) *d++ = (char)c;
    return dst;
}
