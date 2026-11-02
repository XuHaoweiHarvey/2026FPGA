"""Prepare isolated v9/v10 window projects without touching any stable build."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--variant', choices=('stream', 'cache'), required=True)
parser.add_argument('--flow', choices=('prepare', 'map', 'compile'), default='prepare')
parser.add_argument('--efinity', type=Path, default=Path('D:/Efinity'))
args = parser.parse_args()
target = ROOT / ('output/window640_alpha_' + args.variant + '_hardware')
target.mkdir(parents=True, exist_ok=True)
for folder in ('rtl', 'ip', 'embedded_sw', 'constraints'):
    shutil.copytree(ROOT/folder, target/folder, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns('build', '__pycache__', '.metadata'))
for name in ('ti60f225_oob.xml', 'ti60f225_oob.peri.xml', 'ti60f225_oob.sdc'):
    shutil.copy2(ROOT/name, target/name)
(target/'software/flash').mkdir(parents=True, exist_ok=True)
shutil.copy2(ROOT/'software/flash/jtag_wait.hex', target/'software/flash/jtag_wait.hex')
top = target/'rtl/ti60f225_oob_top.v'
text = top.read_text(encoding='utf8')
version = 0x90000 if args.variant == 'stream' else 0xA0000
replacements = {'parameter DISPLAY_WINDOW_ENABLE = 0,': 'parameter DISPLAY_WINDOW_ENABLE = 1,',
                'parameter ALPHA_STREAM_ENABLE = 0,': 'parameter ALPHA_STREAM_ENABLE = 1,',
                'parameter [31:0] HARDWARE_VERSION = 0,': f"parameter [31:0] HARDWARE_VERSION = 32'h{version:08x},"}
if args.variant == 'cache':
    replacements['parameter ALPHA_SPRITE_CACHE_ENABLE = 0,'] = 'parameter ALPHA_SPRITE_CACHE_ENABLE = 1,'
for old, new in replacements.items():
    assert text.count(old) == 1, old
    text = text.replace(old, new)
top.write_text(text, encoding='utf8')
sources = [p for folder in ('rtl','constraints','ip') for p in (target/folder).rglob('*')
           if p.is_file() and p.suffix in ('.v','.sv','.vh','.sdc','.hex','.json')]
manifest = {'hardware_version': f'0x{version:08x}', 'variant': args.variant,
            'display_window': [640,300,640,480], 'output': '1920x1080@60Hz',
            'board_tested': False, 'source_cache_bytes': 1024 if args.variant == 'cache' else 0,
            'sources': {p.relative_to(target).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}}
(target/'source_manifest.json').write_text(json.dumps(manifest, indent=2)+'\n', encoding='utf8')
print('Prepared isolated Alpha project:', target, flush=True)
if args.flow != 'prepare':
    subprocess.run(['cmd','/c',str(args.efinity/'bin/efx_run.bat'),
                    'ti60f225_oob.xml','--flow',args.flow],cwd=target,check=True)
