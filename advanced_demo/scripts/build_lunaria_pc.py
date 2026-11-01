"""Build the desktop viewer and an independent inline-pool oracle."""
from pathlib import Path
import os
import hashlib
import json
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
OUT = Path(os.environ.get('LUNARIA_OUTPUT_DIR', str(ROOT/'output/lunaria')))
sources = [ROOT/'software/lunaria'/f'{name}.c' for name in
           ('lunaria','lunaria_render','lunaria_pool','lunaria_pc')]
OUT.mkdir(exist_ok=True,parents=True)
with tempfile.TemporaryDirectory(prefix='lunaria-pc-') as tmp:
    probe=Path(tmp)/'pool-test.exe'
    subprocess.run(['cl','/nologo','/TC','/W4','/WX','/O2','/MT','/DLN_EXTERNAL_POOL=1',
                    str(ROOT/'sim/test_lunaria_pool.c'),str(ROOT/'software/lunaria/lunaria_pool.c'),
                    '/Fe:'+str(probe)],cwd=tmp,check=True)
    result=subprocess.run([str(probe)],text=True,capture_output=True,check=True)
    print(result.stdout,end='')
    (OUT/'verification/pool-checks.json').write_text(json.dumps({'status':'passed','output':result.stdout,
        'sources':{str(p.relative_to(ROOT)).replace('\\','/'):hashlib.sha256(p.read_bytes()).hexdigest()
                   for p in (ROOT/'sim/test_lunaria_pool.c',ROOT/'software/lunaria/lunaria_pool.c',ROOT/'software/lunaria/lunaria_pool.h')}},indent=2)+'\n',encoding='utf8')
    for name,flags in [('lunaria_pc', ['/DLN_EXTERNAL_POOL=1']),('lunaria_oracle', []),
                       ('lunaria_full_rects',['/DLN_EXTERNAL_POOL=1','/DLN_FULL_SPRITE_RECTS=1']),
                       ('lunaria_legacy_lasers',['/DLN_EXTERNAL_POOL=1','/DLN_LEGACY_LASERS=1'])]:
        subprocess.run(['cl','/nologo','/TC','/W4','/WX','/O2','/MT','/LD',*flags,
                        *map(str,sources),'/Fe:'+str(OUT/(name+'.dll')),
                        '/link','/INCREMENTAL:NO','/IMPLIB:'+str(Path(tmp)/(name+'.lib'))],
                       cwd=tmp,check=True)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
record={'sources':{p.relative_to(ROOT).as_posix():sha(p) for p in sorted((ROOT/'software/lunaria').glob('*.[ch]'))},
        'dlls':{name:sha(OUT/name) for name in ('lunaria_pc.dll','lunaria_oracle.dll','lunaria_full_rects.dll','lunaria_legacy_lasers.dll')}}
(OUT/'pc-build-info.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf8')
print('PASS built desktop DLL with the board pager and inline-pool oracle')
