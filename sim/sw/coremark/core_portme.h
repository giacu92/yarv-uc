/*
 * CoreMark port layer for this core (yarv-uc, RV32IMAC + Zicsr, Harvard).
 *
 * Freestanding: no libc, no newlib, no malloc, no float printing.
 *   - MEM_METHOD = MEM_STATIC  : the 2000-byte work block is a .bss array,
 *                                which the D-mem can hold; malloc does not
 *                                exist here and MEM_STACK would put 2 KiB
 *                                on a stack that has ~5 KiB to itself.
 *   - HAS_FLOAT  = 0           : no FPU and no soft-float printf; the run
 *                                reports raw cycles instead of a score.
 *   - HAS_STDIO  = 0           : ee_printf resolves to the local printf()
 *                                in ee_printf.c (UART, integer formats).
 *   - CORE_TICKS = mcycle      : 32 bits only, this core implements no
 *                                mcycleh, so a run must stay under 2^32
 *                                cycles (107 s at 40 MHz).
 */

#include <stddef.h>

typedef signed short      ee_s16;
typedef unsigned short    ee_u16;
typedef signed int        ee_s32;
typedef double            ee_f32;
typedef unsigned char     ee_u8;
typedef unsigned int      ee_u32;
typedef ee_u32            ee_ptr_int;
typedef size_t            ee_size_t;

typedef ee_u32 CORE_TICKS;

#define MEM_METHOD MEM_STATIC

typedef struct CORE_PORTABLE_S
{
    ee_u8 portable_id;
} core_portable;

#define MULTITHREAD 1
#define USE_PTHREAD 0
#define USE_FORK    0
#define USE_SOCKET  0

#define COMPILER_VERSION  "GCC" __VERSION__
#ifndef COMPILER_FLAGS
#define COMPILER_FLAGS    "-O2 -march=rv32imac_zicsr_zifencei -mabi=ilp32"
#endif
#define MEM_LOCATION      "BSRAM"
#define SC_MEM_LOCATION   "STATIC(BSRAM) RATIOS:1"

#define SEED_METHOD SEED_VOLATILE
#define HAS_FLOAT   0
#define HAS_STDIO   0
#ifndef HAS_PRINTF
#define HAS_PRINTF  1
#endif
#define HAS_TIME_H  0
#define USE_CLOCK   0

#define align_mem(x) (void *)(4 + (((ee_ptr_int)(x)-1) & ~3))

#define CORETIMETYPE ee_u32

extern ee_u32 default_num_contexts;

void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);

/* coremark.h does `#define ee_printf printf` when HAS_PRINTF, so the port
 * has to supply a function actually called printf. ee_printf.c does. */
int printf(const char *fmt, ...);

/* Report helpers, used by the two lines in coremark_main.c that print a
 * duration and a rate. With HAS_FLOAT=0 those are integer divisions, and a
 * run of a few tens of seconds prints "32" and "62" -- one significant
 * figure at the exact place the result is read off. These print hundredths
 * from the raw tick count instead, in 32-bit arithmetic. */
void print_secs_x100(CORE_TICKS ticks);
void print_iters_per_sec_x100(ee_u32 iterations, CORE_TICKS ticks);
