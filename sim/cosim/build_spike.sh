#!/usr/bin/env bash
# Build a local Spike (riscv-isa-sim) for co-sim, with commit logging.
#
# Upstream Spike already implements the Zilx indexed-load extension
# (EXT_ZILX, ISA token "zilx") with the *same* encoding this core uses
# (OPC_AMO 0x2f, funct5 10010=lx unscaled / 11010=lxs scaled, rs1=index
# rs2=base, funct3=size/sign). So NO patch is needed -- we only build
# upstream Spike with --enable-commitlog so --log-commits works.
#
# Build deps (Debian/Ubuntu):
#   sudo apt install device-tree-compiler libboost-all-dev g++ python3
# (Spike's configure is pre-generated; no autoconf/cmake needed.)
#
# Re-running is a no-op if the spike binary already exists AND it was built
# with the current patch set (recorded in riscv-isa-sim-install/.patch-stamp).
# Changing SPIKE_PATCH_STAMP below forces a rebuild on the next run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/riscv-isa-sim"
BUILD="$SCRIPT_DIR/riscv-isa-sim-build"
PREFIX="$SCRIPT_DIR/riscv-isa-sim-install"
SPIKE_BIN="$PREFIX/bin/spike"
# Pinned upstream commit (inspect with: git -C "$SRC" log -1).
SPIKE_REF="${SPIKE_REF:-38c2a30f794f26979a6e3f288bf13bacae27e225}"
REPO="https://github.com/riscv-software-src/riscv-isa-sim"

# Bump this whenever the sed patches below change, so an existing install
# built with the old patch set is rebuilt instead of silently reused.
SPIKE_PATCH_STAMP="rstvec-0x200000,debug-0x100000"
STAMP_FILE="$PREFIX/.patch-stamp"

if [[ -x "$SPIKE_BIN" ]]; then
    if [[ -f "$STAMP_FILE" ]] && [[ "$(cat "$STAMP_FILE")" == "$SPIKE_PATCH_STAMP" ]]; then
        echo "build_spike.sh: $SPIKE_BIN already built, skipping."
        exit 0
    fi
    echo "build_spike.sh: patch set changed -> rebuilding Spike."
    rm -rf "$PREFIX"
fi

# Fetch the pinned commit (shallow).
if [[ ! -d "$SRC" ]] || [[ ! -d "$SRC/.git" ]]; then
    rm -rf "$SRC"
    git init "$SRC"
    git -C "$SRC" remote add origin "$REPO"
    git -C "$SRC" fetch --depth 1 origin "$SPIKE_REF"
    git -C "$SRC" checkout FETCH_HEAD
else
    # Ensure we are at the pinned ref.
    cur=$(git -C "$SRC" rev-parse HEAD)
    if [[ "$cur" != "$SPIKE_REF" ]]; then
        git -C "$SRC" fetch --depth 1 origin "$SPIKE_REF"
        git -C "$SRC" checkout FETCH_HEAD
    fi
fi

# Two relocations of Spike's fixed devices, both because this core's images
# link low and Spike's unified address space has to hold them where the RTL
# holds them.
#
# Move the Spike debug module off 0x0. Upstream places it at DEBUG_START=0x0
# (DEBUG_SIZE=0x1000), which collides with our -m0x0 DRAM (the ELF links at
# 0x0, entry 0x0). The debug module is not memory, so an ELF load to 0x0 is
# "invalid" without -m0x0, but -m0x0 then overlaps the debug device. We
# relocate it to 0x100000 (our program is bare-metal with a j self-loop, no
# tohost/fromhost, so the debug module is unused).
sed -i 's/^#define DEBUG_START        0x0$/#define DEBUG_START        0x100000/' \
    "$SRC/riscv/platform.h"

# Move the boot ROM (reset vector) off 0x1000. Spike places a 4 KiB ROM at
# DEFAULT_RSTVEC, so the target address space has a hole at 0x1000-0x1FFF
# that no -m region may cover ("devices at [0, 2000) and [1000, 2000)
# overlap"). That caps a co-simulated .text at 4 KiB, which quicksort fits
# and CoreMark (7.2 KiB) does not. Relocating the ROM to 0x200000 -- far
# above both memories and clear of the relocated debug module -- lets the
# co-sim map the images exactly where the hardware has them: .text at 0x0
# (16 KiB I-mem) and .data at 0x2000 (D-mem). The ROM still holds the reset
# vector that jumps to the ELF entry, so nothing about the run changes.
sed -i 's/^#define DEFAULT_RSTVEC     0x00001000$/#define DEFAULT_RSTVEC     0x00200000/' \
    "$SRC/riscv/platform.h"

# Out-of-tree build. --enable-commitlog is required for --log-commits.
rm -rf "$BUILD"
mkdir -p "$BUILD"
(
    cd "$BUILD"
    "$SRC/configure" --enable-commitlog --prefix="$PREFIX"
    make -j"$(nproc)"
    make install
)

echo "$SPIKE_PATCH_STAMP" > "$STAMP_FILE"

echo "build_spike.sh: installed $SPIKE_BIN"