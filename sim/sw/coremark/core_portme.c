#include "coremark.h"

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
}

void portable_fini(core_portable *p) { p->portable_id = 0; }

void start_time(void) { start_ticks = rdcycle(); }
void stop_time(void) { stop_ticks = rdcycle(); }

CORE_TICKS get_time(void) { return stop_ticks - start_ticks; }

/* HAS_FLOAT=0, so secs_ret is an integer: whole seconds at the core clock.
 * A short simulation run reports 0 here; the cycle count is the number to
 * read. CLK_HZ is set by the Makefile and must track the build's clock. */
secs_ret time_in_secs(CORE_TICKS ticks) { return (secs_ret)(ticks / CLK_HZ); }

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
