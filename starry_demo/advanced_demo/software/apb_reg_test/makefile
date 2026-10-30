# Eclipse external-make project; Python builds against the generated BSP.
PYTHON ?= python
.PHONY: all clean
all:
	$(PYTHON) ../../scripts/build_apb_software.py
clean:
	$(PYTHON) -c "from pathlib import Path; [p.unlink() for p in Path('build').glob('*') if p.is_file()]"
