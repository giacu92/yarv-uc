/*
 * Example program for the C -> program.hex flow (rv32imac).
 *
 * Compiled with the prebuilt bare-metal riscv32-esp-elf-gcc at
 * -march=rv32imac -mabi=ilp32 (freestanding, -nostdlib), linked at 0x0
 * (the CPU boot address) by link.ld, then converted to a $readmemh word
 * hex by bin2hex.py for the Verilator sim's RAM preload.
 *
 * It is written to stay in registers as much as possible so it exercises
 * the fetch / decode / execute path (ALU, branches, call/ret) even on the
 * current DRAFT core, which has:
 *   - no LSU yet and no data-memory slave on the peri bus -> memory
 *     accesses (stack spill, globals) silently no-op (stores drop, loads
 *     read 0);
 *   - no forwarding / hazard unit -> a RAW-dependent instruction right
 *     after its producer reads the stale pre-writeback value.
 * So treat the sim retire log as a sequencing / decode smoke test, not a
 * correct-result check, until the LSU and hazard unit land. Add a
 * writeback tap (see CLAUDE.md) to observe actual results.
 */

/* fib is kept out of line + opaque so -O2 actually emits the loop instead
 * of constant-folding fib(10) to a single `li`. The empty asm makes `n`
 * opaque to the optimizer without touching memory. */
__attribute__((noinline))
static int fib(int n)
{
    int a = 0, b = 1;
    for (int i = 2; i <= n; i++) {
        int t = a + b;
        a = b;
        b = t;
    }
    return b;
}

int main(void)
{
    int n;
    __asm__ volatile ("" : "=r"(n) : "0"(20));   /* n = 20, opaque to -O2 */
    return fib(n);  // Expect 6765 (0x1A6D) to be returned in a0 */
}