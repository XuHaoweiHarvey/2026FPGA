"""Read-only current project/source and register-contract checks (no snapshots)."""
from pathlib import Path
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
ns = {"e": "http://www.efinixinc.com/enf_proj"}
project = ET.parse(ROOT / "ti60f225_oob.xml").getroot()
files = [e.attrib["name"] for e in project.findall(".//e:design_file", ns)]
assert len(files) == len(set(files)), "Duplicate source entry"
for name in files:
    assert (ROOT / name).is_file(), f"Missing design file: {name}"
    assert not name.startswith(("demo/", "rtl/cam_i2c_ctrl/", "rtl/mipi_config/"))
    assert name not in {"debug_top.v", "rtl/csi_rx_controller.sv"}
for name in ["rtl/test_pattern/rgb_tpg.v", "rtl/framebuffer/rgb_framebuffer.v",
             "rtl/framebuffer/rgb_unpack128_to64.v", "rtl/display/rgb_to_hdmi.v"]:
    assert name in files, f"Missing RGB source: {name}"
assert not any(name.startswith("rtl/debayer/") for name in files)
assert "rtl/test_pattern/bayer_tpg.v" not in files
assert "rtl/frame_buffer_V4/frame_buffer.v" not in files
ips = project.findall(".//e:ip", ns)
checkpoint_b = bool(ips)
if checkpoint_b:
    assert len(ips) == 1 and ips[0].attrib["instance_name"] == "soc_control"
    assert ips[0].attrib["path"] == "ip/soc_control/settings.json"
    assert ips[0].find("e:ip_src_file", ns).attrib["name"] == "soc_control.v"
    assert "ip/soc_control/soc_control.v" not in files, "Do not register the IP source twice"
    for name in ("rtl/control/accel_regs.v", "rtl/control/sapphire_control.v"):
        assert name in files
assert project.find(".//e:top_module", ns).attrib["name"] == "ti60f225_oob_top"
debug = {p.attrib["name"]: p.attrib["value"] for p in project.findall(".//e:debugger/e:param", ns)}
assert debug["auto_instantiation"] == "off" and debug["profile"] == ""

formal = (ROOT / "rtl/ti60f225_oob_top.v").read_text(encoding="utf8")

assert ".rstn                   (w_arstn" in formal
assert "(tpg_frame_start)" in formal and "(tpg_de)" in formal and "(tpg_data)" in formal
assert "rgb_framebuffer #(" in formal and "rgb_to_hdmi u_rgb_to_hdmi" in formal
assert ".SYMBOL_NUM(4)" in formal and ".PIXEL_NUM(2)" in formal
for port, signal in [("pair_data", "ch0_data"), ("vout", "ch0_data"),
                     ("s_axis_tdata", "m_axis_tdata"), ("vin", "tpg_data")]:
    assert re.search(r"\." + port + r"\s*\(\s*" + signal + r"\s*\)", formal), port
assert "assign gamma_sel = 1'b0;" in formal
assert re.search(r"\.i_rdata\s*\(gamma_sel\s*\?\s*gamma_rdata\s*:\s*hdmi_tx_rdata", formal)
assert re.search(r"\.i_bdata\s*\(gamma_sel\s*\?\s*gamma_bdata\s*:\s*hdmi_tx_bdata", formal)
assert "debayer_top_2to1 debayer_top" not in formal
rgb_fb = (ROOT / "rtl/framebuffer/rgb_framebuffer.v").read_text(encoding="utf8")
assert ".FB_NUM(C_MODE ? 1 : 3)" in rgb_fb and ".VID_DATA_WIDTH(32)" in rgb_fb and ".START_ADDR(0)" in rgb_fb
assert ".total_burst_len(FRAME_BEATS)" in rgb_fb and ".burst_len(FRAME_BEATS)" in rgb_fb
assert '.C_MODE(1)' in formal and '.ONE_FRAME(1)' in formal
for name in ('rtl/accelerator/fill_rect_writer.v','rtl/framebuffer/init_write_monitor.v'):
    assert name in files
assert not any(s in formal for s in ["csi_rx_controller", "i2c_master_ctrl_top", "debug_edb_top debug_edb_top_inst"])
if checkpoint_b:
    assert "assign jtag_inst1_TDO = jtag_inst1_TDI;" not in formal
    assert "sapphire_control u_control" in formal
    assert ".jtag_tdi(jtag_inst1_TDI)" in formal and ".jtag_tdo(jtag_inst1_TDO)" in formal
else:
    assert "assign jtag_inst1_TDO = jtag_inst1_TDI;" in formal, \
        "Retained JTAG requires TDI to remain connected after removing EDB"
# Keep the live CSR consistency check previously mixed with snapshot freezes.
# Derive the offsets from the current sources instead of a checkpoint fingerprint.
rtl = (ROOT / "rtl/control/accel_regs.v").read_text(encoding="utf8")
header = (ROOT / "software/apb_reg_test/accel_regs.h").read_text(encoding="utf8")
doc = (ROOT / "docs/REGISTER_MAP.md").read_text(encoding="utf8")
cases = {int(value, 16) for value in re.findall(r"32'h([0-9A-Fa-f]+):", rtl)}
offsets = {int(value, 16) for _, value in re.findall(
    r"^#define\s+(ACCEL_\w+)\s+0x([0-9A-Fa-f]+)u\s*$", header, re.M)}
documented = {int(value, 16) for value in re.findall(
    r"^\| ([0-9A-Fa-f]{2}) \|", doc, re.M)}
assert cases == offsets == documented, "RTL/header/REGISTER_MAP offsets disagree"
print(f"PASS project: {len(files)} unique, existing design entries; current RGB/control integration")
print(f"PASS register contract: {len(cases)} current RTL/header/documented offsets agree")
