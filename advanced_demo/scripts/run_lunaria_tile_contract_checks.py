"""Exercise batch barriers, exact ordered XRGB, idle flush and both Back bases."""
from pathlib import Path
import hashlib,json,subprocess
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'output/lunaria_v16_contract';OUT.mkdir(exist_ok=True)
files=['sim/tb_lunaria_tile_contract.v','rtl/accelerator/tiled_graphics_engine.v',
       'rtl/accelerator/graphics_engine.v','rtl/accelerator/alpha_blit_engine.v',
       'rtl/accelerator/alpha_pixel_pipeline.v','rtl/accelerator/fill_rect_writer.v',
       'rtl/accelerator/blit_engine.v']
results={}
for minimum,back,batch,count in ((1,0x800000,4,5),(1,0,4,5),(8,0x800000,4,5),(8,0x800000,1024,1025)):
    name=f'min{minimum}-back{back:x}-batch{batch}'
    binary=OUT/(name+'.vvp')
    subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2005-sv','-s','tb_lunaria_tile_contract',
        '-Ptb_lunaria_tile_contract.OVERLAP=1','-Ptb_lunaria_tile_contract.READ_AHEAD=1',
        f'-Ptb_lunaria_tile_contract.MIN_TILE={minimum}',f'-Ptb_lunaria_tile_contract.BACK={back}',
        f'-Ptb_lunaria_tile_contract.BATCH_SIZE={batch}',f'-Ptb_lunaria_tile_contract.FIRST_COUNT={count}',
        '-o',str(binary),*files],cwd=ROOT,check=True)
    r=subprocess.run(['D:/iverilog/bin/vvp.exe',str(binary)],cwd=ROOT,capture_output=True,text=True)
    (OUT/(name+'.log')).write_text(r.stdout+r.stderr)
    assert r.returncode==0 and 'PASS TILE CONTRACT' in r.stdout,r.stdout+r.stderr
    results[name]=r.stdout;print(r.stdout,flush=True)
files.append('scripts/run_lunaria_tile_contract_checks.py')
(OUT/'checks.json').write_text(json.dumps(dict(status='passed',board_tested=False,
    results=results,sources={n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in files}),indent=2))
