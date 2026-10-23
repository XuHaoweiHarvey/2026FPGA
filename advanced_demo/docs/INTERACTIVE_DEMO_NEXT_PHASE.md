# Advanced challenge game implementation

`advanced_demo` is scoped to the competition's advanced challenges:

1. Hardware Alpha blending while drawing foreground sprites.
2. Hardware Color Key transparency for irregular sprites.
3. A high-load interactive game on RISC-V, measuring how many simultaneous
   sprites can be presented at a stable 60 FPS with both graphics features in
   use.

The final demonstration is the keyboard-controlled survival game. The game
uses Color Key for player/enemy artwork, Alpha for glow/projectile/effect
sprites, and on-screen FPS/current Sprite/maximum Sprite counters. There is no
CPU-versus-FPGA comparison mode and no standalone BLIT showcase. The game ELF
sends Color Key and Alpha commands, not ordinary `OP_BLIT` commands. BLIT
support remains enabled in RTL because Color Key uses the shared source-transfer
path and the accelerator configuration requires BLIT support; the retained M2
regression also exercises ordinary copies.

## Software organization

- `software/interactive_demo/game_logic.[ch]` contains portable movement,
  enemy-wave, projectile, collision, score, lives, pause/restart, and Sprite
  accounting logic.
- `software/interactive_demo/game_main.c` initializes the v6 accelerator,
  seals the generated sprite atlas, receives keyboard state over UART, renders
  with Alpha/Color Key commands, and records runtime diagnostics.
- `software/interactive_demo/uart_keyboard_test.c` remains a separate link
  diagnostic. It is not a game mode.
- `scripts/build_apb_software.py --program game` builds a separate game ELF;
  the inherited M2 comparison and register-check code is not linked into it.

The automated game wave ramps toward 48 enemies. The player can move with
WASD/arrows, fire with Space/Ctrl, and pause with P. The host logic suite checks
the rules and bounds, but it cannot establish actual board FPS or simultaneous
Sprite capacity.

## Board integration status

The checked-in generated SoC/BSP currently has UART0 disabled. A game ELF
cannot be built against this BSP, and the existing v6 Alpha package has no
keyboard connection. Do not hand-edit `settings.json` alone. Before board
integration, the team holding the board must confirm the exact Ti60F225 board
revision, FT4232 UART channel/COM mapping, and whether JTAG can remain connected
while UART is used. Then enable UART0 in Efinity IP Manager, regenerate the SoC
and BSP, route the generated `io_uart_0` signals through the platform wrapper,
and add the verified board pins without disturbing DDR/video assignments.

The documented manual lists UART_RX at GPIOL_02 (R4) and UART_TX at GPIOR_28
(R14), but the exact board revision and USB bridge mapping still need teammate
confirmation. The existing PC sender and parser can be checked offline with
`py -3 scripts/run_uart_keyboard_checks.py`.

## Acceptance measurements

After UART integration and full Efinity build:

1. Run the game ELF with the matching UART-enabled bitstream and confirm
   movement, firing, pause, restart, and automatic key release after unplug.
2. Verify the game HUD and debugger record agree on presented FPS and active
   Sprite counts while Alpha and Color Key sprites overlap on screen.
3. Increase enemy waves to the maximum and record the maximum simultaneous
   Sprite count at a stable 60 FPS, together with error, underflow, and missed
   boundary deltas.
4. Repeat with both Alpha and Color Key visible throughout the load test.

The CPU/FPGA comparison belongs to the earlier M2 baseline and is not an
advanced-challenge acceptance item. The old Alpha comparison program is not
part of the final game build.
