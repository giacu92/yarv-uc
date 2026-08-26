#!/usr/bin/env python3
"""Convert a raw little-endian binary to a $readmemh word file for the
Verilator sim's native_ram / axi4_lite_ram preload (sim_top / u_imem /
u_dmem / u_ram).

The RAM is `logic [W*8-1:0] mem[words]`; $readmemh loads one hex word per
line into successive mem[] entries starting at the @ address (the @ is an
ELEMENT index, i.e. a word index, not a byte address). The CPU is
little-endian, so byte 0 of each W-byte group is mem[i][7:0] -- i.e. each
output line is the W-byte little-endian word read from the binary.

--word-width <bytes> (default 4): the $readmemh element width in bytes.
4 -> 32-bit words (`%08x`, `@base//4`); 8 -> 64-bit words (`%016x`,
`@base//8`), used by the widened I-mem fetch (one 8-byte access delivers two
32-bit instructions: the low 32 bits are the first word at a byte address,
the high 32 bits the next +4). The D-mem stays 32-bit.

--pad-words <n> (default 0): emit filler words after the image until <n>
words have been written. Gowin builds an inferred ROM only as deep as its
$readmemh init content, so an unpadded image leaves every fetch above it
either aliasing back into real instructions or reading an unbuilt block --
a wrong redirect then runs silently instead of trapping.

--pad-value <word> (default 0x00100073, ebreak): the filler, given as a
32-bit value. For word widths wider than 4 it is REPLICATED across the
element (so a 64-bit element gets (pad<<32)|pad) -- existing Makefile
IMEM_PAD_VALUE values (32-bit) need no edit. It is not zero on purpose.
Zero is a defined illegal encoding and would trap, but a run of zero words
is also what an uninitialised memory looks like, so a synthesiser is free
to treat it as "no init" and shrink the ROM back to the image -- which is
the behaviour being worked around. ebreak is a real instruction word, so
it must be stored, and it raises breakpoint (mcause=3) rather than
illegal-instruction (mcause=2), which tells a wander into the padding apart
from a wander into genuine garbage.

--base <byte_addr> (default 0): the byte address of the first byte in the
binary. The emitted @ is base//word_width (the element index). objcopy -j
strips addresses and starts the binary at the lowest VMA of the kept
sections, so for a Harvard image whose first section is not at 0 (e.g.
.data at DMEM ORIGIN 0x2000), pass --base <that VMA> so the words land at
the right D-mem offset instead of word 0.

Usage: bin2hex.py [--base <byte_addr>] [--pad-words <n>]
                  [--pad-value <word>] [--word-width <bytes>]
                  <in.bin> <out.hex>
"""

import struct
import sys


# struct format + printf width per supported element width (bytes).
_FMT = {4: "<I", 8: "<Q"}
_HEX = {4: "08x", 8: "016x"}


def main() -> int:
    args = sys.argv[1:]
    base = 0
    pad_words = 0
    pad_value = 0x00100073  # ebreak (32-bit, replicated for wider elements)
    word_width = 4
    while len(args) >= 2 and args[0] in (
        "--base",
        "--pad-words",
        "--pad-value",
        "--word-width",
    ):
        if args[0] == "--base":
            base = int(args[1], 0)  # accepts 0x.. and decimal
        elif args[0] == "--pad-words":
            pad_words = int(args[1], 0)
        elif args[0] == "--pad-value":
            pad_value = int(args[1], 0)
        else:
            word_width = int(args[1], 0)
        args = args[2:]
    if len(args) != 2:
        sys.stderr.write(
            f"usage: {sys.argv[0]} [--base <byte_addr>] [--pad-words <n>] "
            f"[--pad-value <word>] [--word-width <bytes>] "
            f"<in.bin> <out.hex>\n"
        )
        return 2
    in_path, out_path = args

    if word_width not in _FMT:
        sys.stderr.write(
            f"{sys.argv[0]}: --word-width {word_width} unsupported "
            f"(one of {sorted(_FMT)})\n"
        )
        return 2
    if base % word_width != 0:
        sys.stderr.write(
            f"{sys.argv[0]}: --base 0x{base:x} not {word_width}-byte-aligned\n"
        )
        return 2

    # Replicate the 32-bit pad value across the element width (e.g. a
    # 64-bit element gets (pad<<32)|pad). Assumes word_width is a multiple
    # of 4, which _FMT guarantees.
    pad_w = 0
    for off in range(0, word_width, 4):
        pad_w |= (pad_value & 0xFFFFFFFF) << (8 * off)

    fmt = _FMT[word_width]
    hexw = _HEX[word_width]

    with open(in_path, "rb") as f:
        data = f.read()

    words = 0
    with open(out_path, "w") as f:
        f.write(f"@{base // word_width:08x}\n")
        for i in range(0, len(data), word_width):
            word = data[i : i + word_width].ljust(word_width, b"\x00")
            value = struct.unpack(fmt, word)[0]  # little-endian -> unsigned
            f.write(f"{value:{hexw}}\n")
            words += 1
        if words > pad_words > 0:
            sys.stderr.write(
                f"{sys.argv[0]}: image is {words} words, larger than "
                f"--pad-words {pad_words}\n"
            )
            return 2
        for _ in range(words, pad_words):
            f.write(f"{pad_w:{hexw}}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())