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
# Re-running is a no-op if the spike binary already exists. Delete
# riscv-isa-sim-install/ to force a rebuild.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/riscv-isa-sim"
BUILD="$SCRIPT_DIR/riscv-isa-sim-build"
PREFIX="$SCRIPT_DIR/riscv-isa-sim-install"
SPIKE_BIN="$PREFIX/bin/spike"
# Pinned upstream commit (inspect with: git -C "$SRC" log -1).
SPIKE_REF="${SPIKE_REF:-38c2a30f794f26979a6e3f288bf13bacae27e225}"
REPO="https://github.com/riscv-software-src/riscv-isa-sim"

if [[ -x "$SPIKE_BIN" ]]; then
    echo "build_spike.sh: $SPIKE_BIN already built, skipping."
    exit 0
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

# Out-of-tree build. --enable-commitlog is required for --log-commits.
rm -rf "$BUILD"
mkdir -p "$BUILD"
(
    cd "$BUILD"
    "$SRC/configure" --enable-commitlog --prefix="$PREFIX"
    make -j"$(nproc)"
    make install
)

echo "build_spike.sh: installed $SPIKE_BIN"