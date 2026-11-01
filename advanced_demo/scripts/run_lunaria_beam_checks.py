"""Compare old/new gameplay and non-laser commands; check procedural beam RTL."""
from pathlib import Path
import os
import hashlib
import json
import struct
import subprocess
import sys
import tempfile
from PIL import Image

ROOT=Path(__file__).resolve().parents[1]
OUT=Path(os.environ.get('LUNARIA_OUTPUT_DIR', str(ROOT/'output/lunaria')))
sys.path.insert(0,str(ROOT/'tools'))
from lunaria_pc import Engine


def old_laser(c):
    return c[0]==3 and c[1]<0x01384000+64*2560 and c[5]<=16 and c[6]<=16 and c[7] in (70,245)


def pixel(distance,color):
    q=abs(distance)//4096
    a=0; rgb=color&0xffffff
    if color>>24<128:
        if q<8:a=255-q*32
    elif q<32:
        a=255 if q<8 else 255-(q-8)*8 if q<16 else 191-(q-16)*16 if q<24 else 63-(q-24)*8
        if q<6:rgb=0xfff4ff
    return a<<24|rgb


def reference(commands):
    bg=list(struct.unpack('<307200I',(OUT/'background.argb').read_bytes()))
    atlas=list(struct.unpack('<307200I',(OUT/'atlas.argb').read_bytes()))
    frame=bg[:]; active=transferred=0
    for op,src,stride,x,y,w,h,color in commands:
        x-=640;y-=300
        nx,ny=struct.unpack('<hh',struct.pack('<I',src))
        distance=struct.unpack('<i',struct.pack('<I',stride))[0]
        for yy in range(h):
            row_alpha=[]
            for xx in range(w):
                dst=(y+yy)*640+x+xx
                if op==0:frame[dst]=color;continue
                if op==1:frame[dst]=bg[dst];continue
                fg=(pixel(distance+xx*nx+yy*ny,color) if op==4 else
                    atlas[(src-0x01384000)//4+yy*640+xx])
                alpha=((fg>>24)*(color>>24 if op==4 else color)+127)//255
                if op==4:row_alpha.append(alpha)
                frame[dst]=sum((((fg>>k&255)*alpha+(frame[dst]>>k&255)*(255-alpha)+127)//255)<<k for k in (0,8,16))
            if op==4:
                active+=sum(a>0 for a in row_alpha)
                transferred+=sum(4 for j in range(0,w,4) if any(row_alpha[j:j+4]))
    data=bytes(c for value in frame for c in (value>>16&255,value>>8&255,value&255))
    return data,active,transferred


def main():
    a,b=Engine(),Engine(name='lunaria_legacy_lasers.dll')
    frames=0; samples=[]; seen=set(); largest=0
    for phase in (6,7):
        for e in (a,b):
            assert e.dll.pc_configure(512,0,255,1);e.dll.pc_phase(phase)
        for tick in range(2000):
            for e in (a,b):e.dll.pc_tick(0);e.dll.pc_draw()
            assert a.status()==b.status() and a.dll.pc_bullet_hash()==b.dll.pc_bullet_hash()
            ca=list(struct.iter_unpack('<8I',a.commands()));cb=list(struct.iter_unpack('<8I',b.commands()))
            beams=[c for c in ca if c[0]==4];old=[c for c in cb if old_laser(c)]
            assert len(beams)<=3
            assert [c for c in ca if c[0]!=4]==[c for c in cb if not old_laser(c)],'non-laser picture changed'
            frames+=1;largest=max(largest,len(old))
            kind='active' if beams and beams[0][7]>>24==245 else 'warning'
            key=(phase,kind)
            if beams and key not in seen:
                seen.add(key)
                expected,active,transferred=reference(ca)
                assert expected==a.pixels(),'desktop beam profile differs from integer reference'
                Image.frombytes('RGB',(640,480),expected).save(OUT/'verification'/f'beam-phase{phase}-{kind}.png')
                samples.append(dict(phase=phase,kind=kind,simulation_ms=a.status()[0],
                    bullets=a.status()[5],old_commands=len(old),new_commands=len(beams),
                    old_alpha_pixel_operations=sum(c[5]*c[6] for c in old),
                    new_nonzero_pixels=active,new_background_pixels_in_4pixel_groups=transferred))
    results={}
    with tempfile.TemporaryDirectory(prefix='lunaria-beam-') as folder:
        for enabled in (0,1):
            binary=Path(folder)/f'beam{enabled}.vvp'
            files=['sim/tb_lunaria_beam.v','rtl/accelerator/graphics_engine.v',
                'rtl/accelerator/alpha_blit_engine.v','rtl/accelerator/alpha_pixel_pipeline.v',
                'rtl/accelerator/fill_rect_writer.v','rtl/accelerator/blit_engine.v']
            subprocess.run(['iverilog','-g2005-sv','-s','tb_lunaria_beam',
                f'-Ptb_lunaria_beam.BEAM={enabled}','-o',str(binary),*files],cwd=ROOT,check=True)
            result=subprocess.run(['vvp',str(binary)],cwd=ROOT,capture_output=True,text=True,check=True)
            assert 'PASS BEAM' in result.stdout
            results[str(enabled)]=result.stdout;print(result.stdout.splitlines()[0],flush=True)
    names=['scripts/run_lunaria_beam_checks.py','sim/tb_lunaria_beam.v',
        'software/lunaria/lunaria.c','software/lunaria/lunaria_beam.h',
        'software/lunaria/lunaria_render.c','software/lunaria/lunaria_pc.c',
        'rtl/accelerator/graphics_engine.v','rtl/accelerator/alpha_blit_engine.v']
    sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
    report=dict(status='passed',board_tested=False,compared_gameplay_frames=frames,
        non_laser_commands_unchanged=True,maximum_old_laser_commands=largest,
        samples=samples,rtl=results,
        scope='MMIO command/RTL unit checks; no real DDR arbitration or HDMI/FPS measurement',
        sources={n:sha(ROOT/n) for n in names},
        dlls={n:sha(OUT/n) for n in ('lunaria_pc.dll','lunaria_legacy_lasers.dll')})
    (OUT/'verification/beam-checks.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf8')
    print(json.dumps(samples,indent=2))
    print(f'PASS {frames} frames: unchanged gameplay/bullets/non-laser commands; max 3 beam commands')


if __name__=='__main__':main()
