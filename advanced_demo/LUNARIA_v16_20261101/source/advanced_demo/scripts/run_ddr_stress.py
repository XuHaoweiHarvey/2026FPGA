"""Concurrent full-resolution DDR display pressure; actual pipeline, write-biased AXI model."""
from pathlib import Path
import argparse,subprocess,sys,tempfile
ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--apb-waits',type=int,nargs='+',default=[0,1,3])
parser.add_argument('--small',action='store_true')
parser.add_argument('--return-delay',type=int,default=64)
parser.add_argument('--unthrottled',action='store_true',help='negative control: old unbounded writer admission')
parser.add_argument('--simulator',choices=['iverilog','modelsim'],default='iverilog')
parser.add_argument('--modelsim-bin',type=Path,default=Path('D:/ModelSim/win64'))
args=parser.parse_args()
out=Path(tempfile.mkdtemp(prefix='fpga-ddr-stress-'))
print('Artifacts:',out,flush=True)
def run(cmd):subprocess.run([str(x) for x in cmd],cwd=ROOT,check=True)
def sim(top,files,overrides=()):
 if args.simulator=='iverilog':
  binary=out/(top+str(len(list(out.glob('*.vvp'))))+'.vvp')
  run(['iverilog','-g2005-sv','-s',top,*overrides,'-o',binary,*files]);run(['vvp',binary])
 else:
  index=len(list(out.glob('run-*.log')))
  if index==0:
   subprocess.run([str(args.modelsim_bin/'vlib.exe'),'work'],cwd=out,check=True,capture_output=True)
   compiled=subprocess.run([str(args.modelsim_bin/'vlog.exe'),'-sv','-quiet',*[str((ROOT/f).resolve()) for f in files]],cwd=out,capture_output=True,text=True)
   (out/'compile.log').write_text(compiled.stdout+compiled.stderr,encoding='utf8')
   if compiled.returncode: print(compiled.stdout,compiled.stderr);compiled.check_returncode()
  gs=['-g'+o.split('.',1)[1] for o in overrides]
  result=subprocess.run([str(args.modelsim_bin/'vsim.exe'),'-c','-quiet','-onfinish','exit',*gs,'work.'+top,
   '-do','run -all; quit -code 0 -f'],cwd=out,capture_output=True,text=True)
  log=result.stdout+result.stderr
  (out/f'run-{index}.log').write_text(log,encoding='utf8')
  for line in log.splitlines():
   if any(x in line for x in ('PASS','FATAL','Fatal','Error','STRESS','SERVICE','Writer rate','license')):print(line,flush=True)
  if result.returncode or 'PASS STRESS' not in log:
   print(log[-4000:]);raise RuntimeError('ModelSim stress failed; see '+str(out))

d_modules=['rtl/framebuffer/buffer_manager.v','rtl/framebuffer/video_frame_cdc.v','rtl/framebuffer/read_frame_guard.v','rtl/framebuffer/ddr_write_admission.v','rtl/framebuffer/display_underflow_counter.v']

run([sys.executable,'scripts/prepare_rgb_sim.py',out])
sources=['sim/tb_ddr_display_stress.v','rtl/test_pattern/rgb_tpg.v','rtl/framebuffer/rgb_framebuffer.v','rtl/accelerator/graphics_command_queue.v',
 'rtl/framebuffer/init_write_monitor.v','rtl/accelerator/fill_rect_writer.v','rtl/control/accel_regs.v',
 'rtl/framebuffer/rgb_unpack128_to64.v','rtl/display/rgb_to_hdmi.v',out/'ddr_wr_buffer.v',out/'ddr_rd_buffer.v',
 out/'DC_FIFO.v','rtl/frame_buffer_V4/bank_switch.v','rtl/frame_buffer_V4/rst_n_piple.v',
 'rtl/user_cvo_axi_v2/cvo_axi_v2.v',*d_modules]
for waits in args.apb_waits:
 sim('tb_ddr_display_stress',sources,[f'-Ptb_ddr_display_stress.APB_WAITS={waits}',f'-Ptb_ddr_display_stress.RETURN_DELAY={args.return_delay}',f'-Ptb_ddr_display_stress.SERVICE_ENABLE={int(not args.unthrottled)}',*(['-Ptb_ddr_display_stress.WIDTH=512','-Ptb_ddr_display_stress.HEIGHT=64'] if args.small else [])])
print('PASS DDR display pressure; hardware verification pending.',flush=True)
