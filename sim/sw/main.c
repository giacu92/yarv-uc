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
 * result. Zilx indexed loads are NOT emitted by -march=rv32imac; they
 * stay covered by the hand-crafted sim/program.hex oracle.
 *
 * .bss is NOT zeroed at runtime (start.S does not clear it), so keep
 * state in an initialized .data array, not uninitialized globals.
 */

#define N 16

/* Initialized .data array (part of the RAM image, so it lands in memory
 * without needing .bss zeroing). volatile forces a real load/store per
 * access and stops -O2 from constant-folding the whole sort. */
static volatile int arr[N] = {
    5, 14, 2, 11, 9, 1, 7, 12, 3, 8, 15, 4, 13, 6, 0, 10,
};

/* Partition (Lomuto) over arr[lo..hi] with arr[hi] as pivot. */
__attribute__((noinline))
static int partition(int lo, int hi)
{
    int pivot = arr[hi];
    int i = lo - 1;
    for (int j = lo; j < hi; j++) {
        if (arr[j] <= pivot) {
            i++;
            int t = arr[i];
            arr[i] = arr[j];
            arr[j] = t;
        }
    }
    int t = arr[i + 1];
    arr[i + 1] = arr[hi];
    arr[hi] = t;
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
    for (int i = 1; i < N; i++) {
        if (arr[i - 1] > arr[i])
            return 0x00000BAD;
    }
    return 0x600D;
}