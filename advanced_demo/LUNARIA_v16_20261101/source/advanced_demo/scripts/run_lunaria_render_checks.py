"""Exact picture comparison and controlled RTL cycles; not a board FPS claim."""
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
def main():
    a,b=Engine(),Engine(name='lunaria_full_rects.dll')
    pictures=0; before_pixels=after_pixels=before_rows=after_rows=0
    def compare():
        nonlocal pictures,before_pixels,after_pixels,before_rows,after_rows
        for e in (a,b):e.dll.pc_draw()
        assert a.pixels()==b.pixels(),'transparent trim changed a rendered RGB pixel'
        for e,which in ((a,0),(b,1)):
            commands=list(struct.iter_unpack('<8I',e.commands()))
            pixels=sum(c[5]*c[6] for c in commands if c[0]==3)
            rows=sum(c[6] for c in commands if c[0]==3)
            if which:before_pixels+=pixels;before_rows+=rows
            else:after_pixels+=pixels;after_rows+=rows
        pictures+=1
    compare() # title
    for phase in range(8):
        for spin in (0,1):
            for e in (a,b):
                assert e.dll.pc_configure(512,spin,255,1);e.dll.pc_phase(phase)
            for tick in range(1250):
                for e in (a,b):e.dll.pc_tick(8 if tick%80<40 else 4)
                if tick in (0,1,2,3,4,75,200,371,512,700,999,1249):compare()
    for alpha in (0,1,51,127,254,255):
        for e in (a,b):
            assert e.dll.pc_configure(4096,1,alpha,1);e.dll.pc_phase(3)
            for _ in range(360):e.dll.pc_tick(0)
        compare()
    for e in (a,b):
        e.dll.pc_tick(32)
    compare() # pause label
    # Verify EVERY alpha byte outside each generated bound is zero, including
    # source cells which are rare in the sampled phases.
    import re
    header=(ROOT/'software/lunaria/lunaria_trim.h').read_text()
    art=Image.open(OUT/'atlas.png').getchannel('A')
    tiles=[(448+i%6*32,i//6*32,32,32) for i in range(66)]
    tiles += [(i%4*112,i//4*112,112,112) for i in range(16)]
    tiles += [(448+i%16*12,352+i//16*24,12,24) for i in range(64)]
    tiles += [(0,448,256,32),(256,448,192,32)]
    boxes=[tuple(map(int,row.split(','))) for row in re.findall(r'\{([0-9,]+)\}',header)]
    assert len(boxes)==len(tiles)==148
    for (sx,sy,w,h),(x,y,cw,ch) in zip(tiles,boxes):
        tile=art.crop((sx,sy,sx+w,sy+h))
        if cw and ch:tile.paste(0,(x,y,x+cw,y+ch))
        assert not tile.getbbox() and x%4==cw%4==0
    rtl={}
    with tempfile.TemporaryDirectory(prefix='lunaria-render-') as tmp:
        for wide,fast in ((0,0),(0,1),(1,0),(1,1)):
            binary=Path(tmp)/f'{wide}{fast}.vvp'
            subprocess.run(['iverilog','-g2005-sv','-s','tb_lunaria_alpha_cache',
                            f'-Ptb_lunaria_alpha_cache.WIDE={wide}',f'-Ptb_lunaria_alpha_cache.FAST={fast}',
                            '-o',str(binary),'sim/tb_lunaria_alpha_cache.v',
                            'rtl/accelerator/alpha_pixel_pipeline.v','rtl/accelerator/alpha_blit_engine.v'],cwd=ROOT,check=True)
            result=subprocess.run(['vvp',str(binary)],capture_output=True,text=True,check=True)
            assert 'PASS LUNARIA' in result.stdout
            rtl[f'wide{wide}_fast{fast}']=result.stdout
            print(result.stdout.splitlines()[0],flush=True)
    sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
    names=['software/lunaria/lunaria_render.c','software/lunaria/lunaria_trim.h',
           'scripts/prepare_lunaria_trim.py','scripts/run_lunaria_render_checks.py',
           'sim/tb_lunaria_alpha_cache.v','rtl/accelerator/alpha_blit_engine.v',
           'rtl/accelerator/alpha_pixel_pipeline.v','rtl/accelerator/graphics_engine.v',
           'rtl/framebuffer/rgb_framebuffer.v','rtl/ti60f225_oob_top.v']
    report={'status':'passed','board_tested':False,'picture_comparisons':pictures,
        'unchanged_regions_verified':len(tiles),'rgb_exact_match':True,
        'before':{'alpha_pixels':before_pixels,'alpha_rows':before_rows},
        'after':{'alpha_pixels':after_pixels,'alpha_rows':after_rows},
        'rtl_controlled_stall_results':rtl,'rtl_scope':'unit engine only; no real DDR/display arbitration or CPU scheduling',
        'sources':{name:sha(ROOT/name) for name in names},
        'dlls':{name:sha(OUT/name) for name in ('lunaria_pc.dll','lunaria_full_rects.dll')},
        'atlas_sha256':sha(OUT/'atlas.argb')}
    (OUT/'verification/render-checks.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf8')
    print(f'PASS {pictures} full RGB comparisons; alpha pixels {before_pixels} -> {after_pixels}, rows {before_rows} -> {after_rows}')
if __name__=='__main__':main()
