"""Sensitivity to longer controlled DDR latency; never a board FPS model."""
from pathlib import Path
import hashlib,json,re,subprocess
ROOT=Path(__file__).resolve().parents[1]
DATA=ROOT/'output/lunaria_v16_trace'
OUT=ROOT/'output/lunaria_v16_latency';OUT.mkdir(exist_ok=True)
sources=['rtl/accelerator/tiled_graphics_engine.v','rtl/accelerator/graphics_engine.v',
 'rtl/accelerator/alpha_blit_engine.v','rtl/accelerator/alpha_pixel_pipeline.v',
 'rtl/accelerator/fill_rect_writer.v','rtl/accelerator/blit_engine.v']
results={}
for tiled in (False,True):
    top='tb_lunaria_tile_trace' if tiled else 'tb_lunaria_trace'
    original=ROOT/f'sim/{top}.v';text=original.read_text()
    assert text.count('cycle+12')==text.count('bd_delay<=12')==1
    text=text.replace('cycle+12','cycle+64').replace('bd_delay<=12','bd_delay<=64')
    tb=OUT/(top+'.v');tb.write_text(text)
    binary=OUT/(top+'.vvp')
    subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2005-sv','-s',top,
       f'-P{top}.OVERLAP=1',f'-P{top}.READ_AHEAD=1','-o',str(binary),str(tb),*sources],cwd=ROOT,check=True)
    args={'ATLAS':DATA/'atlas.hex','BG':DATA/'background.hex','EXPECTED':DATA/'512.hex','COMMANDS':DATA/'512.cmd'}
    r=subprocess.run(['D:/iverilog/bin/vvp.exe',str(binary),*[f'+{k}={v}' for k,v in args.items()]],cwd=ROOT,capture_output=True,text=True)
    (OUT/(top+'.log')).write_text(r.stdout+r.stderr)
    assert r.returncode==0 and 'PASS TRACE' in r.stdout,r.stdout+r.stderr
    results['tiled' if tiled else 'v151']={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',r.stdout.splitlines()[0])}
    print(r.stdout.splitlines()[0],flush=True)
sources+=['sim/tb_lunaria_tile_trace.v','sim/tb_lunaria_trace.v','scripts/run_lunaria_tile_latency_checks.py']
(OUT/'checks.json').write_text(json.dumps(dict(status='passed',board_tested=False,read_latency=64,write_response_latency=64,
 scope='Controlled latency sensitivity, no CPU/display contention; not physical DDR calibration.',results=results,
 sources={n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in sources},
 inputs={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in args.values()}),indent=2))
