"""Read-only current project/source and register-contract checks (no snapshots)."""
from pathlib import Path
import json
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
             "rtl/framebuffer/cpu_ddr_bridge.v", "rtl/framebuffer/rgb_unpack128_to64.v",
             "rtl/display/rgb_to_hdmi.v"]:
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
for name in ('rtl/accelerator/graphics_engine.v','rtl/accelerator/blit_engine.v',
             'rtl/framebuffer/blit_source_guard.v','rtl/framebuffer/ddr_read_arbiter.v'):
    assert name in files, f'Missing shared-read graphics source: {name}'
assert '.BLIT_ENABLE(1)' in formal and 'ddr_read_arbiter #' in rgb_fb
for name in ('rtl/accelerator/alpha_pixel_pipeline.v','rtl/accelerator/alpha_blit_engine.v'):
    assert name in files, f'Missing Alpha design file: {name}'
control = (ROOT / 'rtl/control/sapphire_control.v').read_text(encoding='utf8')
assert '.BLIT_ENABLE(1)' in control
generated_soc = (ROOT / 'ip/soc_control/soc_control.v').read_text(encoding='utf8')
soc_start = generated_soc.index('module soc_control')
soc_header = generated_soc[soc_start:generated_soc.index(');',soc_start)]
soc_inputs = set(re.findall(r'\binput\s+(?:\[[^]]+\]\s+)?(\w+)',soc_header))
connection_start = control.index('soc_control u_soc_control')
soc_connection_text = control[connection_start:control.index(');',connection_start)]
soc_connections = set(re.findall(r'\.(\w+)\s*\(', soc_connection_text))
assert not (soc_inputs-soc_connections), f'Unconnected generated SoC inputs: {sorted(soc_inputs-soc_connections)}'
assert 'io_memoryClk' in soc_inputs and 'io_ddrA_r_payload_data' in soc_inputs
assert 'io_ddrMasters_0_clk' in soc_inputs
# Reserve the V4 board UART pads without fabricating a UART-enabled SoC/BSP.
peri_ns = {"p": "http://www.efinixinc.com/peri_design_db"}
peripheral = ET.parse(ROOT / 'ti60f225_oob.peri.xml').getroot()
gpios = peripheral.findall('.//p:comp_gpio', peri_ns)
for port, pad, direction in [('uart_rx', 'GPIOL_02', 'input'),
                             ('uart_tx', 'GPIOR_28', 'output')]:
    matches = [gpio for gpio in gpios if gpio.get('gpio_def') == pad]
    assert len(matches) == 1, f'UART pad {pad} must have exactly one assignment'
    assert sum(gpio.get('name') == port for gpio in gpios) == 1
    assert matches[0].get('name') == port and matches[0].get('mode') == direction
    assert matches[0].get('io_standard') == '3.3 V LVCMOS'
    config = matches[0].find('p:' + direction + '_config', peri_ns)
    assert config is not None and config.get('name') == port
    assert re.search(r'\b' + direction + r'\s+wire\s+' + port + r'\b', formal)
    assert re.search(r'\b' + direction + r'\s+wire\s+' + port + r'\b', control)
    assert re.search(r'\.' + port + r'\s*\(\s*' + port + r'\s*\)', formal)
uart_enabled = json.loads((ROOT / 'ip/soc_control/settings.json').read_text(encoding='utf8'))['conf']['UART0']
if uart_enabled == "1'b0":
    assert not any('uart' in name.lower() for name in soc_inputs)
    assert "assign uart_tx = 1'b1;" in control, 'Reserved UART TX must remain idle high'
    uart_status = 'reserved; UART0 disabled, TX idle high'
else:
    assert uart_enabled == "1'b1", f'Unexpected UART0 configuration: {uart_enabled}'
    assert "assign uart_tx = 1'b1;" not in control, \
        'UART0 enabled: replace the reservation driver with regenerated SoC RX/TX connections'
    soc_outputs = set(re.findall(r'\boutput\s+(?:(?:wire|reg)\s+)?(?:\[[^]]+\]\s+)?(\w+)', soc_header))
    bindings = dict(re.findall(r'\.(\w+)\s*\(\s*(\w+)\s*\)', soc_connection_text))
    for signal, ports in [('uart_rx', soc_inputs), ('uart_tx', soc_outputs)]:
        assert any('uart' in name.lower() and bindings.get(name) == signal for name in ports), \
            f'Connect {signal} to the actual regenerated SoC UART port'
    bsp_header = (ROOT / 'embedded_sw/soc_control/bsp/efinix/EfxSapphireSoc/include/soc.h').read_text(encoding='utf8')
    assert re.search(r'^#define\s+SYSTEM_UART_0_IO_CTRL\s+', bsp_header, re.M), \
        'Regenerate the UART0 BSP before building the game'
    uart_status = 'SoC/BSP connected; physical link still requires board validation'
assert 'localparam COLOR_KEY_ENABLE = 1;' in formal
assert formal.count('.COLOR_KEY_ENABLE(COLOR_KEY_ENABLE)') == 2
assert 'localparam ALPHA_ENABLE = 1;' in formal
assert formal.count('.ALPHA_ENABLE(ALPHA_ENABLE)') == 2
assert '.ALPHA_ENABLE(ALPHA_ENABLE)' in control and '.ALPHA_ENABLE(ALPHA_ENABLE)' in rgb_fb
assert '.COLOR_KEY_ENABLE(COLOR_KEY_ENABLE)' in control and '.COLOR_KEY_ENABLE(COLOR_KEY_ENABLE)' in rgb_fb
for port in ('cmd_op','cmd_src_addr','cmd_src_stride'):
    assert len(re.findall(r'\.'+port+r'\s*\(',formal))==2, f'Unpaired graphics command: {port}'
assert not any(s in formal for s in ["csi_rx_controller", "i2c_master_ctrl_top", "debug_edb_top debug_edb_top_inst"])
if checkpoint_b:
    assert "assign jtag_inst1_TDO = jtag_inst1_TDI;" not in formal
    assert re.search(r'sapphire_control\s*#\([^;]+\)\s*u_control\s*\(', formal)
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
assert '0x00060000' in header and "32'h00060000" in rtl
assert '0x000001FB' in header and "32'h000001FB" in rtl
assert 'ACCEL_CAP_ALPHA' in header and '0xE0u' in header and '0xE4u' in header
print(f"PASS project: {len(files)} unique, existing design entries; current RGB/control integration")
print(f"PASS register contract: {len(cases)} current RTL/header/documented offsets agree")
print(f"PASS V4 UART pad reservation: RX R4/GPIOL_02, TX R14/GPIOR_28; {uart_status}")
