"""Run the UART protocol C tests using a host C compiler (no FPGA toolchain)."""

import argparse
import ctypes
import importlib.util
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--cc", default=os.environ.get("CC"),
                    help="host C compiler command; defaults to CC, cc, gcc or clang")
args = parser.parse_args()

sender_path = ROOT / "tools/keyboard_uart.py"
spec = importlib.util.spec_from_file_location("keyboard_uart", sender_path)
sender = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sender)
assert sender.crc8(b"123456789") == 0xF4
assert sender.encode_frame(254, sender.UP | sender.FIRE) == bytes.fromhex("a55a01fe11de")
assert sender.encode_frame(256, 0xC1)[4] == 1, "sequence/bitmap must be masked to wire width"
assert ctypes.sizeof(sender.DCB) == 28, "Windows DCB layout must match Win32"

compiler = shlex.split(args.cc) if args.cc else next(
    ([candidate] for candidate in ("cc", "gcc", "clang", "cl")
     if shutil.which(candidate)), None)
if not compiler:
    raise SystemExit("No host C compiler found. Run from a Visual Studio Developer shell or pass --cc.")

source = ROOT / "sim/test_uart_keyboard_protocol.c"
with tempfile.TemporaryDirectory(prefix="uart-key-check-") as temp:
    is_msvc = Path(compiler[0]).name.lower() in ("cl", "cl.exe")
    suffix = ".exe" if os.name == "nt" else ""
    cases = [
        ("protocol", ROOT / "sim/test_uart_keyboard_protocol.c", []),
        ("input", ROOT / "sim/test_uart_keyboard_input.c",
         ["/I" + str(ROOT / "sim/mock_uart")] if is_msvc else
         ["-I", str(ROOT / "sim/mock_uart")]),
    ]
    for name, test_source, includes in cases:
        exe = Path(temp) / ("uart_key_" + name + suffix)
        if is_msvc:
            obj = Path(temp) / ("uart_key_" + name + ".obj")
            command = [*compiler, "/nologo", "/TC", "/W4", "/WX",
                       *includes, str(test_source), f"/Fo:{obj}", f"/Fe:{exe}"]
        else:
            command = [*compiler, "-std=c99", "-Wall", "-Wextra", "-Werror",
                       *includes, str(test_source), "-o", str(exe)]
        subprocess.run(command, cwd=ROOT, check=True)
        subprocess.run([str(exe)], cwd=ROOT, check=True)

    firmware = ROOT / "software/interactive_demo/uart_keyboard_test.c"
    if is_msvc:
        obj = Path(temp) / "uart_keyboard_test.obj"
        command = [*compiler, "/nologo", "/TC", "/W4", "/WX", "/c",
                   "/I" + str(ROOT / "sim/mock_uart"), str(firmware), f"/Fo:{obj}"]
    else:
        command = [*compiler, "-std=c99", "-Wall", "-Wextra", "-Werror",
                   "-I", str(ROOT / "sim/mock_uart"), "-fsyntax-only", str(firmware)]
    subprocess.run(command, cwd=ROOT, check=True)
print("PASS PC sender framing/CRC and Win32 DCB layout")
