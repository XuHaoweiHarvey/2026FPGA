"""Count pool IO for identical simulation workloads; never infer hardware FPS."""
from pathlib import Path
import os
import ctypes as ct
import hashlib
import json
import sys
ROOT=Path(__file__).resolve().parents[1]
OUT=Path(os.environ.get('LUNARIA_OUTPUT_DIR', str(ROOT/'output/lunaria')))
sys.path.insert(0,str(ROOT/'tools'))
from lunaria_pc import Engine
def counts(e):
    values=(ct.c_uint32*3)(); e.dll.pc_io_counts(values); return list(values)
def delta(before,after): return [(b-a)&0xffffffff for a,b in zip(before,after)]
def main():
    e=Engine(); rows=[]; low=[]
    for cap in (64,128,256,512,4096):
        assert e.dll.pc_configure(cap,0,255,1); e.dll.pc_phase(3)
        before=counts(e)
        for _ in range(1000): e.dll.pc_tick(0); e.dll.pc_draw()
        reads,writes,sessions=delta(before,counts(e))
        row=dict(cap=cap,frames=1000,reads=reads,writes=writes,sessions=sessions)
        if cap<=512: assert reads==writes==sessions==0,row
        rows.append(row)
    for cap in (64,128,256,512):
        for phase in range(8):
            for spin in (0,1):
                assert e.dll.pc_configure(cap,spin,255,1); e.dll.pc_phase(phase)
                before=counts(e)
                for tick in range(700):
                    e.dll.pc_tick(8 if tick%80<40 else 4); e.dll.pc_draw()
                io=delta(before,counts(e)); assert io==[0,0,0],(cap,phase,spin,io)
                low.append(dict(cap=cap,phase=phase,spin=spin,frames=700,pool_io=io))
    # Raising the ceiling does not force sparse scenes out to DDR.
    assert e.dll.pc_configure(4096,0,255,1); e.dll.pc_phase(2)
    before=counts(e)
    for _ in range(60): e.dll.pc_tick(0); e.dll.pc_draw()
    assert delta(before,counts(e))==[0,0,0]
    assert 0 < e.status()[5] <= 512
    sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
    files=[*sorted((ROOT/'software/lunaria').glob('*.[ch]')),Path(__file__).resolve()]
    report={'status':'passed','board_tested':False,'hardware_fps_measured':False,
            'scope':'CPU bullet-pool DDR transfers only; drawing still uses DDR',
            'before':json.loads((OUT/'verification/paging-cost-before.json').read_text()),
            'after':rows,'low_density_scenes':low,'high_ceiling_sparse_scene':'passed',
            'sources':{p.relative_to(ROOT).as_posix():sha(p) for p in files},
            'dll_sha256':sha(OUT/'lunaria_pc.dll')}
    (OUT/'verification/cost-checks.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf8')
    print('PASS zero bullet-pool DDR IO: 64/128/256/512, all 8 phases, spin on/off, 44800 frames')
    print(json.dumps(rows))
if __name__=='__main__':main()
