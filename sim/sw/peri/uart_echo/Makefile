# UART echo + external-interrupt (MEIP) oracle: echoes 4 bytes by polling, then
# enables CTRL.RX_IE + mie.MEIE + mstatus.MIE and echoes 4 more from an
# interrupt handler (interrupt("machine")), sleeping in wfi in between. Writes
# 0x600D / 0xBAD to D-mem 0x3000 (.rodata linked there). The only end-to-end test
# of MEIP: uart_irq_o -> meip_i -> mip.MEIP -> trap_unit -> interrupt entry, plus
# the wfi wake on an external interrupt. Doubles as the hardware bring-up program.
#
#   make          build build/imem.hex + build/dmem.hex
#   make show     disassemble build/program.elf
#   make clean    remove build/
#
# Run in the sim (from sim/):
#   UART_RX='abcdefgh' make run RUN_ARGS="+IINIT=sw/peri/uart_echo/build/imem.hex +DINIT=sw/peri/uart_echo/build/dmem.hex"
#   -> serial log "ECHO / abcd / IRQ / efgh / GOOD", wb x15 = 0x0000600d
#
# Needs Zicsr (programs mtvec/mie/mstatus, runs an interrupt handler). Board-fw-
# style: pad the I-mem image to the full declared depth with ebreak.

ARCH := rv32imac_zicsr_zifencei

UART_TX_PACED ?= 0
EXTRA_CFLAGS := -DUART_TX_PACED=$(UART_TX_PACED)

C_SRCS := uart_echo.c

IMEM_PAD_WORDS := 4096

include ../../common/sw_build.mk