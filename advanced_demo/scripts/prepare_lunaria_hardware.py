"""Isolated v12: original picture, tagged 32px row cache, pipelined Alpha writes."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--compile',action='store_true')
args=parser.parse_args()
target=ROOT/'output/lunaria_v12_hardware'
target.mkdir(parents=True,exist_ok=True)
for folder in ('rtl','ip','embedded_sw','constraints'):
    shutil.copytree(ROOT/folder,target/folder,dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns('build','__pycache__','.metadata'))
for name in ('ti60f225_oob.xml','ti60f225_oob.peri.xml','ti60f225_oob.sdc'):
    shutil.copy2(ROOT/name,target/name)
(target/'software/flash').mkdir(parents=True,exist_ok=True)
shutil.copy2(ROOT/'software/flash/jtag_wait.hex',target/'software/flash/jtag_wait.hex')
top=target/'rtl/ti60f225_oob_top.v'; source=top.read_text(encoding='utf8')
for name in ('DISPLAY_WINDOW_ENABLE','DISPLAY_SCALE2_ENABLE','ALPHA_STREAM_ENABLE',
             'ALPHA_SPRITE_CACHE_ENABLE','ALPHA_WIDE_CACHE_ENABLE'):
    old=f'parameter {name} = 0,'
    assert source.count(old)==1,name
    source=source.replace(old,f'parameter {name} = 1,')
source=source.replace('parameter [31:0] HARDWARE_VERSION = 0,',
                      "parameter [31:0] HARDWARE_VERSION = 32'h000c0000,")
top.write_text(source,encoding='utf8')
paths=[p for folder in ('rtl','constraints','ip') for p in (target/folder).rglob('*')
       if p.is_file() and p.suffix in ('.v','.sv','.vh','.sdc','.hex','.json')]
paths += [target/n for n in ('ti60f225_oob.xml','ti60f225_oob.peri.xml','ti60f225_oob.sdc')]
(target/'source_manifest.json').write_text(json.dumps({
    'hardware_version':'0x000c0000','capabilities':'0x0000fffb','core_hz':100000000,
    'source_window':[640,300,640,480],'presentation_window':[320,60,1280,960],
    'source_cache_bytes':16384,'source_cache_row_pixels':32,'fast_alpha_writes':True,
    'board_tested':False,'sources':{p.relative_to(target).as_posix():hashlib.sha256(p.read_bytes()).hexdigest()
                                  for p in paths}},indent=2)+'\n',encoding='utf8')
print('Prepared',target,flush=True)
if args.compile:
    subprocess.run(['cmd','/c','D:/Efinity/bin/efx_run.bat','ti60f225_oob.xml','--flow','compile'],
                   cwd=target,check=True)
