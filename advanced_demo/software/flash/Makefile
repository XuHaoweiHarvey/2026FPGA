# Override PYTHON/IDE_ROOT for another computer. Each target uses the shared BSP.
PYTHON ?= python
IDE_ROOT ?= C:/Efinity/efinity-riscv-ide-2026.1
.PHONY: all game probe maintenance
all: game
game:
	"$(PYTHON)" ../../scripts/build_apb_software.py --ide-root "$(IDE_ROOT)" --program game --opt O2
probe:
	"$(PYTHON)" ../../scripts/build_apb_software.py --ide-root "$(IDE_ROOT)" --program flash-probe --opt O2
maintenance:
	"$(PYTHON)" ../../scripts/build_apb_software.py --ide-root "$(IDE_ROOT)" --program flash-maint --opt O2
