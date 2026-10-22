"""Focused Alpha arithmetic, DMA, source-window, APB and CPU sprite regressions."""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--iverilog', default='iverilog')
parser.add_argument('--vvp', default='vvp')
args = parser.parse_args()
out = Path(tempfile.mkdtemp(prefix='fpga-alpha-checks-'))
print(f'Alpha artifacts: {out}', flush=True)

def sim(name, top, sources, overrides=()):
    binary=out/(name+'.vvp')
    subprocess.run([args.iverilog,'-g2005-sv','-Wall','-s',top,*overrides,
                    '-o',str(binary),*sources],cwd=ROOT,check=True)
    subprocess.run([args.vvp,str(binary)],cwd=ROOT,check=True)

sim('pixels','tb_alpha_pixel_pipeline',[
    'sim/tb_alpha_pixel_pipeline.v','rtl/accelerator/alpha_pixel_pipeline.v'])
for case,override in [('pixels',()),('read-error',('INJECT_RRESP=1',)),
                      ('write-error',('INJECT_BRESP=1',)),
                      ('early-last',('MALFORMED_RLAST=1',)),
                      ('late-last',('MALFORMED_RLAST=2',)),
                      ('timeout-drain',('TIMEOUT_READ=1',))]:
    sim('blit-'+case,'tb_alpha_blit_engine',[
        'sim/tb_alpha_blit_engine.v','rtl/accelerator/alpha_pixel_pipeline.v',
        'rtl/accelerator/alpha_blit_engine.v'],[
        '-Ptb_alpha_blit_engine.'+x for x in override])
sim('sprite-guard','tb_blit_source_guard',[
    'sim/tb_blit_source_guard.v','rtl/framebuffer/blit_source_guard.v'],[
    '-Ptb_blit_source_guard.FRAME_WIDTH=64',
    '-Ptb_blit_source_guard.FRAME_HEIGHT=48',
    '-Ptb_blit_source_guard.ALPHA_ENABLE=1'])
for wait in (0,1,3):
    sim(f'apb-alpha-wait{wait}','tb_m2_asset_regs',[
        'sim/tb_m2_asset_regs.v','rtl/control/accel_regs.v'],[
        f'-Ptb_m2_asset_regs.WAIT_CYCLES={wait}',
        '-Ptb_m2_asset_regs.ALPHA_ENABLE=1'])
sim('cpu-sprite','tb_cpu_ddr_bridge',[
    'sim/tb_cpu_ddr_bridge.v','rtl/framebuffer/cpu_ddr_bridge.v'],[
    '-Ptb_cpu_ddr_bridge.SPRITE_ENABLE=1'])
print('PASS Alpha arithmetic/DMA/source guard/APB/sprite bridge regression.')
