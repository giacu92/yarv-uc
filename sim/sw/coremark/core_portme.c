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

/* ------------------------------------------------------------------
 * Trap reporter.
 *
 * Neither start.S nor this port used to install an mtvec, so mtvec kept
 * its reset value of 0 -- which on this Harvard split is _start. Any
 * exception therefore re-entered the program from the top and reprinted
 * the banner, and a fault inside the timed loop looked like the board
 * rebooting in a loop with no other symptom. That is exactly what a
 * 2026-09-01 board run showed: banner, "running...", banner, forever.
 *
 * The handler exists to make that self-reporting: it prints mcause /
 * mepc / mtval and parks, so one board run names the fault and the PC
 * instead of leaving the restart to be guessed at. It is diagnostic, not
 * a recovery path -- it deliberately does NOT mret, because returning to
 * a faulting instruction would just re-trap and returning past it would
 * hide the problem.
 *
 * Aligned 4-byte, direct mode (mtvec MODE=00 needs BASE[1:0]=00).
 * __attribute__((naked)): no prologue may run before mepc is read, and
 * the handler never returns, so it needs no frame at all.
 * ------------------------------------------------------------------ */
static void __attribute__((naked, aligned(4))) trap_report(void)
{
    __asm__ volatile(
        "csrr a0, mcause\n"
        "csrr a1, mepc\n"
        "csrr a2, mtval\n"
        "j    trap_report_c\n");
}

void trap_report_c(ee_u32 mcause, ee_u32 mepc, ee_u32 mtval);
void trap_report_c(ee_u32 mcause, ee_u32 mepc, ee_u32 mtval)
{
    printf("\n  *** TRAP  mcause=0x%08x mepc=0x%08x mtval=0x%08x\n",
           (unsigned)mcause, (unsigned)mepc, (unsigned)mtval);
    printf("  (4/6 = load/store misaligned, 2 = illegal, 1 = instr access, "
           "5/7 = load/store access)\n");
    printf("  parked.\n");
    for (;;) {
    }
}

void portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc;
    (void)argv;
    p->portable_id = 1;

#if !COSIM
    /* Install the trap reporter before anything else can fault.
     *
     * NOT in the co-sim build. There, Spike has no UART / CLINT / MSIP, so the
     * first MMIO access is an access fault on its side and a normal store on
     * the core's -- the documented end of comparability. With mtvec at its
     * reset value of 0 both sides stop being compared there and cosim_diff
     * reports a clean PASS. With a handler installed, Spike instead VECTORS
     * into it and keeps executing (mcause=5 into a0), so the divergence shows
     * up as a control-flow MISMATCH at that same retire instead of a stop:
     *   spike: pc 0x28 x10 = 0x5   rtl: pc 0x1c0 x14 = 0x1
     * Same event, worse diagnosis. The reporter is a board instrument; the
     * co-sim build has no board and no UART to report on. */
    __asm__ volatile("csrw mtvec, %0" : : "r"(&trap_report));
#endif

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

void portable_fini(core_portable *p)
{
    p->portable_id = 0;
#if !COSIM
    report_port_summary();
#endif
}

void start_time(void) { start_ticks = rdcycle(); }
void stop_time(void) { stop_ticks = rdcycle(); }

CORE_TICKS get_time(void) { return stop_ticks - start_ticks; }

/* HAS_FLOAT=0, so secs_ret is an integer: whole seconds at the core clock.
 * A short simulation run reports 0 here; the cycle count is the number to
 * read. CLK_HZ is set by the Makefile and must track the build's clock. */
secs_ret time_in_secs(CORE_TICKS ticks) { return (secs_ret)(ticks / CLK_HZ); }

/* Two decimals, computed by dividing before scaling so nothing overflows
 * 32 bits: ticks can reach 2^32-1 and multiplying that by 100 would not
 * fit. CLK_HZ/100 is exact for any sane clock. */
static void print_x100(ee_u32 whole, ee_u32 hundredths)
{
    printf("%u.%02u", (unsigned)whole, (unsigned)hundredths);
}

void report_port_summary(void)
{
    CORE_TICKS ticks = get_time();
    ee_u32     iters = (ee_u32)ITERATIONS;

    printf("\n");
    printf("  Ticks (core cycles) : %u\n", (unsigned)ticks);

    if (ticks == 0 || iters == 0) return;

    ee_u32 per_iter = ticks / iters;

    printf("  Cycles / iteration  : %u\n", (unsigned)per_iter);

    printf("  Total time (secs)   : ");
    print_x100((ee_u32)ticks / (ee_u32)CLK_HZ,
               ((ee_u32)ticks % (ee_u32)CLK_HZ) / ((ee_u32)CLK_HZ / 100u));
    printf("\n");

    if (per_iter) {
        printf("  Iterations / sec    : ");
        print_x100((ee_u32)CLK_HZ / per_iter,
                   (((ee_u32)CLK_HZ % per_iter) * 100u) / per_iter);
        printf("\n");

        /* CoreMark/MHz: iterations per second divided by MHz, which with
         * ticks measured in core cycles is just 1e6 / cycles-per-iteration
         * -- no clock frequency involved, so this figure holds whatever
         * CLK_HZ is set to. */
        ee_u32 score100 = 100000000UL / per_iter;
        printf("  CoreMark / MHz      : ");
        print_x100(score100 / 100u, score100 % 100u);
        printf("\n");
    }

    /* CoreMark's run rules require at least 10 s of run time. Upstream
     * already prints its own ERROR line and counts an error when the run
     * is shorter; this says what to do about it. */
    if ((ee_u32)ticks / (ee_u32)CLK_HZ < 10u)
        printf("  (short run: not a reportable score -- raise ITERATIONS)\n");
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
