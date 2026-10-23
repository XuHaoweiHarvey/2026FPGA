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
    if is_msvc:
        executable = temp / "game_logic_test.exe"
        subprocess.run([*compiler, "/nologo", "/TC", "/W4", "/WX",
                        str(ROOT / "sim/test_survival_game.c"),
                        str(ROOT / "software/interactive_demo/game_logic.c"),
                        "/Fe:" + str(executable)], cwd=ROOT, check=True)
        subprocess.run([*compiler, "/nologo", "/TC", "/W4", "/WX", "/Zs",
                        "/DSURVIVAL_GAME_HOST_SYNTAX",
                        "/I" + str(ROOT / "sim/mock_game"),
                        "/I" + str(ROOT / "sim/mock_uart"),
                        str(ROOT / "software/interactive_demo/game_main.c")],
                       cwd=ROOT, check=True)
    else:
        executable = temp / "game_logic_test"
        common = [*compiler, "-std=c99", "-Wall", "-Wextra", "-Werror"]
        subprocess.run([*common, str(ROOT / "sim/test_survival_game.c"),
                        str(ROOT / "software/interactive_demo/game_logic.c"),
                        "-o", str(executable)], cwd=ROOT, check=True)
        subprocess.run([str(executable)], cwd=ROOT, check=True)
        subprocess.run([*common, "-fsyntax-only", "-I", str(ROOT / "sim/mock_uart"),
                        str(ROOT / "software/interactive_demo/game_main.c")],
                       cwd=ROOT, check=True)
print("PASS survival game movement, firing, scoring, pause/restart and sprite accounting")
print("PASS UART-enabled board game source syntax")
