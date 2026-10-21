"""Check the retained JTAG required input against a synthesized netlist.

Run after synthesis. This catches the unconnected TDI regression; the Efinity
packer remains the authority for the complete physical interface check.
"""
import argparse
import csv
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--netlist", type=Path, default=ROOT / "outflow/ti60f225_oob.map.v")
parser.add_argument("--interface", type=Path, default=ROOT / "outflow/ti60f225_oob.interface.csv")
args = parser.parse_args()
rows = list(csv.reader(args.interface.read_text(encoding="utf8").splitlines()))
required = {row[-1].strip() for row in rows if row and row[0].strip() == "required input"}
pin = "jtag_inst1_TDI"
if pin not in required:
    raise SystemExit("FAIL: retained JTAG physical interface must require jtag_inst1_TDI")
netlist = args.netlist.read_text(encoding="utf8")
netlist = re.sub(r"/\*.*?\*/|//[^\n]*", "", netlist, flags=re.S)
top = re.search(r"\bmodule\s+ti60f225_oob_top\b.*?;(.*?)\bendmodule\b", netlist, re.S)
if not top:
    raise SystemExit("FAIL: synthesized ti60f225_oob_top not found")
body = re.sub(r"\b(?:input|output|inout|wire|reg)\b[^;]*;", "", top.group(1))
if not re.search(r"\bjtag_inst1_TDI\b", body):
    raise SystemExit("FAIL: Required pin jtag_inst1_TDI is unconnected and can be removed by packing")
print("PASS: required jtag_inst1_TDI participates in the synthesized JTAG path")
