"""Run portable survival-game logic tests and compile-check the board app."""

import argparse
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--cc", default=os.environ.get("CC"),
                        help="host C compiler command; defaults to CC, cc, gcc, clang or cl")
args = parser.parse_args()
compiler = shlex.split(args.cc) if args.cc else next(
    ([candidate] for candidate in ("cc", "gcc", "clang", "cl") if shutil.which(candidate)), None)
if not compiler:
    raise SystemExit("No host C compiler found. Use a Developer PowerShell or pass --cc.")

is_msvc = Path(compiler[0]).name.lower() in ("cl", "cl.exe")
with tempfile.TemporaryDirectory(prefix="survival-game-check-") as temp_name:
    temp = Path(temp_name)
    for fullscreen, background, window, tuning, hud_cache in (
            (0, 0, 0, 0, 0), (0, 1, 0, 0, 0), (1, 1, 0, 0, 0),
            (0, 1, 1, 0, 0), (0, 1, 1, 1, 0), (0, 1, 1, 1, 1)):
        # Compile the same contracts for both display geometries.
        mode = ([f"/DGAME_FULLSCREEN={fullscreen}"] if is_msvc else
                  [f"-DGAME_FULLSCREEN={fullscreen}"])
        mode += ([f"/DGAME_TEAM_BACKGROUND={background}"] if is_msvc else
                 [f"-DGAME_TEAM_BACKGROUND={background}"])
        mode += ([f"/DGAME_DISPLAY_WINDOW={window}"] if is_msvc else
                 [f"-DGAME_DISPLAY_WINDOW={window}"])
        mode += ([f"/DGAME_WINDOW_HUD_CACHE={hud_cache}"] if is_msvc else
                 [f"-DGAME_WINDOW_HUD_CACHE={hud_cache}"])
        if tuning:
            prefix = "/D" if is_msvc else "-D"
            mode += [prefix + "GAME_STRESS_TUNING=1", prefix + "GAME_ENEMY_BULLET_CAPACITY=512"]
        if is_msvc:
            executable = temp / "game_logic_test.exe"
            subprocess.run([*compiler, *mode, "/nologo", "/TC", "/W4", "/WX",
                            str(ROOT / "sim/test_survival_game.c"),
                            str(ROOT / "software/interactive_demo/game_logic.c"),
                            "/Fe:" + str(executable)], cwd=temp, check=True)
            subprocess.run([str(executable)], cwd=temp, check=True)
            control_test = temp / "game_debug_test.exe"
            subprocess.run([*compiler, *mode, "/nologo", "/TC", "/W4", "/WX",
                            "/I" + str(ROOT / "sim/mock_uart"),
                            str(ROOT / "sim/test_game_debug_control.c"),
                            str(ROOT / "software/interactive_demo/game_logic.c"),
                            "/Fe:" + str(control_test)], cwd=temp, check=True)
            subprocess.run([str(control_test)], cwd=temp, check=True)
            subprocess.run([*compiler, *mode, "/nologo", "/TC", "/W4", "/WX", "/Zs",
                            "/DSURVIVAL_GAME_HOST_SYNTAX",
                            "/DGAME_FLASH_ENABLE=0",
                            "/I" + str(ROOT / "sim/mock_game"),
                            "/I" + str(ROOT / "sim/mock_uart"),
                            str(ROOT / "software/interactive_demo/game_main.c")],
                           cwd=temp, check=True)
        else:
            executable = temp / ("game_logic_test.exe" if os.name == "nt" else "game_logic_test")
            common = [*compiler, *mode, "-std=c99", "-Wall", "-Wextra", "-Werror"]
            subprocess.run([*common, str(ROOT / "sim/test_survival_game.c"),
                            str(ROOT / "software/interactive_demo/game_logic.c"),
                            "-o", str(executable)], cwd=ROOT, check=True)
            subprocess.run([str(executable)], cwd=ROOT, check=True)
            control_test = temp / ("game_debug_test.exe" if os.name == "nt" else "game_debug_test")
            subprocess.run([*common, "-I", str(ROOT / "sim/mock_uart"),
                            str(ROOT / "sim/test_game_debug_control.c"),
                            str(ROOT / "software/interactive_demo/game_logic.c"),
                            "-o", str(control_test)], cwd=ROOT, check=True)
            subprocess.run([str(control_test)], cwd=ROOT, check=True)
            subprocess.run([*common, "-fsyntax-only", "-DSURVIVAL_GAME_HOST_SYNTAX",
                            "-DGAME_FLASH_ENABLE=0",
                            "-I", str(ROOT / "sim/mock_game"),
                            "-I", str(ROOT / "sim/mock_uart"),
                            str(ROOT / "software/interactive_demo/game_main.c")],
                           cwd=ROOT, check=True)
print("PASS game movement, firing, enemy projectiles/collision, fixed-step rates, pause/clock wrap, auto restart, option bounds and sprite accounting")
print("PASS UART-enabled board game source syntax")
print("PASS windowed/fullscreen modes, background PNG hash, edge clipping, dirty coverage, burst-saving coalescing and independent display slots")
print("PASS 10 compact sprite hashes, Color Key/Alpha pixels, six-frame fade, pause and 32-bit clock wrap")
print("PASS centered island background: both buffers initialized, full image retained and per-frame BLIT restricted to 640x480")
print("PASS firmware command ack/ownership, restart configuration, frozen pause timers, 60s presentation metrics and raw counters (mock hardware)")
print("PASS three campaign waves, two Boss phases, win/loss/restart, paused Boss deadlines and clock wrap")
print("PASS 100-second stress scene retains 48 enemies + 64 enemy shots; hardware glyph cache and HUD clipping")
print("PASS dynamic 1-48 enemy / 1-512 shot loads, bounds, pool resizing, rendered counts and measurement lock")
print("PASS optimized HUD pixels match full redraw across both buffers, score/life/pause updates and clock wrap; center overlays persist")
