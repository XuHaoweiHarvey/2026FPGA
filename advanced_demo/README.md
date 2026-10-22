# Advanced Alpha Demo

This directory is the experimental v6 branch of the graphics-engine work. The
accepted v5/M2 demonstration remains under `basic_demo`; all changes described
here are local to `advanced_demo`. Its source starting point is M2 baseline
commit `be4a02d36b83eefb03009c4457b9225d321e99e3` on `main`.

## What it demonstrates

The independent `advanced_demo` software mode generates a sealed 640x480
ARGB8888 sprite atlas in DDR and draws one deterministic scene in two ways:

- ordinary Front-to-Back BLIT;
- magenta Color Key from the atlas;
- two overlapping straight-alpha light sprites over a prepared background.

The CPU reference and FPGA renderers use the same atlas, background and source
rectangle. The sprites fade automatically. Render FPS counts the render phase;
presented FPS includes HUD drawing and the safe frame swap. The debugger result
record is `g_advanced_result`; no input devices are needed.

The older M2 software remains available as mode 6 and the new demo as mode 7:

```powershell
py -3 scripts/build_apb_software.py --program m2
py -3 scripts/build_apb_software.py --program advanced
```

ELFs and bitstreams are intentionally not checked into this source tree. Build
outputs go to separate `software/m2_demo/build` and `software/advanced_demo/build`
directories. The builder expects the Efinity RISC-V IDE toolchain and generated
formal BSP at their configured paths; an alternate GNU tool prefix can be
provided with `--toolchain-prefix`.

## Hardware contract

- Version: `0x00060000`; capabilities: `0x000001FB` (Alpha is bit 8).
- Opcode 3 uses source ARGB alpha and `RECT_COLOR[7:0]` global alpha. It rounds
  `Aeff=(pixel_alpha*global_alpha+127)/255` and each RGB result as
  `(src*Aeff+dst*(255-Aeff)+127)/255`. Destination X is preserved.
- The sprite atlas starts at `0x01384000`, contains 640x480 pixels at a 2560
  byte stride and ends exclusively at `0x014B0000`. It follows the three sealed
  M2 images. Only sealed, in-bounds Color Key and Alpha rectangles may read it;
  ordinary BLIT continues to use Front or one of the three full M2 images.
- Alpha reuses the existing graphics read channel and display-priority
  arbiter. Each segment reads foreground and Back, blends, then writes Back.
  The buffer manager retains Back ownership until the final write response.
- The CPU DDR alias is `0x1000 + physical DDR address`. Sprite writes are
  accepted only during the platform-controlled loading session. Sealing is
  permanent until platform reset.

The complete register contract is in [docs/REGISTER_MAP.md](docs/REGISTER_MAP.md).
The local Efinity synthesis and timing results are recorded in
[docs/ALPHA_BUILD_REPORT.md](docs/ALPHA_BUILD_REPORT.md).

## Verification

Focused Alpha regressions:

```powershell
py -3 scripts/run_alpha_checks.py
```

The suite checks 537 deterministic and random pixel vectors, the Alpha DMA
pixel scoreboard and command snapshot, sprite-window boundaries, Alpha APB
begin/seal at several wait counts, and CPU DDR sprite loading/sealed access.
Other regression entry points remain `run_graphics_checks.ps1`,
`run_d_checks.py`, `run_apb_checks.py`, `run_rgb_checks.py`, and
`run_m2_software_checks.py`.

The source and testbenches do not replace a full Efinity map/place-and-route,
board run, or performance measurement. Record on-board error counters,
render/present FPS, actual swap cadence, resource use and timing after building
the v6 project and loading its matching ELF/bitstream.
