"""A/B video regressions plus current formal top elaboration. All generated simulation artifacts stay outside the repo."""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--iverilog", default="iverilog")
parser.add_argument("--vvp", default="vvp")
parser.add_argument("--quick", action="store_true", help="Skip full-resolution DDR mock run")
parser.add_argument("--pulse-only", action="store_true", help="Fast asynchronous frame_start glitch regression")
parser.add_argument("--top-only", action="store_true", help="Elaborate both display modes without rerunning video simulations")
args = parser.parse_args()
output = Path(tempfile.mkdtemp(prefix="fpga-rgb-checks-"))
print(f"Simulation artifacts: {output}", flush=True)

def run(command):
    subprocess.run([str(x) for x in command], cwd=ROOT, check=True)

def simulate(top, sources, overrides=()):
    if args.top_only:
        return
    print(f"Running {top} {' '.join(overrides)}", flush=True)
    binary = output / (top + ("-" + str(len(list(output.glob('*.vvp'))))) + ".vvp")
    run([args.iverilog, "-g2005-sv", "-s", top, *overrides, "-o", binary, *sources])
    run([args.vvp, binary])

run([sys.executable, ROOT / "scripts/check_project.py"])
simulate("tb_rgb_tpg_pulse", ["sim/tb_rgb_tpg_pulse.v", "rtl/test_pattern/rgb_tpg.v"])
if args.pulse_only:
    sys.exit(0)
run([sys.executable, ROOT / "scripts/prepare_rgb_sim.py", output])
fifo = ROOT / "rtl/frame_buffer_V4/DC_FIFO.v"
unpack = ROOT / "rtl/framebuffer/rgb_unpack128_to64.v"
serializer = ROOT / "rtl/display/rgb_to_hdmi.v"
framebuffer_sources = ["sim/tb_rgb_framebuffer.v", "rtl/framebuffer/rgb_framebuffer.v", "rtl/accelerator/graphics_command_queue.v", 'rtl/framebuffer/buffer_manager.v','rtl/framebuffer/video_frame_cdc.v','rtl/framebuffer/read_frame_guard.v','rtl/framebuffer/ddr_write_admission.v','rtl/framebuffer/display_underflow_counter.v', "rtl/framebuffer/init_write_monitor.v", "rtl/accelerator/fill_rect_writer.v", unpack,
    output / "ddr_wr_buffer.v", output / "ddr_rd_buffer.v",
    "rtl/frame_buffer_V4/bank_switch.v", "rtl/frame_buffer_V4/rst_n_piple.v", output / "DC_FIFO.v"]
simulate("tb_rgb_tpg", ["sim/tb_rgb_tpg.v", "rtl/test_pattern/rgb_tpg.v"])
simulate("tb_rgb_tpg", ["sim/tb_rgb_tpg.v", "rtl/test_pattern/rgb_tpg.v"],
    ["-Ptb_rgb_tpg.H_ACTIVE=64", "-Ptb_rgb_tpg.V_ACTIVE=8",
     "-Ptb_rgb_tpg.H_BLANK=12", "-Ptb_rgb_tpg.V_BLANK=4"])
simulate("tb_rgb_slots", ["sim/tb_rgb_slots.v", "rtl/frame_buffer_V4/bank_switch.v"])
display_sources = ["sim/tb_rgb_display.v", serializer, unpack, fifo, "rtl/user_cvo_axi_v2/cvo_axi_v2.v"]
simulate("tb_rgb_display", display_sources)
simulate("tb_fifo_sequence", ["sim/tb_fifo_sequence.v", fifo])
simulate("tb_rgb_framebuffer", framebuffer_sources)
simulate("tb_rgb_pipeline", ["sim/tb_rgb_pipeline.v", "rtl/test_pattern/rgb_tpg.v",
    "rtl/framebuffer/rgb_framebuffer.v", "rtl/accelerator/graphics_command_queue.v", 'rtl/framebuffer/buffer_manager.v','rtl/framebuffer/video_frame_cdc.v','rtl/framebuffer/read_frame_guard.v','rtl/framebuffer/ddr_write_admission.v','rtl/framebuffer/display_underflow_counter.v', "rtl/framebuffer/init_write_monitor.v", "rtl/accelerator/fill_rect_writer.v", unpack, serializer, output / "ddr_wr_buffer.v",
    output / "ddr_rd_buffer.v", output / "DC_FIFO.v", "rtl/frame_buffer_V4/bank_switch.v",
    "rtl/frame_buffer_V4/rst_n_piple.v", "rtl/user_cvo_axi_v2/cvo_axi_v2.v"])
if not args.quick:
    simulate("tb_rgb_framebuffer", framebuffer_sources,
        ["-Ptb_rgb_framebuffer.WIDTH=1920", "-Ptb_rgb_framebuffer.HEIGHT=1080"])
print("Elaborating formal top with port-only DDR/HDMI stubs; no CPU simulation", flush=True)
control_sources = []
if (ROOT / 'ip/soc_control/soc_control.v').exists():
    control_sources = ['rtl/control/sapphire_control.v', 'rtl/control/accel_regs.v']
top_command=[args.iverilog, "-g2005-sv", "-Irtl", "-Irtl/ddr3_controller", "-s", "ti60f225_oob_top",
    "-o", output / "top-ports.vvp", "rtl/ti60f225_oob_top.v", "rtl/reset.v",
    "rtl/test_pattern/rgb_tpg.v", "rtl/framebuffer/rgb_framebuffer.v", "rtl/accelerator/graphics_command_queue.v", 'rtl/framebuffer/buffer_manager.v','rtl/framebuffer/video_frame_cdc.v','rtl/framebuffer/read_frame_guard.v','rtl/framebuffer/ddr_write_admission.v','rtl/framebuffer/display_underflow_counter.v', "rtl/framebuffer/init_write_monitor.v", "rtl/accelerator/fill_rect_writer.v", unpack, serializer,
    "rtl/frame_buffer_V4/bank_switch.v", "rtl/frame_buffer_V4/rst_n_piple.v",
    output / "ddr_wr_buffer.v", output / "ddr_rd_buffer.v", output / "DC_FIFO.v",
    "rtl/user_cvo_axi_v2/cvo_axi_v2.v", "rtl/gamma_conrrection/gamma_correction.v",
    "rtl/true_dual_port_ram.v",
    output / "ip_port_stubs.v", *control_sources,
    'rtl/framebuffer/cpu_ddr_bridge.v',
    'rtl/accelerator/alpha_pixel_pipeline.v','rtl/accelerator/alpha_blit_engine.v','rtl/accelerator/graphics_engine.v','rtl/accelerator/blit_engine.v',
    'rtl/framebuffer/blit_source_guard.v','rtl/framebuffer/ddr_read_arbiter.v',
    'rtl/framebuffer/window_display_reader.v','rtl/framebuffer/window_axis_composer.v']
run(top_command)
run([*top_command[:1], "-Pti60f225_oob_top.DISPLAY_WINDOW_ENABLE=1", *top_command[1:]])
run([*top_command[:1], "-Pti60f225_oob_top.DISPLAY_WINDOW_ENABLE=1",
     "-Pti60f225_oob_top.ALPHA_STREAM_ENABLE=1", "-Pti60f225_oob_top.ALPHA_SPRITE_CACHE_ENABLE=1",
     "-Pti60f225_oob_top.HARDWARE_VERSION=655360", *top_command[1:]])
print("PASS " + ("fullscreen/window top elaboration" if args.top_only else
      "RGB regression and current top elaboration") +
      ". No encrypted-IP or hardware verification.", flush=True)
