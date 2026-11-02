from pathlib import Path
import subprocess,json,hashlib
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'output/lunaria_v16_faults';OUT.mkdir(exist_ok=True)
files=['sim/tb_lunaria_tile_fault.v','rtl/accelerator/tiled_graphics_engine.v','rtl/accelerator/graphics_engine.v','rtl/accelerator/alpha_blit_engine.v','rtl/accelerator/alpha_pixel_pipeline.v','rtl/accelerator/fill_rect_writer.v','rtl/accelerator/blit_engine.v']
results={}
for case in range(9):
 binary=OUT/f'case{case}.vvp'
 subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2005-sv','-s','tb_lunaria_tile_fault','-Ptb_lunaria_tile_fault.OVERLAP=1','-Ptb_lunaria_tile_fault.READ_AHEAD=1',f'-Ptb_lunaria_tile_fault.FAULT_CASE={case}','-o',str(binary),*files],cwd=ROOT,check=True)
 r=subprocess.run(['D:/iverilog/bin/vvp.exe',str(binary)],cwd=ROOT,capture_output=True,text=True)
 (OUT/f'case{case}.log').write_text(r.stdout+r.stderr)
 assert r.returncode==0 and 'PASS TILE FAULT' in r.stdout,r.stdout+r.stderr
 results[str(case)]=r.stdout;print(r.stdout,flush=True)
files.append('scripts/run_lunaria_tile_fault_checks.py')
(OUT/'checks.json').write_text(json.dumps(dict(status='passed',board_tested=False,results=results,sources={n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in files}),indent=2))
