/*
 * Example program for the C -> program.hex flow (rv32imac).
 *
 * Compiled with the prebuilt bare-metal riscv32-esp-elf-gcc at
 * -march=rv32imac -mabi=ilp32 (freestanding, -nostdlib), linked at 0x0
 * (the CPU boot address) by link.ld, then converted to a $readmemh word
 * hex by bin2hex.py for the Verilator sim's RAM preload.
 *
 * The LSU is live (loads/stores retire through the shared imem bus) and
 * the stall-on-RAW interlock covers register and load-use hazards, so a
 * memory-heavy program like quicksort is now a real correctness check:
 * it exercises the fetch / decode / execute path AND the data path (array
 * loads/stores, stack spill/fill from recursion, branches on loaded
 * values). The retire+writeback log (a0 at exit) is the observable
 * result. Zilx indexed loads are NOT emitted by -march=rv32imac (no
 * zilx mnemonics in the assembler), so partition() hand-encodes a
 * scaled word indexed load (lxs.w) via .insn to exercise that path
 * for real here. The hand-crafted sim/program.hex oracle still covers
 * the other Zilx sizes/signs (b/h/w, signed/unsigned) and the unscaled
 * variant; this program only stresses lxs.w.
 *
 * .bss is NOT zeroed at runtime (start.S does not clear it), so keep
 * state in an initialized .data array, not uninitialized globals.
 */

#define N 32

#include "uart.h"

/* Initialized .data array (part of the RAM image, so it lands in memory
 * without needing .bss zeroing). volatile forces a real load/store per
 * access and stops -O2 from constant-folding the whole sort. */
static volatile int arr[N] = {
    10, -8, 3, -15, 12, -1, 6, -13, 0, 9, -4, 14, -7, 11, -2, 5,
    -16, 7, -12, 4, -9, 15, -6, 13, -10, 2, -11, 8, -5, 1, -14, -3
};

/* Zilx (draft) scaled indexed word load: val = *(base + (idx << 2)).
 * Hand-encoded via .insn since -march=rv32imac's assembler has no
 * zilx mnemonics: AMO opcode (0x2f), funct3=010 (word), funct5=11010
 * scaled-indexed mode, aq=rl=0 -> funct7 = 0b1101000 = 0x68.
 */
static inline int lxsw(volatile int *base, int idx)
{
    int val;
    __asm__ volatile (".insn r 0x2f, 0x2, 0x68, %0, %1, %2"
                       : "=r"(val)
                       : "r"(idx), "r"(base)
                       : "memory");
    return val;
}

/* Partition (Lomuto) over arr[lo..hi] with arr[hi] as pivot. */
__attribute__((noinline))
static int partition(int lo, int hi)
{
    int pivot = lxsw(arr, hi);
    int i = lo - 1;
    for (int j = lo; j < hi; j++) {
        int aj = lxsw(arr, j);
        if (aj <= pivot) {
            i++;
            int ai = lxsw(arr, i);
            arr[i] = aj;
            arr[j] = ai;
        }
    }
    int lo_v = lxsw(arr, i + 1);
    int hi_v = lxsw(arr, hi);
    arr[i + 1] = hi_v;
    arr[hi] = lo_v;
    return i + 1;
}

/* Recursive quicksort. Recursion drives stack spill/fill, so this also
 * stresses the LSU's stack path and the RAW interlock on load-use. */
__attribute__((noinline))
static void quicksort(int lo, int hi)
{
    if (lo < hi) {
        int p = partition(lo, hi);
        quicksort(lo, p - 1);
        quicksort(p + 1, hi);
    }
}

int main(void)
{
    quicksort(0, N - 1);

    /* Verify ascending order; return a recognizable marker in a0.
     * 0x600D == sorted, 0x00000BAD == still unsorted (sort broken). */
    int ok = 1;
    for (int i = 1; i < N; i++) {
        if (arr[i - 1] > arr[i])
        {
            ok = 0;
            break;
        }
    }

    if (ok) {
        uart_puts("OK\r\n");
        return 0x600D;
    } else {
        uart_puts("FAIL\r\n");
        return 0x00000BAD;
    }
}