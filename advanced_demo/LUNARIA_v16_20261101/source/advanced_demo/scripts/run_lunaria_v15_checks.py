"""Candidate v15 RTL checks; does not alter the v14 delivery."""
from pathlib import Path
import hashlib,json,subprocess
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'output/lunaria_v15_checks';OUT.mkdir(exist_ok=True)
ALPHA=['rtl/accelerator/alpha_blit_engine.v','rtl/accelerator/alpha_pixel_pipeline.v']
results={};files=set()
def sim(top,src,**params):
    name=top+'-'+ '-'.join(f'{k}{v}' for k,v in params.items())
    binary=OUT/(name+'.vvp');sources=[f'sim/{top}.v',*src];files.update(sources)
    subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2005-sv','-s',top,*[f'-P{top}.{k}={v}' for k,v in params.items()],'-o',str(binary),*sources],cwd=ROOT,check=True)
    r=subprocess.run(['D:/iverilog/bin/vvp.exe',str(binary)],cwd=ROOT,capture_output=True,text=True)
    (OUT/(name+'.log')).write_text(r.stdout+r.stderr)
    assert r.returncode==0 and 'PASS' in r.stdout,r.stdout+r.stderr
    results[name]=r.stdout;print(r.stdout.splitlines()[0],flush=True)
for depth in (2,3,4,8):sim('tb_ddr_read_queue',['rtl/framebuffer/ddr_read_arbiter.v'],DEPTH=depth)
sim('tb_ddr_read_arbiter',['rtl/framebuffer/ddr_read_arbiter.v'])
for ahead in (0,1):
    for sparse in (0,1):sim('tb_lunaria_read_ahead',ALPHA,AHEAD=ahead,SPARSE=sparse)
for sparse in (0,1):sim('tb_lunaria_read_ahead',ALPHA,AHEAD=1,SPARSE=sparse,READ_DEPTH=1)
for enabled,ahead in ((0,0),(1,0),(1,1)):sim('tb_lunaria_perf_regs',['rtl/control/accel_regs.v'],ENABLED=enabled,READ_AHEAD=ahead)
files.add('scripts/run_lunaria_v15_checks.py')
(OUT/'checks.json').write_text(json.dumps(dict(status='passed',board_tested=False,results=results,sources={n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in sorted(files)}),indent=2))
