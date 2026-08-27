/* RVC spanning-bubble removal oracle for the target_span_complete path.
 *
 * No existing oracle/cosim places a 32-bit instruction at a 2-byte-aligned
 * branch target (offset 2 or 6 of an 8-byte fetch word), so the same-cycle
 * stitch path (decode consumes head[31:16] + head+1[15:0] in one cycle, pops
 * 2, re-stashes head+1[31:16]) was unguarded. A broken stitch would reassemble
 * the 32-bit word from the wrong halfword boundary and decode garbage.
 *
 * Each case branches (c.j) to a 32-bit (or compressed) instruction sitting at
 * offset 2 / offset 6 of an 8-byte-aligned block, runs it, jumps back, and
 * self-checks the architectural result. A mtvec handler catches a mis-decoded
 * jump/illegal as FAIL (writes 0xBAD, parks) instead of a hang. Pass marker:
 * 0x600D at D-mem 0x2000 (= sim probe word 0x800).
 *
 * Cases (offset = byte offset within the 8-byte fetch word):
 *   1  offset 2, 32-bit addi  (I-type)  -- target_span_complete, 0 bubble
 *   2  offset 6, 32-bit addi  (I-type)  -- target_span_wait then span_complete
 *   3  offset 2, 32-bit lui   (U-type)  -- target_span_complete, 0 bubble
 *   4  offset 2, compressed c.addi      -- target_upper && !target_span (regression)
 *   5  offset 6, compressed c.addi      -- target_upper && !target_span (regression)
 *
 * The 32-bit instrs use distinctive per-case immediates so a half-word-swap
 * stitch shows up as the wrong a0 value (caught by CHECK -> bad), or an
 * illegal opcode (caught by trap_handler -> bad). Compressed targets set
 * a0=0 first since c.addi is rd = rd + imm (rs1 = rd).
 */

    .section .text.init, "ax"

    # CHECK reg, expect : li t1, expect ; bne reg, t1, bad
    .macro  CHECK reg, expect
    li      t1, \expect
    bne     \reg, t1, bad
    .endm

    .globl _start
_start:
    li      sp, 0x2000              # data base / pass-marker address
    la      t0, trap_handler
    csrw    mtvec, t0

    # ===== Case 1: offset-2 target, 32-bit addi a0,x0,0x123 =====
    c.j     o2_addi
cont1:
    CHECK   a0, 0x123

    # ===== Case 2: offset-6 target, 32-bit addi a0,x0,0x456 =====
    c.j     o6_addi
cont2:
    CHECK   a0, 0x456

    # ===== Case 3: offset-2 target, 32-bit lui a0,0x12345 =====
    c.j     o2_lui
cont3:
    CHECK   a0, 0x12345000

    # ===== Case 4: offset-2 target, compressed c.addi a0,0x7 =====
    li      a0, 0                   # c.addi is rd=rd+imm; start from 0
    c.j     o2_c
cont4:
    CHECK   a0, 0x7

    # ===== Case 5: offset-6 target, compressed c.addi a0,0x9 =====
    li      a0, 0
    c.j     o6_c
cont5:
    CHECK   a0, 0x9

    # ===== all checks passed =====
    li      t0, 0x2000
    li      t1, 0x600D
    sw      t1, 0(t0)
park:
    j       park

bad:
    li      t0, 0x2000
    li      t1, 0xBAD
    sw      t1, 0(t0)
badpark:
    j       badpark

trap_handler:
    li      t0, 0x2000
    li      t1, 0xBAD
    sw      t1, 0(t0)
th_park:
    j       th_park

    # ===== Test blocks (8-byte aligned; target at offset 2 / 6) =====

    .balign 8
o2_blk:                         # bytes 0-7 of the fetch word
    c.nop                        # offset 0  (branched over)
o2_addi:                        # offset 2  (32-bit instr under test)
    addi    a0, x0, 0x123
    c.j     cont1                # offset 6

    .balign 8
o6_blk:
    c.nop                        # offset 0  (branched over)
    c.nop                        # offset 2  (branched over)
    c.nop                        # offset 4  (branched over)
o6_addi:                        # offset 6  (32-bit instr under test)
    addi    a0, x0, 0x456
    c.j     cont2                # offset 10

    .balign 8
o2_lui_blk:
    c.nop                        # offset 0  (branched over)
o2_lui:                         # offset 2  (32-bit instr under test)
    lui     a0, 0x12345
    c.j     cont3                # offset 6

    .balign 8
o2c_blk:
    c.nop                        # offset 0  (branched over)
o2_c:                           # offset 2  (compressed target)
    c.addi  a0, 0x7
    c.j     cont4                # offset 4

    .balign 8
o6c_blk:
    c.nop                        # offset 0  (branched over)
    c.nop                        # offset 2  (branched over)
    c.nop                        # offset 4  (branched over)
o6_c:                           # offset 6  (compressed target)
    c.addi  a0, 0x9
    c.j     cont5                # offset 8