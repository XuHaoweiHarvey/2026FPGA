"""Checkpoint C tests. No Sapphire CPU simulation or Efinity invocation."""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile
ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--full-init',action='store_true')
parser.add_argument('--iverilog',default='iverilog')
parser.add_argument('--vvp',default='vvp')
args=parser.parse_args()
out=Path(tempfile.mkdtemp(prefix='fpga-c-checks-'))
print('Artifacts:',out,flush=True)
def run(cmd):subprocess.run([str(x) for x in cmd],cwd=ROOT,check=True)
def sim(top,files,overrides=()):
 binary=out/(top+str(len(list(out.glob('*.vvp'))))+'.vvp')
 run([args.iverilog,'-g2005-sv','-s',top,*overrides,'-o',binary,*files]);run([args.vvp,binary])
sim('tb_fill_rect_writer',['sim/tb_fill_rect_writer.v','rtl/accelerator/fill_rect_writer.v'])

sim('tb_init_write_monitor',['sim/tb_init_write_monitor.v','rtl/framebuffer/init_write_monitor.v'],
    ['-Ptb_init_write_monitor.FRAME_BEATS=518400'] if args.full_init else [])
run([sys.executable,'scripts/prepare_rgb_sim.py',out])
c_sources=['sim/tb_checkpoint_c.v','rtl/test_pattern/rgb_tpg.v',
 'rtl/framebuffer/rgb_framebuffer.v','rtl/accelerator/graphics_command_queue.v', 'rtl/framebuffer/buffer_manager.v','rtl/framebuffer/video_frame_cdc.v','rtl/framebuffer/read_frame_guard.v','rtl/framebuffer/ddr_write_admission.v','rtl/framebuffer/display_underflow_counter.v','rtl/framebuffer/init_write_monitor.v','rtl/accelerator/fill_rect_writer.v',
 'rtl/control/accel_regs.v','rtl/framebuffer/rgb_unpack128_to64.v','rtl/display/rgb_to_hdmi.v',
 out/'ddr_wr_buffer.v',out/'ddr_rd_buffer.v',out/'DC_FIFO.v',
 'rtl/frame_buffer_V4/bank_switch.v','rtl/frame_buffer_V4/rst_n_piple.v','rtl/user_cvo_axi_v2/cvo_axi_v2.v']
for waits in (0,1,3):
 sim('tb_checkpoint_c',c_sources,[f'-Ptb_checkpoint_c.APB_WAITS={waits}'])
if args.full_init:
 sim('tb_checkpoint_c',c_sources,['-Ptb_checkpoint_c.WIDTH=1920','-Ptb_checkpoint_c.HEIGHT=1080','-Ptb_checkpoint_c.INIT_ONLY=1'])

print('PASS Checkpoint C simulations. Efinity/physical DDR/HDMI hardware validation remains for the user.',flush=True)
