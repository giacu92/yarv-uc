# ISA decode/fetch oracles. Builds every test in this group with one command.
#
#   make            build ifault + isa_probe + rvc_scramble
#   make clean      clean all
#   make ifault     build one test

TESTS := ifault isa_probe rvc_scramble span_target

.PHONY: all clean $(TESTS)
all:
	@for t in $(TESTS); do $(MAKE) -C $$t || exit 1; done

$(TESTS):
	$(MAKE) -C $@

clean:
	@for t in $(TESTS); do $(MAKE) -C $$t clean; done