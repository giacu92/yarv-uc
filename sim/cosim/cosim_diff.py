#!/usr/bin/env python3
# Co-sim differential driver: compares the RTL per-retire commit log
# (emitted by sim_main.cpp when RTL_TRACE=<path> is set) against Spike's
# --log-commits output, retire by retire.
#
# RTL trace line:  "0x<pc> x<rd> 0x<rd_value>"   (rd=0 / value=0 when the
#                   retire writes no register, e.g. store / branch / NOP)
# Spike commit line (RV32, to stderr):
#   "core   0: 3 0x<pc> (0x<instr>)  x<rd> 0x<rd_value> [mem 0x.. [0x..]]"
#   - priv digit after "core N:" then pc, then "(instr)", then reg deltas
#     (" x<rd> 0x<val>" for an integer reg write) and optional " mem ..." for
#     load/store addresses. We extract only the integer reg write.
#
# Two alignment concerns:
#  1. Spike inserts a 5-instruction boot-ROM stub at 0x1000 (auipc/addi a1,
#     csrr a0,mhartid / lw t0 / jr t0) that jumps to the ELF entry (0x0).
#     The RTL boots directly at 0x0, so we skip Spike retires until the first
#     pc == ENTRY (default 0x0), then align 1:1. The stub sets a0/a1 which the
#     program ignores, and clobbers t0 which the program overwrites, so
#     skipping it is arch-equivalent.
#  2. Both sides end in a `1: j 1b` self-loop. We detect the park as PARK_N
#     (8) consecutive identical PCs at the tail and compare up to and
#     including the first occurrence of the loop instruction, then require
#     the park PC to match on both sides.
#
# Exit 0 on full match, 1 on first mismatch / alignment failure.
import argparse
import re
import sys

PARK_N = 8

RTL_RE = re.compile(r"^0x([0-9a-fA-F]+)\s+x(\d+)\s+0x([0-9a-fA-F]+)\s*$")
SPIKE_RE = re.compile(
    r"^core\s+\d+:\s+\d+\s+0x([0-9a-fA-F]+)\s+\(0x[0-9a-fA-F]+\)(.*)$"
)
SPIKE_REG_RE = re.compile(r"\sx(\d+)\s+0x([0-9a-fA-F]+)")


def parse_rtl(path):
    out = []
    with open(path) as f:
        for line in f:
            m = RTL_RE.match(line.strip())
            if not m:
                continue
            pc = int(m.group(1), 16)
            rd = int(m.group(2))
            val = int(m.group(3), 16)
            out.append((pc, rd, val))
    return out


def parse_spike(path):
    out = []
    with open(path) as f:
        for line in f:
            m = SPIKE_RE.match(line.rstrip("\n"))
            if not m:
                continue
            pc = int(m.group(1), 16)
            rest = m.group(2)
            rm = SPIKE_REG_RE.search(rest)
            if rm:
                rd = int(rm.group(1))
                val = int(rm.group(2), 16)
            else:
                rd, val = 0, 0
            out.append((pc, rd, val))
    return out


def find_park(retires):
    """Index of the first of PARK_N consecutive identical PCs, or None."""
    n = len(retires)
    for i in range(n - PARK_N + 1):
        pc = retires[i][0]
        if all(retires[i + k][0] == pc for k in range(PARK_N)):
            return i
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rtl", required=True)
    ap.add_argument("--spike", required=True)
    ap.add_argument("--entry", type=lambda s: int(s, 0), default=0x0,
                    help="ELF entry PC; Spike retires below this (the boot "
                         "stub) are skipped. Default 0x0.")
    args = ap.parse_args()

    rtl = parse_rtl(args.rtl)
    spike_full = parse_spike(args.spike)

    if not rtl:
        print("cosim: RTL trace empty (--rtl)", file=sys.stderr)
        return 1
    if not spike_full:
        print("cosim: Spike log empty/unaligned (--spike)", file=sys.stderr)
        return 1

    # Skip Spike boot-ROM stub: align at the first retire with pc == entry.
    skip = 0
    while skip < len(spike_full) and spike_full[skip][0] != args.entry:
        skip += 1
    if skip == len(spike_full):
        print(f"cosim: never saw entry PC 0x{args.entry:x} in Spike log "
              f"(stub never jumped to the program?)", file=sys.stderr)
        return 1
    spike = spike_full[skip:]

    # Park handling: compare up to and including the first loop instr.
    park_rtl = find_park(rtl)
    park_spike = find_park(spike)

    if park_rtl is not None and park_spike is not None:
        cmp_rtl = rtl[: park_rtl + 1]
        cmp_spike = spike[: park_spike + 1]
        park_pc_rtl = rtl[park_rtl][0]
        park_pc_spike = spike[park_spike][0]
        if park_pc_rtl != park_pc_spike:
            print(f"cosim: park PC mismatch: rtl 0x{park_pc_rtl:08x} vs "
                  f"spike 0x{park_pc_spike:08x}", file=sys.stderr)
            return 1
    else:
        cmp_rtl = rtl
        cmp_spike = spike
        if park_rtl is None and park_spike is None:
            print("cosim: neither side parked (both hit a bound); "
                  "comparing the shorter run.", file=sys.stderr)
        else:
            which = "RTL" if park_rtl is None else "Spike"
            print(f"cosim: only {which} parked (control-flow divergence or "
                  f"bound hit on the other side).", file=sys.stderr)

    n = min(len(cmp_rtl), len(cmp_spike))
    for i in range(n):
        rpc, rrd, rval = cmp_rtl[i]
        spc, srd, sval = cmp_spike[i]
        if (rpc, rrd, rval) != (spc, srd, sval):
            print(f"cosim: MISMATCH @ retire {i} (after {i} matched):")
            print(f"  spike: pc 0x{spc:08x}  x{srd} = 0x{sval:08x}")
            print(f"  rtl  : pc 0x{rpc:08x}  x{rrd} = 0x{rval:08x}")
            if rpc != spc:
                print("  -> PC differs: control-flow divergence.")
            elif rrd != srd:
                print("  -> destination register differs.")
            else:
                print("  -> writeback value differs.")
            return 1

    if len(cmp_rtl) != len(cmp_spike):
        shorter = "rtl" if len(cmp_rtl) < len(cmp_spike) else "spike"
        longer = "spike" if shorter == "rtl" else "rtl"
        print(f"cosim: first {n} retires match, but {shorter} stopped early "
              f"({len(cmp_rtl)} vs {len(cmp_spike)}). {longer} ran "
              f"{abs(len(cmp_rtl) - len(cmp_spike))} more.", file=sys.stderr)
        return 1

    parkmsg = ""
    if park_rtl is not None:
        parkmsg = f", park @ 0x{rtl[park_rtl][0]:08x}"
    print(f"cosim: PASS -- matched {n} retires{parkmsg} "
          f"(skipped {skip} Spike stub retires).")
    return 0


if __name__ == "__main__":
    sys.exit(main())