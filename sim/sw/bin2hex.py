#!/usr/bin/env python3
"""Convert a raw little-endian binary to a $readmemh word file for the
Verilator sim's native_ram / axi4_lite_ram preload (sim_top / u_imem /
u_dmem / u_ram).

The RAM is `logic [31:0] mem[words]`; $readmemh loads one hex word per
line into successive mem[] entries starting at the @ address (the @ is an
ELEMENT index, i.e. a word index, not a byte address). The CPU is
little-endian, so byte 0 of each 4-byte group is mem[i][7:0] -- i.e. each
output line is the 32-bit little-endian word read from the binary.

--base <byte_addr> (default 0): the byte address of the first byte in the
binary. The emitted @ is base//4 (the word index). objcopy -j strips
addresses and starts the binary at the lowest VMA of the kept sections, so
for a Harvard image whose first section is not at 0 (e.g. .data at DMEM
ORIGIN 0x2000), pass --base <that VMA> so the words land at the right
D-mem offset instead of word 0.

Usage: bin2hex.py [--base <byte_addr>] <in.bin> <out.hex>
"""

import struct
import sys


def main() -> int:
    args = sys.argv[1:]
    base = 0
    if len(args) >= 2 and args[0] == "--base":
        s = args[1]
        base = int(s, 0)  # accepts 0x.. and decimal
        args = args[2:]
    if len(args) != 2:
        sys.stderr.write(f"usage: {sys.argv[0]} [--base <byte_addr>] <in.bin> <out.hex>\n")
        return 2
    in_path, out_path = args

    with open(in_path, "rb") as f:
        data = f.read()

    if base % 4 != 0:
        sys.stderr.write(f"{sys.argv[0]}: --base 0x{base:x} not word-aligned\n")
        return 2

    with open(out_path, "w") as f:
        f.write(f"@{base // 4:08x}\n")
        for i in range(0, len(data), 4):
            word = data[i : i + 4].ljust(4, b"\x00")  # zero-pad the last word
            value = struct.unpack("<I", word)[0]      # little-endian -> u32
            f.write(f"{value:08x}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())