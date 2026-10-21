"""Compile/run the benchmark's native C behavioral tests; no board or RISC-V emulator."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--cc', help='Native C compiler (cc/gcc/clang/cl); MSVC needs its developer environment')
parser.add_argument('--output', type=Path, default=ROOT / 'output/graphics/benchmark_checks')
args = parser.parse_args()
cc = args.cc or next((p for name in ('cc', 'gcc', 'clang', 'cl') if (p := shutil.which(name))), None)
if not cc:
    parser.error('No native C compiler found; pass --cc or use a compiler developer shell')
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
msvc = Path(cc).stem.lower() == 'cl'
exe = out / ('test_accel_benchmark.exe' if msvc or os.name == 'nt' else 'test_accel_benchmark')
includes = [ROOT / 'software/apb_reg_test', ROOT / 'embedded_sw/soc_control/bsp/efinix/EfxSapphireSoc/include']
if msvc:
    command = [cc, '/nologo', '/std:c11', '/O2', '/W4', '/WX', '/TC',
               '/Fe:' + str(exe), '/Fo:' + str(out / 'test_accel_benchmark.obj')]
    command += ['/I' + str(path) for path in includes]
else:
    command = [cc, '-std=c99', '-O2', '-Wall', '-Wextra', '-Werror', '-o', str(exe)]
    command += ['-I' + str(path) for path in includes]
command.append(str(ROOT / 'sim/test_accel_benchmark.c'))
subprocess.run(command, cwd=out, check=True)
subprocess.run([str(exe)], cwd=out, check=True)
