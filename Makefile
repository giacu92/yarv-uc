# Top-level Makefile for code formatting (Verible).
#
# The FPGA build still runs through the Gowin IDE / gw_sh (see CLAUDE.md);
# this Makefile only covers the formatter so the RTL stays consistently
# styled across editors.
#
#   make format        reformat every SystemVerilog file in place
#   make format-check  fail (exit 1) if any file is not formatted; prints
#                      the offending files (use this in CI / pre-commit)
#   make format-diff   show a unified diff of what `make format` would do
#
# Requires `verible-verilog-format` on PATH. Install (Debian/Ubuntu): see
# CLAUDE.md; the project uses the chipsalliance/verible static binary in
# ~/tools/verible (symlinked into ~/.local/bin).

VERIBLE       ?= verible-verilog-format
FLAGFILE      := verible.flags

# SystemVerilog sources to format: all RTL under src/rtl plus the sim
# wrapper. Build artefacts (sim/obj_dir) and generated files are excluded.
SV_SOURCES    := $(shell find src/rtl sim -type f \( -name '*.sv' -o -name '*.svh' -o -name '*.v' \) \
                       ! -path 'sim/obj_dir/*' 2>/dev/null)

# Formatter invocation shared by all targets. --flagfile carries the
# project policy; --inplace is added only by the `format` target.
FMT_FLAGS     := --flagfile=$(FLAGFILE)

.PHONY: format format-check format-diff help

help:
	@echo "Targets:"
	@echo "  format        reformat all SystemVerilog in place"
	@echo "  format-check  exit 1 if any file is unformatted (CI/pre-commit)"
	@echo "  format-diff   print a unified diff of pending formatting changes"
	@echo "Variables:"
	@echo "  VERIBLE=$(VERIBLE)   formatter binary"
	@echo "  FLAGFILE=$(FLAGFILE)   project formatter policy"

# Reformat in place.
format: $(SV_SOURCES)
	@for f in $(SV_SOURCES); do \
	    $(VERIBLE) $(FMT_FLAGS) --inplace "$$f" || exit 1; \
	done
	@echo "formatted $(words $(SV_SOURCES)) files"

# Dry run: list files that would change. Exits 1 if any do (CI-friendly).
format-check: $(SV_SOURCES)
	@status=0; \
	for f in $(SV_SOURCES); do \
	    if ! $(VERIBLE) $(FMT_FLAGS) "$$f" 2>/dev/null | diff -q "$$f" - >/dev/null 2>&1; then \
	        echo "not formatted: $$f"; \
	        status=1; \
	    fi; \
	done; \
	exit $$status

# Dry run: show the full diff (for review before running `make format`).
format-diff: $(SV_SOURCES)
	@for f in $(SV_SOURCES); do \
	    $(VERIBLE) $(FMT_FLAGS) "$$f" 2>/dev/null | diff -u "$$f" - || true; \
	done