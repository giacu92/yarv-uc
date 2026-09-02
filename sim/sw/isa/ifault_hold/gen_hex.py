#!/usr/bin/env python3
"""Oracle: an instruction access fault must not swallow a stashed RVC half.

Decode's hold buffer stashes the upper half of a fetch word whose low half
was a compressed instruction, and decodes it on the following cycle. If the
buffer entry that arrives on that following cycle is an instruction access
fault (the PC ran past the end of the implemented I-mem), the stashed half
is a COMPLETE instruction that is OLDER than the faulting PC -- it has to
retire before the trap, or the trap is imprecise and one instruction has
silently vanished from the retire stream.

Decode used to give the fault entry priority over every other source,
including that stash, so the instruction was dropped. This program puts the
case at the only address where it can happen: the last two 4-byte words of
a 16 KiB I-mem, four compressed instructions, then a PC that is off the end
of the memory.

    0x3ff8  c.li a0, 1     <- low half of word W0, decoded, upper half stashed
    0x3ffa  c.li a1, 2     <- the stash, decoded next cycle
    0x3ffc  c.li a2, 3     <- low half of word W1, decoded, upper half stashed
    0x3ffe  c.li a3, 4     <- the stash whose next entry is the fault
    0x4000                 <- outside the I-mem: instruction access fault

a3 is the instruction the bug dropped, so a3 == 4 in the handler is the
whole test; mcause == 1 and mtval == 0x4000 check that the trap that does
arrive is still the right one, reported against the right PC.

The handler parks instead of returning: mepc is 0x4000, which by
construction cannot be fetched.

Toolchain-free by design -- the program IS its placement at the top of the
I-mem, which is expressed here directly rather than through a link script.
Emits build/imem.hex (64-bit $readmemh elements, 8 bytes per line) and
build/dmem.hex. Result word: 0x600D / 0xBAD at 0x2000.
"""
import os
import sys

X = {"x0": 0, "sp": 2, "t0": 5, "t1": 6, "t2": 7,
     "a0": 10, "a1": 11, "a2": 12, "a3": 13}
CSR = {"mtvec": 0x305, "mepc": 0x341, "mcause": 0x342, "mtval": 0x343}

IMEM_BYTES = 1 << 14  # must match sim_top's u_imem ADDR_W
EDGE = IMEM_BYTES - 8  # 0x3ff8: the last 8-byte fetch word
RESULT_ADDR = 0x2000


def _u(v, n):
    return v & ((1 << n) - 1)


def i_type(imm, rs1, f3, rd, op):
    return (_u(imm, 12) << 20) | (_u(rs1, 5) << 15) | (_u(f3, 3) << 12) \
        | (_u(rd, 5) << 7) | _u(op, 7)


def s_type(imm, rs2, rs1, f3, op):
    return (_u(imm >> 5, 7) << 25) | (_u(rs2, 5) << 20) | (_u(rs1, 5) << 15) \
        | (_u(f3, 3) << 12) | (_u(imm, 5) << 7) | _u(op, 7)


def b_type(imm, rs2, rs1, f3, op):
    return (((imm >> 12) & 1) << 31) | (_u(imm >> 5, 6) << 25) \
        | (_u(rs2, 5) << 20) | (_u(rs1, 5) << 15) | (_u(f3, 3) << 12) \
        | (_u(imm >> 1, 4) << 8) | (((imm >> 11) & 1) << 7) | _u(op, 7)


def j_type(imm, rd, op):
    return (((imm >> 20) & 1) << 31) | (_u(imm >> 1, 10) << 21) \
        | (((imm >> 11) & 1) << 20) | (_u(imm >> 12, 8) << 12) \
        | (_u(rd, 5) << 7) | _u(op, 7)


def lui(rd, imm20):
    return (_u(imm20, 20) << 12) | (_u(rd, 5) << 7) | 0x37


def addi(rd, rs1, imm):
    return i_type(imm, rs1, 0b000, rd, 0x13)


def sw(rs2, off, rs1):
    return s_type(off, rs2, rs1, 0b010, 0x23)


def bne(rs1, rs2, off):
    return b_type(off, rs2, rs1, 0b001, 0x63)


def jal(rd, off):
    return j_type(off, rd, 0x6F)


def csrrw(rd, csr, rs1):
    return i_type(csr, rs1, 0b001, rd, 0x73)


def csrrs(rd, csr, rs1):
    return i_type(csr, rs1, 0b010, rd, 0x73)


# li rd, imm32 -> always two words (lui+addi) so instruction addresses do
# not shift between the sizing pass and the emit pass.
def li(rd, imm):
    imm &= 0xFFFFFFFF
    hi = (imm + 0x800) >> 12
    lo = imm - (_u(hi, 20) << 12)
    lo = ((lo + 0x800) & 0xFFF) - 0x800  # sign-extend to 12 bits
    return [lui(rd, hi), addi(rd, rd, lo)]


def c_li(rd, imm):
    """c.li rd, imm6 -> 010 imm[5] rd[4:0] imm[4:0] 01 (rd != x0)."""
    assert rd != 0 and -32 <= imm < 32
    return (0b010 << 13) | (((imm >> 5) & 1) << 12) | (_u(rd, 5) << 7) \
        | (_u(imm, 5) << 2) | 0b01


# The four compressed instructions at the top of the I-mem, in address
# order 0x3ff8 / 0x3ffa / 0x3ffc / 0x3ffe.
EDGE_HALVES = [c_li(X["a0"], 1), c_li(X["a1"], 2),
               c_li(X["a2"], 3), c_li(X["a3"], 4)]

# (label, mnemonic, args) for the head of the image, at address 0.
PROG = [
    ("_start",       "li",   ("sp", 0x4000)),
    (None,           "li",   ("t0", "trap_handler")),
    (None,           "csrw", ("mtvec", "t0")),
    # Clear the four destinations so "was it written" is a real question.
    (None,           "li",   ("a0", 0)),
    (None,           "li",   ("a1", 0)),
    (None,           "li",   ("a2", 0)),
    (None,           "li",   ("a3", 0)),
    (None,           "jabs", (EDGE,)),

    ("trap_handler", "csrr", ("t1", "mcause")),
    (None,           "li",   ("t2", 1)),  # MCAUSE_INSTR_ACC
    (None,           "bne",  ("t1", "t2", "bad")),
    (None,           "csrr", ("t1", "mtval")),
    (None,           "li",   ("t2", IMEM_BYTES)),  # the unfetchable PC
    (None,           "bne",  ("t1", "t2", "bad")),
    (None,           "li",   ("t2", 1)),
    (None,           "bne",  ("a0", "t2", "bad")),
    (None,           "li",   ("t2", 2)),
    (None,           "bne",  ("a1", "t2", "bad")),
    (None,           "li",   ("t2", 3)),
    (None,           "bne",  ("a2", "t2", "bad")),
    # The instruction the fault used to swallow.
    (None,           "li",   ("t2", 4)),
    (None,           "bne",  ("a3", "t2", "bad")),
    (None,           "li",   ("t0", RESULT_ADDR)),
    (None,           "li",   ("t1", 0x600D)),
    (None,           "sw",   ("t1", 0, "t0")),
    (None,           "j",    ("park",)),
    ("bad",          "li",   ("t0", RESULT_ADDR)),
    (None,           "li",   ("t1", 0xBAD)),
    (None,           "sw",   ("t1", 0, "t0")),
    # mepc is the unfetchable PC, so there is nothing to mret to: park.
    ("park",         "j",    ("park",)),
]

SIZE = {"li": 2}  # every other mnemonic is one word


def assemble():
    labels, pc = {}, 0
    for label, mn, _ in PROG:
        if label:
            labels[label] = pc
        pc += 4 * SIZE.get(mn, 1)

    words, pc = [], 0
    for _, mn, a in PROG:
        if mn == "li":
            imm = labels[a[1]] if isinstance(a[1], str) else a[1]
            out = li(X[a[0]], imm)
        elif mn == "sw":
            out = [sw(X[a[0]], a[1], X[a[2]])]
        elif mn == "bne":
            out = [bne(X[a[0]], X[a[1]], labels[a[2]] - pc)]
        elif mn == "j":
            out = [jal(0, labels[a[0]] - pc)]
        elif mn == "jabs":
            out = [jal(0, a[0] - pc)]
        elif mn == "csrw":
            out = [csrrw(0, CSR[a[0]], X[a[1]])]
        elif mn == "csrr":
            out = [csrrs(X[a[0]], CSR[a[1]], 0)]
        else:
            raise SystemExit("unknown mnemonic: " + mn)
        words += out
        pc += 4 * len(out)
    return labels, words


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "build"
    os.makedirs(out_dir, exist_ok=True)
    labels, words = assemble()
    if 4 * len(words) > EDGE:
        raise SystemExit("head image overruns the edge block")

    with open(os.path.join(out_dir, "imem.hex"), "w") as f:
        # 64-bit $readmemh elements (the I-mem fetch port is 8 bytes wide):
        # two 32-bit words per line, low 32 bits = the word at the byte
        # address, high 32 bits = the next (+4). @N is an ELEMENT index, so
        # byte address N*8.
        f.write("@00000000\n")
        f.write("// instruction-access-fault vs stashed RVC half oracle --\n")
        f.write("// generated by gen_hex.py (see its docstring).\n")
        for name, addr in sorted(labels.items(), key=lambda kv: kv[1]):
            f.write("// %-14s 0x%08x\n" % (name, addr))
        padded = words + [0] if len(words) % 2 else words
        for i in range(0, len(padded), 2):
            f.write("%016x\n" % ((padded[i + 1] << 32) | padded[i]))

        # The edge block: the last fetch word of the I-mem, four compressed
        # instructions, with nothing fetchable behind it.
        f.write("\n@%08x\n" % (EDGE // 8))
        f.write("// 0x%08x: c.li a0,1 / c.li a1,2 / c.li a2,3 / c.li a3,4\n" % EDGE)
        f.write("// 0x%08x: off the end of the I-mem -> access fault\n" % IMEM_BYTES)
        w0 = (EDGE_HALVES[1] << 16) | EDGE_HALVES[0]
        w1 = (EDGE_HALVES[3] << 16) | EDGE_HALVES[2]
        f.write("%016x\n" % ((w1 << 32) | w0))

    with open(os.path.join(out_dir, "dmem.hex"), "w") as f:
        f.write("@%08x\n" % (RESULT_ADDR // 4))
        f.write("// Placeholder for the result word the handler writes.\n")
        f.write("00000000\n")

    print("wrote %s/imem.hex (%d head words + 1 edge block), %s/dmem.hex"
          % (out_dir, len(words), out_dir))
    for name, addr in sorted(labels.items(), key=lambda kv: kv[1]):
        print("  %-14s 0x%08x" % (name, addr))
    print("  %-14s 0x%08x" % ("edge", EDGE))


if __name__ == "__main__":
    main()
