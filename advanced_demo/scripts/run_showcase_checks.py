"""Host regression and rasterized previews of the actual showcase firmware."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from render_showcase_previews import main as render_previews

ROOT=Path(__file__).resolve().parents[1]
compiler=next((c for c in ('cl','gcc','clang','cc') if shutil.which(c)),None)
if not compiler:
    raise SystemExit('Use run_showcase_checks.cmd from Windows, or install a C compiler.')
defines=['GAME_SHOWCASE=1','GAME_ENEMY_BULLET_CAPACITY=256','GAME_FULLSCREEN=0',
         'GAME_TEAM_SPRITES=1','GAME_TEAM_BACKGROUND=1','GAME_DISPLAY_WINDOW=1',
         'GAME_WINDOW_HUD_CACHE=1','GAME_ALLOW_SCALE2=1','GAME_STRESS_TUNING=1',
         'GAME_PATH_DIAGNOSTICS=1']
with tempfile.TemporaryDirectory(prefix='showcase-checks-') as folder:
    temp=Path(folder)
    for source in ('test_showcase_game.c','test_showcase_render.c'):
        if not (ROOT/'sim'/source).exists():
            continue
        exe=temp/(Path(source).stem+('.exe' if os.name=='nt' else ''))
        if compiler=='cl':
            command=[compiler,'/nologo','/TC','/W4','/WX']+['/D'+d for d in defines]
            command+=['/I'+str(ROOT/'sim/mock_game'),'/I'+str(ROOT/'sim/mock_uart'),
                      str(ROOT/'sim'/source),str(ROOT/'software/interactive_demo/game_logic.c'),'/Fe:'+str(exe)]
        else:
            command=[compiler,'-std=c99','-Wall','-Wextra','-Werror']+['-D'+d for d in defines]
            command+=['-I',str(ROOT/'sim/mock_game'),'-I',str(ROOT/'sim/mock_uart'),
                      str(ROOT/'sim'/source),str(ROOT/'software/interactive_demo/game_logic.c'),'-o',str(exe)]
        subprocess.run(command,cwd=temp,check=True)
        subprocess.run([str(exe)],cwd=ROOT,check=True)
render_previews()
print('PASS showcase host checks (no board connected)')
