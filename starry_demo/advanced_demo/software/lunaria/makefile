PYTHON ?= python
.PHONY: all pixelforge stress clean
all:
	$(PYTHON) -B ../../scripts/build_pixelforge.py
pixelforge: all
stress:
	$(PYTHON) -B ../../scripts/build_lunaria_stress.py
clean:
	@echo Builds use temporary objects; delivery packages are retained.
