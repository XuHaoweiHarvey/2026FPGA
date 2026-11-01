"""CPU bridge plus shared read arbiter, staged 4 KiB DDR upload/readback."""
from pathlib import Path
import subprocess,json,hashlib
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'output/lunaria_v151_upload';OUT.mkdir(exist_ok=True)
files=['sim/tb_lunaria_upload_ddr.v','rtl/framebuffer/cpu_ddr_bridge.v','rtl/framebuffer/ddr_read_arbiter.v']
results={}
for depth in (1,4):
    binary=OUT/f'depth{depth}.vvp'
    subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2005-sv','-s','tb_lunaria_upload_ddr',f'-Ptb_lunaria_upload_ddr.DEPTH={depth}','-o',str(binary),*files],cwd=ROOT,check=True)
    r=subprocess.run(['D:/iverilog/bin/vvp.exe',str(binary)],cwd=ROOT,capture_output=True,text=True)
    (OUT/f'depth{depth}.log').write_text(r.stdout+r.stderr)
    assert r.returncode==0 and 'PASS UPLOAD DDR' in r.stdout,r.stdout+r.stderr
    results[str(depth)]=r.stdout;print(r.stdout,flush=True)
files.append('scripts/run_lunaria_upload_ddr_checks.py')
(OUT/'checks.json').write_text(json.dumps(dict(status='passed',board_tested=False,scope='CPU bridge and arbiter with behavioral DDR; encrypted vendor controller not simulated',results=results,sources={n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in files}),indent=2))
