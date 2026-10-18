"""D manager/CDC and full RGB pipeline checks; no CPU or encrypted IP simulation."""
from pathlib import Path
import argparse,subprocess,sys,tempfile
ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--apb-waits',type=int,nargs='+',default=[0,1,3])
parser.add_argument('--graphics',action='store_true',help='Enable formal APB/shared-read BLIT integration scenarios')
parser.add_argument('--negative-control',choices=['display-data','display-quota'],
                    help='With --graphics, intentionally miswire a temporary copy and require the matching checker to fail')
args=parser.parse_args()
if args.negative_control and not args.graphics:
 parser.error('--negative-control requires --graphics')
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
if args.graphics:
 sources.extend(['rtl/accelerator/graphics_engine.v','rtl/accelerator/blit_engine.v',
                 'rtl/framebuffer/blit_source_guard.v','rtl/framebuffer/ddr_read_arbiter.v'])
if args.negative_control:
 text=(ROOT/'rtl/framebuffer/rgb_framebuffer.v').read_text(encoding='utf8')
 if args.negative_control=='display-data':
  original='.rlast(display_rlast), .rvalid(display_rvalid), .rready(display_rready), .rresp(display_rresp)'
  replacement=original.replace('.rvalid(display_rvalid)','.rvalid(rvalid)')
  expected="Display reader received another client's response"
 else:
  original='.arvalid(display_arvalid),.arready(display_arready),.rvalid(display_rvalid),.rready(display_rready),.reader_outstanding(reader_outstanding)'
  replacement=original.replace('.rvalid(display_rvalid),.rready(display_rready)', '.rvalid(rvalid),.rready(rready)')
  expected='BLIT read counted as display write-admission quota'
 assert text.count(original)==1,'Negative control mutation must have exactly one target'
 broken=out/'broken_framebuffer.v'
 broken.write_text(text.replace(original,replacement),encoding='utf8')
 sources[sources.index('rtl/framebuffer/rgb_framebuffer.v')]=broken
for waits in args.apb_waits:
 overrides=[f'-Ptb_checkpoint_d.APB_WAITS={waits}',f'-Ptb_checkpoint_d.GRAPHICS={int(args.graphics)}']
 if args.negative_control:
  binary=out/f'negative-{waits}.vvp'
  run(['iverilog','-g2005-sv','-s','tb_checkpoint_d',*overrides,'-o',binary,*sources])
  result=subprocess.run(['vvp',str(binary)],cwd=ROOT,text=True,capture_output=True)
  assert result.returncode!=0 and expected in result.stdout,result.stdout+result.stderr
  print(f'PASS negative control {args.negative_control}: checker rejected the intentional miswire',flush=True)
 else:
  sim('tb_checkpoint_d',sources,overrides)
print('PASS D simulations; hardware verification pending.',flush=True)
