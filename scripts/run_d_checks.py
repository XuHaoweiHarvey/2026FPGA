"""D manager/CDC and full RGB pipeline checks; no CPU or encrypted IP simulation."""
from pathlib import Path
import argparse,subprocess,sys,tempfile
ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--apb-waits',type=int,nargs='+',default=[0,1,3])
args=parser.parse_args()
out=Path(tempfile.mkdtemp(prefix='fpga-d-checks-'))
print('Artifacts:',out,flush=True)
def run(cmd):subprocess.run([str(x) for x in cmd],cwd=ROOT,check=True)
def sim(top,files,overrides=()):
 binary=out/(top+str(len(list(out.glob('*.vvp'))))+'.vvp')
 run(['iverilog','-g2005-sv','-s',top,*overrides,'-o',binary,*files]);run(['vvp',binary])
d_modules=['rtl/framebuffer/buffer_manager.v','rtl/framebuffer/video_frame_cdc.v','rtl/framebuffer/read_frame_guard.v','rtl/framebuffer/ddr_write_admission.v','rtl/framebuffer/display_underflow_counter.v']
sim('tb_ddr_write_admission',['sim/tb_ddr_write_admission.v',*d_modules])
sim('tb_buffer_manager',['sim/tb_buffer_manager.v',*d_modules])
sim('tb_read_frame_guard',['sim/tb_read_frame_guard.v',*d_modules])
run([sys.executable,'scripts/prepare_rgb_sim.py',out])
sources=['sim/tb_checkpoint_d.v','rtl/test_pattern/rgb_tpg.v','rtl/framebuffer/rgb_framebuffer.v',
 'rtl/framebuffer/init_write_monitor.v','rtl/accelerator/fill_rect_writer.v','rtl/control/accel_regs.v',
 'rtl/framebuffer/rgb_unpack128_to64.v','rtl/display/rgb_to_hdmi.v',out/'ddr_wr_buffer.v',out/'ddr_rd_buffer.v',
 out/'DC_FIFO.v','rtl/frame_buffer_V4/bank_switch.v','rtl/frame_buffer_V4/rst_n_piple.v',
 'rtl/user_cvo_axi_v2/cvo_axi_v2.v',*d_modules]
for waits in args.apb_waits:
 sim('tb_checkpoint_d',sources,[f'-Ptb_checkpoint_d.APB_WAITS={waits}'])
print('PASS D simulations; hardware verification pending.',flush=True)
