#!/usr/bin/env python3
"""Convert a raw little-endian binary to a $readmemh word file for the
Verilator sim's native_ram / axi4_lite_ram preload (sim_top / u_imem /
u_dmem / u_ram).

The RAM is `logic [31:0] mem[words]`; $readmemh loads one hex word per
line into successive mem[] entries starting at the @ address (the @ is an
ELEMENT index, i.e. a word index, not a byte address). The CPU is
little-endian, so byte 0 of each 4-byte group is mem[i][7:0] -- i.e. each
output line is the 32-bit little-endian word read from the binary.

--pad-words <n> (default 0): emit filler words after the image until <n>
words have been written. Gowin builds an inferred ROM only as deep as its
$readmemh init content, so an unpadded image leaves every fetch above it
either aliasing back into real instructions or reading an unbuilt block --
a wrong redirect then runs silently instead of trapping.

--pad-value <word> (default 0x00100073, ebreak): the filler. It is not
zero on purpose. Zero is a defined illegal encoding and would trap, but a
run of zero words is also what an uninitialised memory looks like, so a
synthesiser is free to treat it as "no init" and shrink the ROM back to
the image -- which is the behaviour being worked around. ebreak is a real
instruction word, so it must be stored, and it raises breakpoint
(mcause=3) rather than illegal-instruction (mcause=2), which tells a
wander into the padding apart from a wander into genuine garbage.

--base <byte_addr> (default 0): the byte address of the first byte in the
binary. The emitted @ is base//4 (the word index). objcopy -j strips
addresses and starts the binary at the lowest VMA of the kept sections, so
for a Harvard image whose first section is not at 0 (e.g. .data at DMEM
ORIGIN 0x2000), pass --base <that VMA> so the words land at the right
D-mem offset instead of word 0.

Usage: bin2hex.py [--base <byte_addr>] [--pad-words <n>]
                  [--pad-value <word>] <in.bin> <out.hex>
"""

import struct
import sys


def main() -> int:
    args = sys.argv[1:]
    base = 0
    pad_words = 0
    pad_value = 0x00100073  # ebreak
    while len(args) >= 2 and args[0] in ("--base", "--pad-words", "--pad-value"):
        if args[0] == "--base":
            base = int(args[1], 0)  # accepts 0x.. and decimal
        elif args[0] == "--pad-words":
            pad_words = int(args[1], 0)
        else:
            pad_value = int(args[1], 0)
        args = args[2:]
    if len(args) != 2:
        sys.stderr.write(
            f"usage: {sys.argv[0]} [--base <byte_addr>] [--pad-words <n>] "
            f"[--pad-value <word>] <in.bin> <out.hex>\n"
        )
        return 2
    in_path, out_path = args

    with open(in_path, "rb") as f:
        data = f.read()

    if base % 4 != 0:
        sys.stderr.write(f"{sys.argv[0]}: --base 0x{base:x} not word-aligned\n")
        return 2

    words = 0
    with open(out_path, "w") as f:
        f.write(f"@{base // 4:08x}\n")
        for i in range(0, len(data), 4):
            word = data[i : i + 4].ljust(4, b"\x00")  # zero-pad the last word
            value = struct.unpack("<I", word)[0]      # little-endian -> u32
            f.write(f"{value:08x}\n")
            words += 1
        if words > pad_words > 0:
            sys.stderr.write(
                f"{sys.argv[0]}: image is {words} words, larger than "
                f"--pad-words {pad_words}\n"
            )
            return 2
        for _ in range(words, pad_words):
            f.write(f"{pad_value:08x}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())