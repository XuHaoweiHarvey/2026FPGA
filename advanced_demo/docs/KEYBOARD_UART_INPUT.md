# PC keyboard input over UART for the advanced game

The survival game uses a USB-UART key-state link. The PC helper sends a
complete key bitmap at 50 Hz; the board parser rejects corrupt, duplicate and
old frames. If no good frame arrives for 150 ms, it releases every key so a
disconnected cable cannot leave movement stuck.

## Frame format

All bytes are sent 8-N-1 at 115200 baud, least-significant bit first as standard
UART. Every packet is six bytes:

| Byte | Meaning |
|---|---|
| 0–1 | Sync: `A5 5A` |
| 2 | Protocol version: `01` |
| 3 | Unsigned sequence number, wraps at 255 |
| 4 | Current key bitmap |
| 5 | CRC-8/ATM (polynomial `07`, initial value `00`, no reflection/xorout), over bytes 2–4 |

Button bits: bit 0 up, bit 1 down, bit 2 left, bit 3 right, bit 4 fire, and
bit 5 pause. Reserved bits must be zero. The sequence difference must be 1–127
modulo 256; the receiver accepts wraparound and rejects duplicates/replays.
Packets describe current state rather than key transitions, so releases are
sent as part of the next frame. The PC utility sends two all-released frames
on exit, and the board has the 150 ms timeout as a second release path.

## PC sender

`tools/keyboard_uart.py` uses only Python's standard library and Windows
Win32 serial/keyboard APIs; it does not need pyserial or administrator rights.
Close any terminal program that already has the COM port open. List ports and
start the sender from PowerShell in this directory:

```powershell
py -3 tools/keyboard_uart.py --list
py -3 tools/keyboard_uart.py COM7
```

Replace `COM7` with the board's serial port from Device Manager. The sender
reads keyboard state globally, so it does not need its window focused. WASD or
the arrow keys move, Space or Ctrl fires, P pauses, and Esc exits after sending
released keys. `--baud` and `--rate` can override the defaults when the board
configuration is changed.

## Game and FPGA integration status

The reusable nonblocking receiver is in
`software/interactive_demo/uart_keyboard_input.h`; the game polls it between
render commands, reads the current bitmap, and latches press/release edges for
taps that arrive between game frames. Polling is capped at 128 bytes per call
so a busy or corrupt stream cannot monopolize rendering. The separate
`software/interactive_demo/uart_keyboard_test.c` diagnostic firmware exposes
`g_uart_keyboard_result` for debugger inspection. In this checkout UART0 is
disabled in `ip/soc_control/settings.json`, and the generated SoC has no UART
ports, so neither the game ELF nor the diagnostic ELF can yet be built against
the checked-in BSP. Do not enable it by hand only in the JSON: regenerate the
SoC and BSP through Efinity IP Manager, then connect the generated `io_uart_0`
pins at the platform wrapper and map them to the board's actual FT4232 UART
RX/TX pads in the peripheral constraints. Keep the existing video and DDR pin
assignments intact.

The board manual identifies UART_RX as GPIOL_02 (R4) and UART_TX as GPIOR_28
(R14) for the documented Ti60F225 revision. The exact board revision, which
FT4232 COM port/channel maps to those pins, and simultaneous JTAG/COM behavior
still need confirmation from the teammate holding the board. A host-side test
does not validate the FT4232 channel or physical RX/TX wiring.

After UART0 is regenerated and board pads are connected, build the game with
`py -3 scripts/build_apb_software.py --program game`. The separate diagnostic
image can be built with `py -3 scripts/build_apb_software.py --program keyboard-test`.
Load each ELF only with its matching UART-enabled bitstream. For the diagnostic,
resume it and inspect
`g_uart_keyboard_result` in the debugger, and run the PC sender. `phase == 2`
means the receiver loop is live; `buttons` must follow the key map, accepted
frames must increase, and the CRC/version/flags/stale counters should remain
zero. Stop the PC sender and verify `buttons == 0` and `timeout_releases`
increments. This diagnostic build is kept separate from the existing v6 ELF.

## Offline verification

Run the portable parser regression using a host C compiler. On Windows this can
be a Visual Studio Developer PowerShell:

```powershell
py -3 scripts/run_uart_keyboard_checks.py
```

The checks cover CRC, garbage and partial-frame recovery, corrupt/unsupported
frames, sequence replay/wrap, timeout release, reconnection and millisecond
counter rollover. A mocked MMIO FIFO test also checks UART setup, bounded
draining, state and press/release latching. These checks verify software only;
the USB-UART and display/game behavior need the board.
