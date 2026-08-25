# Trap + interrupt oracles. Builds every test in this group with one command.
#
#   make            build trap + timer + wfi_trap
#   make clean      clean all
#   make trap       build one test

TESTS := trap timer wfi_trap

.PHONY: all clean $(TESTS)
all:
	@for t in $(TESTS); do $(MAKE) -C $$t || exit 1; done

$(TESTS):
	$(MAKE) -C $@

clean:
	@for t in $(TESTS); do $(MAKE) -C $$t clean; done