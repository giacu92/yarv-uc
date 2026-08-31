# SHA-256 monitor -> Harvard imem.hex + dmem.hex.
#
# Interactive UART monitor: reads a line (backspace supported), Enter computes
# SHA-256 of the typed text and prints the digest, e.g.
#   SHA256: 0x2CF24DBA5FB0A30E0x26E83B2A0xC5B9E29E0xE1B161E5C0x1FA7425E0x730433620x938B9824
# (8 uart_put_hex32 words, no separators)
# Never terminates (prompt loop); the sim parks on the RX poll.
#
#   make          build build/imem.hex + build/dmem.hex
#   make show     disassemble build/program.elf
#   make clean    remove build/
#
# Load in the sim (from sim/):
#   UART_RX='hello\r' MAX_CYC=20000 make run \
#     RUN_ARGS="+IINIT=sw/sha256/build/imem.hex +DINIT=sw/sha256/build/dmem.hex"
#
# Plain integer code (-march=rv32imac, no zicsr in the arch string): no CSR /
# fence / atomics.
ARCH := rv32imac

# Board-loadable, so the I-mem image is padded to the full 2048-element
# (64-bit) depth: GowinSynthesis sizes an inferred ROM from its $readmemh
# content, not from the declared depth (see sw_build.mk).
IMEM_PAD_WORDS := 2048

C_SRCS := sha256.c

include ../common/sw_build.mk