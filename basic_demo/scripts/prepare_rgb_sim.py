"""Prepare Icarus-only compatibility copies; never alter formal RTL.

The legacy Efinity code uses unsized expressions in concatenations, which
Icarus rejects. Its explicitly sensitive GrayDecode can also miss a time-zero
constant input in Icarus, leaving FIFO counts X until a read has occurred.
always_comb evaluates that combinational decoder once at time zero.
"""
import argparse
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("output", type=Path)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
for name, signal in (("ddr_wr_buffer", "ddr_awlen"), ("ddr_rd_buffer", "ddr_arlen")):
    text = (ROOT / f"rtl/frame_buffer_V4/{name}.v").read_text(encoding="utf8")
    old = f"({signal}+1)"
    assert text.count(old) == 1, f"Unexpected legacy expression: {name}"
    text = text.replace(old, f"({signal}+32'd1)")
    (args.output / f"{name}.v").write_text(text, encoding="utf8")
text = (ROOT / "rtl/frame_buffer_V4/DC_FIFO.v").read_text(encoding="utf8")
assert text.count("always @ (GrayIn)") == 1
(args.output / "DC_FIFO.v").write_text(text.replace("always @ (GrayIn)", "always_comb"), encoding="utf8")
print("Prepared three temporary simulation copies; formal legacy RTL unchanged")
# Port-only encrypted IP stubs support top-level wiring elaboration, never
# functional simulation or an Efinity source list. Use the real port headers.
headers = []
for name in ("rtl/ddr3_controller/ddr3_top.v", "rtl/dvi_tx/dvi_encoder.v_encrypted.v"):
    text = (ROOT / name).read_text(encoding="utf8")
    end = re.search(r"^\s*\);\s*$", text, re.M)
    assert end, name
    headers.append(text[:end.end()] + "\nendmodule\n")
soc = ROOT / 'ip/soc_control/soc_control.v'
if soc.exists():
    # Sapphire also contains protected CPU blocks. Extract only its real public
    # header for binding checks; do not run this stub as a CPU simulation.
    text = soc.read_text(encoding='utf8')
    start = text.index('module soc_control')
    end = text.index(');', start) + 2
    headers.append(text[start:end] + '\nendmodule\n')
(args.output / "ip_port_stubs.v").write_text("\n".join(headers), encoding="utf8")
