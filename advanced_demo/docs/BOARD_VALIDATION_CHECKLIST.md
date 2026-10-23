# Advanced game board validation checklist

This checklist is for the final UART-controlled Alpha/Color Key game. The
existing v6 Alpha-comparison bit/ELF package is not a game build. In the
current checkout UART0 is disabled in the generated SoC/BSP, so do not use
that package to claim the keyboard game is board-ready.

## Before creating game images

The board model and pins are confirmed from the V4 manual. Record the remaining
PC/tool and hardware observations on the teammate's machine:

| Item | Record |
|---|---|
| Full Ti60F225 board model and PCB revision | TI60F225I3-V4 (confirmed) |
| Efinity Programmer, Efinity IDE and RISC-V IDE versions | |
| UART_RX/TX pads and pin constraints for this revision | RX R4/GPIOL_02 input; TX R14/GPIOR_28 output; reserved in source |
| FT4232 channel and Windows COM port mapping | |
| Whether JTAG and UART can be used at the same time | |
| HDMI display model/input | |

Then enable UART0 in Efinity IP Manager, regenerate the Sapphire SoC and BSP,
replace the idle TX driver in `rtl/control/sapphire_control.v` with connections
to the actual generated UART RX/TX ports. The top-level ports and V4 peripheral
pin assignments are already reserved. Keep existing HDMI and DDR assignments
unchanged. Do not edit only `settings.json` or combine a new ELF with the old
UART-disabled bitstream.

Run `py -3 scripts/check_project.py` after connecting the regenerated UART.
The COM number is a PC runtime choice and may differ between computers; it
does not need to be fixed in the FPGA or game code. Check the FT4232 channel
on the board PC. See `KEYBOARD_UART_INPUT.md` for the exact handoff steps.

## Build and load

After regenerated UART-enabled BSP and a successful full Efinity build:

1. Build the game with `py -3 scripts/build_apb_software.py --program game`.
2. Build/load the matching UART-enabled bitstream with Efinity Programmer.
   Initially use temporary JTAG configuration; do not program SPI Flash.
3. Load `software/interactive_demo/build/game/survival_game.elf` through the
   matching Efinity RISC-V IDE/OpenOCD configuration and resume the CPU.
4. Run `py -3 tools/keyboard_uart.py --list`, then start the sender on the
   verified board COM port, for example `py -3 tools/keyboard_uart.py COM7`.
5. Use WASD/arrows to move, Space/Ctrl to fire, and P to pause. When the game
   ends, release and press fire to restart.

Use `--program keyboard-test` only with the UART diagnostic firmware. It is a
separate diagnostic image, not the gameplay ELF.

## Acceptance measurements

Observe at least 60 seconds after startup. Confirm that the player and enemies
draw with Color Key transparency, and the glow, shots, and hit effects use
Alpha blending. Keep both types visible during the high-load section.

Record these values from the screen and `g_game_result`:

| Measurement | Result |
|---|---|
| Stable presented game FPS | |
| Maximum simultaneous Sprite count | |
| FPS at maximum Sprite count | |
| `error` / `phase` | |
| `underflow_delta` / `missed_delta` | |
| `reader_error` / `command_delta` / `swap_delta` | |
| UART accepted / bad CRC / version / flags / stale / timeout-release counts | |
| Keyboard response and reconnect behavior | |
| Pause preserves effects, damage protection, firing cooldown and wave timing | |

The target is a stable 60 FPS with the largest repeatable Sprite load while
Alpha and Color Key are both active. Report the measured Sprite limit if 60
FPS cannot be sustained; do not infer a successful result from host tests.

## If the board run fails

Save the screen photo, debugger state, Programmer/OpenOCD output, exact bit and
ELF paths, and board revision. Check that the ELF and bit came from the same
UART-enabled build. For a black screen inspect `phase/error`; for visual
discontinuity inspect underflow/missed deltas and `reader_error`; for missing
input inspect the UART counters, COM selection, TX/RX crossing, and pin map.
Do not switch to old M2 or Alpha-comparison artifacts and label them as the
game result.
