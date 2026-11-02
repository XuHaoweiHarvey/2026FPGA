"""Run the exact production accel_init C body with read-only APB fixtures."""
from pathlib import Path
import os
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
API = ROOT/'software/apb_reg_test/accel_api.h'
sys.path.insert(0,str(ROOT/'tools'))
from game_debug_bridge import ElfImage


def main():
    elf = ROOT/'software/lunaria/build/lunaria.elf'
    assert ElfImage(elf).symbol_u32('g_lunaria_v12_compatible') == 0x8000
    compiler = next((c for c in ('cl','gcc','clang','cc') if shutil.which(c)), None)
    if not compiler:
        raise SystemExit('Run from a Visual Studio compiler environment')
    source = API.read_text(encoding='utf8')
    # Keep declarations, feature defaults and the complete production function.
    # Only architecture-specific MMIO primitives and unrelated API functions
    # are omitted. No version/capability condition is rewritten for this test.
    prefix = source.split('static inline void accel_write(')[0]
    body = source.split('static inline uint32_t accel_init(void) {',1)[1].split(
        '\nstatic inline uint32_t accel_error(void)',1)[0]
    extracted = prefix+'static inline uint32_t accel_init(void) {'+body+'\n#endif\n'
    results = []
    with tempfile.TemporaryDirectory(prefix='lunaria-startup-') as folder:
        temp = Path(folder)
        (temp/'accel_init_under_test.h').write_text(extracted,encoding='utf8')
        includes = [temp,ROOT/'software/apb_reg_test',
                    ROOT/'embedded_sw/soc_control/bsp/efinix/EfxSapphireSoc/include']
        for window,scale,wide,beam in ((0,0,0,0),(1,0,0,0),(1,1,0,0),(1,1,1,0),(1,1,1,1)):
            definitions = [f'GAME_DISPLAY_WINDOW={window}',f'GAME_ALLOW_SCALE2={scale}',
                           f'GAME_ALLOW_WIDE_CACHE={wide}',f'GAME_ALLOW_BEAM={beam}','ACCEL_POLL_LIMIT=4']
            exe = temp/('startup.exe' if os.name=='nt' else 'startup')
            if compiler == 'cl':
                flags = ['/nologo','/TC','/W4','/WX','/O2',
                         *['/D'+d for d in definitions],*['/I'+str(p) for p in includes],'/Fe:'+str(exe)]
            else:
                flags = ['-std=c99','-Wall','-Wextra','-Werror','-Wno-unused-variable','-O2',
                         *['-D'+d for d in definitions],*['-I'+str(p) for p in includes],'-o',str(exe)]
            subprocess.run([compiler,*flags,str(ROOT/'sim/test_lunaria_startup.c')],cwd=temp,check=True)
            run = subprocess.run([str(exe)],cwd=temp,check=True,capture_output=True,text=True)
            print(run.stdout,end='')
            results.append({'defines':definitions,'output':run.stdout.strip()})
    paths = ('software/apb_reg_test/accel_api.h','software/apb_reg_test/accel_regs.h',
             'sim/test_lunaria_startup.c','scripts/run_lunaria_startup_checks.py',
             'scripts/build_lunaria.py','software/lunaria/main.c')
    report = {'status':'passed','board_tested':False,
              'elf_sha256':hashlib.sha256(elf.read_bytes()).hexdigest(),
              'scope':'Exact production accel_init body compiled natively; APB behavior fixtures, no DDR/HDMI timing',
              'configurations':results,
              'sources':{name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in paths}}
    (Path(os.environ.get('LUNARIA_OUTPUT_DIR', str(ROOT/'output/lunaria')))/'verification/startup-checks.json').write_text(
        json.dumps(report,indent=2)+'\n',encoding='utf8')


if __name__ == '__main__':
    main()
