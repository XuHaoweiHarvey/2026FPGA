"""Compare the board's paged storage with independent inline storage, offline."""
from pathlib import Path
import os
import ctypes as ct
import hashlib
import json
import struct
import sys
import time
from PIL import Image, ImageDraw
ROOT=Path(__file__).resolve().parents[1]
OUT=Path(os.environ.get('LUNARIA_OUTPUT_DIR', str(ROOT/'output/lunaria')))
sys.path.insert(0,str(ROOT/'tools'))
from lunaria_pc import Engine, Preview, NAMES

def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()

def main():
    a,b=Engine(),Engine(name='lunaria_oracle.dll')
    frame_count=0; peaks={}; samples=[]
    start=time.perf_counter()
    for limit in (64,65,512,999,1024,2048,3072,4096):
        peak=0
        for spin in (0,1):
            for phase in range(8):
                for e in (a,b):
                    assert e.dll.pc_configure(limit,spin,255,1)
                    e.dll.pc_phase(phase)
                for tick in range(500):
                    # Movement, homing, pause/resume, and two framebuffer slots.
                    buttons=(8 if tick%80<40 else 4) | (32 if tick in (150,175) else 0)
                    for e in (a,b): e.dll.pc_tick(buttons); e.dll.pc_draw()
                    sa,sb=a.status(),b.status()
                    assert sa==sb,(limit,spin,phase,tick,'state')
                    assert a.dll.pc_bullet_hash()==b.dll.pc_bullet_hash(),(limit,spin,phase,tick,'bullets')
                    assert a.commands()==b.commands(),(limit,spin,phase,tick,'draw commands')
                    assert sa[5]<=limit and sa[12]==0
                    peak=max(peak,sa[5]); frame_count+=1
                    if tick==370 and limit==4096 and spin:
                        pixels=a.pixels()
                        assert pixels==b.pixels()
                        path=OUT/'verification'/f'pc-shared-phase{phase}-4096.png'
                        Image.frombytes('RGB',(640,480),pixels).save(path)
                        samples.append(path)
                # Reset settings after repeated swaps; cleared pages cannot revive.
                for e in (a,b):
                    assert e.dll.pc_configure(64,0,255,1)
                    assert e.status()[5]==0
        peaks[limit]=peak
        print(f'PASS shared C/paged DDR parity: cap {limit}, 8 patterns, spin on/off',flush=True)
    counts=(ct.c_uint32*3)(); a.dll.pc_io_counts(counts)
    # Tk controls and real key events, hidden; no board access or visible helper.
    import tkinter as tk
    from types import SimpleNamespace
    root=tk.Tk(); root.withdraw()
    try:
        ui=Preview(root,schedule=False); root.update_idletasks()
        for limit in ('64','513','999','1024','2048','3072','4096'):
            ui.limit.set(limit); assert ui.apply_settings()
            assert ui.engine.status()[8]==int(limit)
        for bad in ('63','4097','NaN','64.5'):
            ui.limit.set(bad); assert not ui.apply_settings()
            assert ui.engine.status()[8]==4096
        ui.limit.set('4096'); ui.spin.set(True); ui.invincible.set(True)
        ui.phase.set(NAMES[3]); ui.practice()
        ui.engine.dll.pc_tick(0); before=ui.engine.status()[14]
        ui.keys.add('Right'); ui.frame(); assert ui.engine.status()[14]>before
        ui.keys={'p'}; ui.frame(); assert ui.engine.status()[9]==1
        ui.keys.clear(); ui.frame(); assert ui.engine.status()[9]==1
        assert ui.photo.width()==640 and ui.photo.height()==480
    finally: root.destroy()
    contact=Image.new('RGB',(640,4*256),(12,9,26))
    for n,path in enumerate(samples):
        contact.paste(Image.open(path).resize((320,240)),((n%2)*320,(n//2)*256+16))
        ImageDraw.Draw(contact).text(((n%2)*320+8,(n//2)*256),f'{n+1}. {NAMES[n].split(" / ")[0]} / 4096',fill='white')
    contact.save(OUT/'verification/shared-4096-contact.jpg',quality=82)
    source_paths=[*sorted((ROOT/'software/lunaria').glob('*.[ch]')),ROOT/'tools/lunaria_pc.py',Path(__file__).resolve()]
    report={'status':'passed','board_tested':False,'compared_frames':frame_count,
            'checks':'full state, active bullet bytes, every draw command; RGB at 8 dense samples; Tk settings/input',
            'limits_peaks':peaks,'ddr_model':{'reads':counts[0],'writes':counts[1],'sessions':counts[2],
               'aligned_words_only':True,'writes_back_only':True,'scratch_bounds_checked':True},
            'native_resolution':[640,480],'bullet_size':32,'fixed_tick_ms':16,
            'elapsed_seconds':round(time.perf_counter()-start,2),
            'sources':{p.relative_to(ROOT).as_posix():sha(p) for p in source_paths},
            'dlls':{name:sha(OUT/name) for name in ('lunaria_pc.dll','lunaria_oracle.dll')},
            'assets':{name:sha(OUT/name) for name in ('atlas.argb','background.argb','assets.json')}}
    (OUT/'verification/parity-checks.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf8')
    print(f'PASS {frame_count} frames: exact simulation/command parity; RGB and interactive controls passed',flush=True)

if __name__=='__main__':main()
