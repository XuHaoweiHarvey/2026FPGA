# The IDE and command line build the same application and output.
PYTHON ?= python
BUILD_ARGS ?=
.PHONY: all clean
all:
	$(PYTHON) -B build.py $(BUILD_ARGS)
clean:
	$(PYTHON) -B build.py --clean
