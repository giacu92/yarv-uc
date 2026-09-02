# Instruction-access-fault vs stashed-RVC-half oracle.
#
# A compressed instruction stashed in decode's hold buffer is a COMPLETE
# instruction older than the faulting PC behind it; taking the fault first
# drops it and makes the trap imprecise. Decode used to do exactly that.
#
#   make          build build/imem.hex + build/dmem.hex
#   make clean    remove build/
#
# Run in the sim (from sim/):
#   make run RUN_ARGS="+IINIT=sw/isa/ifault_hold/build/imem.hex \
#                      +DINIT=sw/isa/ifault_hold/build/dmem.hex"
# Result word at 0x2000: 0x600D pass / 0xBAD fail.
#
# No toolchain path: the program IS its placement in the last fetch word of
# the I-mem, which gen_hex.py states directly instead of routing it through
# a link script. gen_hex.py needs python3 and nothing else.

BUILD := build

.PHONY: all clean

all: $(BUILD)/imem.hex

$(BUILD)/imem.hex: gen_hex.py
	python3 gen_hex.py $(BUILD)

clean:
	rm -rf $(BUILD)
