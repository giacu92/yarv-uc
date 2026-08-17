#!/usr/bin/env python3
"""Convert a raw little-endian binary to a $readmemh word file for the
Verilator sim's axi4_lite_ram preload (sim_top / u_ram).

The RAM is `logic [31:0] mem[words]`; $readmemh loads one hex word per
line into successive mem[] entries starting at the @ address. The CPU is
little-endian, so byte 0 of each 4-byte group is mem[i][7:0] -- i.e. each
output line is the 32-bit little-endian word read from the binary.

Usage: bin2hex.py <in.bin> <out.hex>
"""

import struct
import sys


def main() -> int:
    if len(sys.argv) != 3:
        sys.stderr.write(f"usage: {sys.argv[0]} <in.bin> <out.hex>\n")
        return 2
    in_path, out_path = sys.argv[1], sys.argv[2]

    with open(in_path, "rb") as f:
        data = f.read()

    with open(out_path, "w") as f:
        f.write("@00000000\n")
        for i in range(0, len(data), 4):
            word = data[i : i + 4].ljust(4, b"\x00")  # zero-pad the last word
            value = struct.unpack("<I", word)[0]      # little-endian -> u32
            f.write(f"{value:08x}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())