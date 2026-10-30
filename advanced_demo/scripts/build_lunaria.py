"""Build independent LUNARIA firmware using the existing v10/v11 interface."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--ide-root',type=Path,default=Path('D:/Efinity/efinity-riscv-ide-2026.1'))
parser.add_argument('--prepare-assets',action='store_true',help='Requires Pillow and local system fonts')
args = parser.parse_args()
if args.prepare_assets:
    subprocess.run([sys.executable,str(ROOT/'scripts/prepare_lunaria_assets.py')],cwd=ROOT,check=True)
subprocess.run([sys.executable,str(ROOT/'scripts/build_apb_software.py'),
                '--program','lunaria','--ide-root',str(args.ide_root),'--opt','O2',
                '--define','GAME_DISPLAY_WINDOW=1','--define','GAME_ALLOW_SCALE2=1'],
               cwd=ROOT,check=True)
source_files = sorted((ROOT/'software/lunaria').glob('*.c')) + sorted((ROOT/'software/lunaria').glob('*.h'))
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
build = {'elf_sha256':sha(ROOT/'software/lunaria/build/lunaria.elf'),
         'sources':{p.relative_to(ROOT).as_posix():sha(p) for p in source_files},
         'assets':{name:sha(ROOT/'output/lunaria'/name) for name in ('atlas.argb','background.argb','assets.json')}}
(ROOT/'software/lunaria/build/build-info.json').write_text(json.dumps(build,indent=2)+'\n',encoding='utf8')
