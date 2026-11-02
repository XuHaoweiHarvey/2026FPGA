"""Replay real dense frame commands/artwork through old/new RTL, exact RGB."""
from pathlib import Path
import hashlib
import json
import re
import struct
import subprocess
import sys
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from lunaria_pc import Engine
OUT=ROOT/'output/lunaria'
TEMP=ROOT/'output/lunaria_v15_trace'
TEMP.mkdir(exist_ok=True)


def hexwords(path, data):
    path.write_text(''.join(f'{v:08x}\n' for (v,) in struct.iter_unpack('<I',data)))


def main():
    for name in ('atlas','background'):hexwords(TEMP/(name+'.hex'),(OUT/(name+'.argb')).read_bytes())
    engine=Engine();engine.dll.pc_configure(1024,0,255,1);engine.dll.pc_phase(3)
    samples=[];targets=iter((400,512,768));target=next(targets)
    for tick in range(2000):
        engine.dll.pc_tick(0)
        if engine.status()[5]<target or engine.status()[6] < target*0.70:continue
        engine.dll.pc_draw()
        commands=list(struct.iter_unpack('<8I',engine.commands()))
        # Freshly emitted age-zero bullets are counted by the game but draw
        # no pixels. Select a frame with an actual dense command workload.
        if len(commands)-1 < target:continue
        assert commands[0][0]==1 and all(c[0] in (0,3,4) for c in commands[1:])
        prefix=str(target)
        (TEMP/(prefix+'.cmd')).write_text(''.join(' '.join(f'{v:08x}' for v in c)+'\n' for c in commands[1:]))
        rgb=engine.pixels()
        (TEMP/(prefix+'.hex')).write_text(''.join(f'{int.from_bytes(rgb[i:i+3],"big"):08x}\n' for i in range(0,len(rgb),3)))
        samples.append(dict(target=target,active_bullets=engine.status()[5],visible_bullets=engine.status()[6],tick=tick,results={}))
        target=next(targets,None)
        if target is None:break
    assert len(samples)==3
    sources=['rtl/accelerator/alpha_blit_engine.v','rtl/accelerator/alpha_pixel_pipeline.v',
             'rtl/accelerator/graphics_engine.v','rtl/accelerator/fill_rect_writer.v','rtl/accelerator/blit_engine.v']
    for ahead in (0,1):
        overlap=1
        binary=TEMP/f'trace{ahead}.vvp'
        subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2005-sv','-s','tb_lunaria_trace',
                        f'-Ptb_lunaria_trace.OVERLAP={overlap}',f'-Ptb_lunaria_trace.READ_AHEAD={ahead}', '-Ptb_lunaria_trace.READ_DEPTH=1','-o',str(binary),'sim/tb_lunaria_trace.v',*sources],cwd=ROOT,check=True)
        for sample in samples:
            args=dict(ATLAS=TEMP/'atlas.hex',BG=TEMP/'background.hex',EXPECTED=TEMP/f'{sample["target"]}.hex',COMMANDS=TEMP/f'{sample["target"]}.cmd')
            result=subprocess.run(['D:/iverilog/bin/vvp.exe',str(binary),*[f'+{k}={v}' for k,v in args.items()]],cwd=ROOT,capture_output=True,text=True)
            assert result.returncode==0 and 'PASS TRACE' in result.stdout,result.stdout+result.stderr
            print(str(sample['target'])+': '+result.stdout.splitlines()[0],flush=True)
            sample['results'][f'v{14+ahead}']={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',result.stdout)}
    for s in samples:
        a,b=s['results']['v14'],s['results']['v15']
        assert b['cycles']<a['cycles'] and b['read_beats']<a['read_beats'] and b['write_beats']<a['write_beats']
    sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
    report=dict(status='passed',board_tested=False,samples=samples,
                scope='Actual C/atlas/commands, exact RGB; controlled independent AXI channels, no CPU/display competition, background restore excluded. Cycles are NOT board FPS.',
                dll_sha256=sha(OUT/'lunaria_pc.dll'),atlas_sha256=sha(OUT/'atlas.argb'),
                sources={n:sha(ROOT/n) for n in sources+['sim/tb_lunaria_trace.v','scripts/run_lunaria_v15_trace_checks.py']})
    (TEMP/'trace-v15-checks.json').write_text(json.dumps(report,indent=2)+'\n')


if __name__=='__main__':main()
