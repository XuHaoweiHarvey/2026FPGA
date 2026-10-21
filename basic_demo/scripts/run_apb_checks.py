"""Standalone Checkpoint B APB tests. Does not simulate Sapphire or modify the A project."""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--iverilog', default='iverilog')
parser.add_argument('--vvp', default='vvp')
args = parser.parse_args()
out = Path(tempfile.mkdtemp(prefix='fpga-apb-checks-'))
print(f'Simulation artifacts: {out}', flush=True)
for waits in (0, 1, 3):
    binary = out / f'accel_regs-wait{waits}.vvp'
    subprocess.run([args.iverilog, '-g2005-sv', '-s', 'tb_accel_regs',
                    f'-Ptb_accel_regs.WAIT_CYCLES={waits}', '-o', str(binary),
                    'sim/tb_accel_regs.v', 'rtl/control/accel_regs.v'], cwd=ROOT, check=True)
    subprocess.run([args.vvp, str(binary)], cwd=ROOT, check=True)
    for color_key in (0,1):
        graphics_binary = out / f'graphics-regs-wait{waits}-key{color_key}.vvp'
        subprocess.run([args.iverilog,'-g2005-sv','-s','tb_graphics_regs',
                        f'-Ptb_graphics_regs.WAIT_CYCLES={waits}',
                        f'-Ptb_graphics_regs.COLOR_KEY={color_key}','-o',str(graphics_binary),
                        'sim/tb_graphics_regs.v','rtl/control/accel_regs.v'],cwd=ROOT,check=True)
        subprocess.run([args.vvp,str(graphics_binary)],cwd=ROOT,check=True)
print('PASS standalone APB3 B compatibility and v4/v5 graphics contracts; this run does not simulate the CPU or validate hardware.')
