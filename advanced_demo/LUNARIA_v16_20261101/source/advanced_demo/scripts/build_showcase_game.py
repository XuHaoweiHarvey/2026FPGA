"""Build independent compact-campaign and unchanged-art 512-shot comparison ELFs."""
from pathlib import Path
import argparse
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--ide-root',type=Path,default=Path('D:/Efinity/efinity-riscv-ide-2026.1'))
args=parser.parse_args()
common=['GAME_FLASH_ENABLE=0','GAME_TEAM_SPRITES=1','GAME_TEAM_BACKGROUND=1','GAME_FULLSCREEN=0',
        'GAME_REQUIRE_QUEUE=1','GAME_PATH_DIAGNOSTICS=1','GAME_SUBMIT_TIMING=0','GAME_DISPLAY_WINDOW=1',
        'GAME_STRESS_TUNING=1','GAME_WINDOW_HUD_CACHE=1','GAME_ALLOW_SCALE2=1']
for name,showcase,capacity in (('game-showcase',1,256),('game-showcase-benchmark',0,512)):
    command=[sys.executable,str(ROOT/'scripts/build_apb_software.py'),'--program','game','--opt','O2',
             '--ide-root',str(args.ide_root),'--output',str(ROOT/'software/interactive_demo/build'/name)]
    for define in common+[f'GAME_SHOWCASE={showcase}',f'GAME_ENEMY_BULLET_CAPACITY={capacity}']:
        command+=['--define',define]
    subprocess.run(command,cwd=ROOT,check=True)
