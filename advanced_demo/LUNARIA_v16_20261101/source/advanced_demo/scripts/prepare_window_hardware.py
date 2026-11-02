"""Snapshot a separate Efinity project; never build into the fullscreen outflow."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--compile", action="store_true")
parser.add_argument("--efinity", type=Path, default=Path("D:/Efinity"))
args = parser.parse_args()
target = ROOT / "output/window640_hardware"
target.mkdir(parents=True, exist_ok=True)
for folder in ("rtl", "ip", "embedded_sw", "constraints"):
    shutil.copytree(ROOT/folder, target/folder, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns("build", "__pycache__", ".metadata"))
for name in ("ti60f225_oob.xml", "ti60f225_oob.peri.xml", "ti60f225_oob.sdc"):
    shutil.copy2(ROOT/name, target/name)
# Preserve project-relative initialization paths without copying application builds.
(target/"software/flash").mkdir(parents=True, exist_ok=True)
shutil.copy2(ROOT/"software/flash/jtag_wait.hex", target/"software/flash/jtag_wait.hex")
top = target/"rtl/ti60f225_oob_top.v"
text = top.read_text(encoding="utf8")
original = "parameter DISPLAY_WINDOW_ENABLE = 0,"
assert text.count(original) == 1
top.write_text(text.replace(original, "parameter DISPLAY_WINDOW_ENABLE = 1,"), encoding="utf8")
sources = [p for folder in ("rtl", "constraints", "ip") for p in (ROOT/folder).rglob("*")
           if p.is_file() and p.suffix in (".v", ".sv", ".vh", ".sdc", ".hex", ".json")]
manifest = {"hardware_version": "0x00080000", "display_window": [640, 300, 640, 480],
            "output": "1920x1080@60Hz", "framebuffer_stride": 7680,
            "board_tested": False,
            "sources": {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                        for p in sources}}
(target/"source_manifest.json").write_text(json.dumps(manifest, indent=2)+"\n", encoding="utf8")
print("Prepared isolated window project:", target, flush=True)
if args.compile:
    subprocess.run(["cmd", "/c", str(args.efinity/"bin/efx_run.bat"),
                    "ti60f225_oob.xml", "--flow", "compile"], cwd=target, check=True)
