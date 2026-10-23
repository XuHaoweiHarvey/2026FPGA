# Advanced graphics game demo

This directory implements the competition's high-level challenges: hardware
Alpha blending, Color Key sprites, and a high-load interactive game running on
the RISC-V CPU with FPGA-accelerated drawing. `basic_demo` remains unchanged.

The final demonstration is a keyboard-controlled survival game. The player
moves with WASD or the arrow keys, holds Space or Ctrl to fire, and presses P
to pause. The game uses Color Key for opaque sprites with transparent borders
and Alpha blending for the player's glow, projectiles, and hit effects. Enemy
waves ramp up toward 48 simultaneous enemies. On-screen counters report the
presented game FPS, current Sprite count, and maximum observed Sprite count so
the team can measure the 60 FPS challenge on the board.

The game ELF issues Color Key and Alpha commands; it does not issue ordinary
`OP_BLIT` commands. The RTL keeps BLIT support enabled because Color Key uses
the shared source-transfer path and the accelerator's configuration requires
that support. The retained M2 regression also exercises ordinary BLIT. BLIT is
therefore a lower-level accelerator operation, not a separate advanced-game
mode or a standalone demonstration. The game does not render a CPU/FPGA
comparison scene.

## Build and controls

The confirmed board is TI60F225I3-V4. Its UART pins are reserved in the top
module, control wrapper and peripheral constraints: FPGA RX is R4/GPIOL_02,
and FPGA TX is R14/GPIOR_28 (3.3 V LVCMOS). TX currently stays idle high because
the checked-in generated SoC has no UART0. This is a reservation, not a working
keyboard link. The generated Sapphire SoC/BSP must include UART0 before
building the game ELF:

```powershell
py -3 scripts/build_apb_software.py --program game
py -3 scripts/build_apb_software.py --program keyboard-test
py -3 tools/keyboard_uart.py --list
py -3 tools/keyboard_uart.py COM7
```

The game ELF is written to `software/interactive_demo/build/game/`. The
diagnostic ELF is separate under `software/interactive_demo/build/keyboard-test/`.
Use the game ELF with the UART-enabled game bitstream. The diagnostic ELF is
only for checking the keyboard link and is not the game.

In this checkout, UART0 is disabled in `ip/soc_control/settings.json` and the
generated BSP has no UART0 registers. Do not edit only that JSON file. Use
Efinity IP Manager to enable UART0 and regenerate the SoC/BSP, then replace the
idle TX assignment in `rtl/control/sapphire_control.v` with the actual generated
RX/TX named-port connections. The V4 pin reservations are already in
`ti60f225_oob.peri.xml`; do not copy the opposite-direction pin mapping from
the older generic SoC example. Run `scripts/check_project.py` and a full
Efinity build after connecting UART0. The game/diagnostic software builder also
runs this connection check before compiling. The old v6 Alpha comparison
ELF/bit package does not include this UART integration and is not the game
build. Existing build outputs are ignored by Git.

`COM7` above is only an example. Windows assigns the port on each PC; choose
it when launching the sender, without editing or rebuilding FPGA/game sources.
The teammate can identify the FT4232 COM channel during board validation.
See `docs/KEYBOARD_UART_INPUT.md` for the handoff steps.

## Verification

Run the portable game-logic checks and board-app syntax check on a host:

```powershell
py -3 scripts/run_game_logic_checks.py
py -3 scripts/run_uart_keyboard_checks.py
```

The game logic tests movement bounds, firing/scoring, pause/restart edges,
preservation of effect/protection/cooldown timers while paused (including clock
wrap), and Sprite accounting. UART protocol tests cover framing, CRC, replay rejection,
release on timeout, and FIFO adapter behavior. These host tests do not verify
the generated SoC, physical UART pins, DDR/display timing, or board FPS.

The graphics regressions remain available for the required hardware features:

```powershell
py -3 scripts/run_alpha_checks.py
powershell -ExecutionPolicy Bypass -File scripts/run_color_key_checks.ps1
```

Record the board's presented FPS and maximum Sprite count while both Alpha and
Color Key are active. Also record `error`, `reader_error`, underflow and missed
boundary deltas. The stable simultaneous Sprite count at 60 FPS can only be
established by running the UART-enabled game build on the target board.

The M2 comparison sources, builders, and regression scripts that remain in this
engineering checkout support earlier baselines and compatibility checks; they
are not advanced-demo modes and are not linked into the game ELF.
