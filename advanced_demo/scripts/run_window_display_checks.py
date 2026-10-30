"""Full-resolution window read/composition and original protection regressions."""
from pathlib import Path
import argparse
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--units-only", action="store_true", help="Run guard/admission/swap units without repeating full-resolution scans")
parser.add_argument("--scale2", action="store_true", help="Also verify 2x display with the same DDR beat count")
args = parser.parse_args()
out = Path(tempfile.mkdtemp(prefix="fpga-window-checks-"))
print("Simulation artifacts:", out, flush=True)
def run(*args):
    subprocess.run([str(a) for a in args], cwd=ROOT, check=True)
run(sys.executable, "scripts/prepare_rgb_sim.py", out)
sources = ["sim/tb_window_display.v", "rtl/framebuffer/window_display_reader.v",
           "rtl/framebuffer/window_axis_composer.v", "rtl/framebuffer/window_scale2_composer.v", "rtl/framebuffer/read_frame_guard.v",
           "rtl/framebuffer/buffer_manager.v", "rtl/framebuffer/ddr_read_arbiter.v",
           "rtl/framebuffer/ddr_write_admission.v", "rtl/framebuffer/video_frame_cdc.v",
           "rtl/user_cvo_axi_v2/cvo_axi_v2.v", "rtl/display/rgb_to_hdmi.v", out/"DC_FIFO.v"]
if args.scale2:
    run("iverilog", "-g2005-sv", "-s", "tb_window_scale2", "-o", out/"scale2-unit.vvp",
        "sim/tb_window_scale2.v", "rtl/framebuffer/window_scale2_composer.v")
    run("vvp", out/"scale2-unit.vvp")
if not args.units_only:
    run("iverilog", "-g2005-sv", "-s", "tb_window_display", "-o", out/"window.vvp", *sources)
    run("vvp", out/"window.vvp")
    run("iverilog", "-g2005-sv", "-s", "tb_window_display",
        "-Ptb_window_display.REAL_CVO=1", "-o", out/"window-cvo.vvp", *sources)
    run("vvp", out/"window-cvo.vvp")
    if args.scale2:
        for cvo in (0, 1):
            image = out/f"scale2-{cvo}.vvp"
            run("iverilog", "-g2005-sv", "-s", "tb_window_display",
                "-Ptb_window_display.SCALE2=1", f"-Ptb_window_display.REAL_CVO={cvo}",
                "-o", image, *sources)
            run("vvp", image)
for top, module in (("tb_read_frame_guard", "read_frame_guard"),
                    ("tb_window_guard", "read_frame_guard"),
                    ("tb_ddr_write_admission", "ddr_write_admission"),
                    ("tb_window_admission", "ddr_write_admission"),
                    ("tb_buffer_manager", "buffer_manager")):
    run("iverilog", "-g2005-sv", "-s", top, "-o", out/(top+".vvp"),
        "sim/"+top+".v", "rtl/framebuffer/"+module+".v",
        "rtl/framebuffer/display_underflow_counter.v", "rtl/framebuffer/video_frame_cdc.v")
    run("vvp", out/(top+".vvp"))
print("PASS " + ("guard/admission/swap units" if args.units_only else
      "window scan and original full-screen guard/admission/swap regressions"), flush=True)
