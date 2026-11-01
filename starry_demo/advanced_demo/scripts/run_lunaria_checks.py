"""Compile and exercise the actual native logic/renderer without a board."""
from pathlib import Path
import json
import hashlib
import os
import shutil
import struct
import subprocess
import tempfile
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'output/lunaria'


def rasterize(path, contact_sheets=True, atlas_override=None):
    atlas = Image.open(OUT/'atlas.png').convert('RGBA')
    if atlas_override is not None: atlas = atlas_override
    background = Image.open(OUT/'background.png').convert('RGBA')
    data = path.read_bytes()
    offset, files = 0, []
    while offset < len(data):
        name = data[offset:offset+32].split(b'\0')[0].decode()
        count, = struct.unpack_from('<I', data, offset+32)
        offset += 36
        # Restore the same frame into two differently dirty buffers.
        results = []
        for dirty in ('#ef0000', '#00ddee'):
            image = Image.new('RGBA', (640,480), dirty)
            for n in range(count):
                op, src, stride, x, y, w, h, color = struct.unpack_from('<8I', data, offset+n*32)
                x -= 640; y -= 300
                if op == 0:
                    ImageDraw.Draw(image).rectangle((x,y,x+w-1,y+h-1),
                                                   fill=(color>>16&255,color>>8&255,color&255,255))
                elif op == 1:
                    image.paste(background, (x,y))
                else:
                    p = (src-0x01384000)//4
                    sx, sy = p%640, p//640
                    tile = atlas.crop((sx,sy,sx+w,sy+h))
                    # Match hardware's rounded pixel/global alpha.
                    if color != 255:
                        tile.putalpha(tile.getchannel('A').point(lambda a: (a*color+127)//255))
                    image.alpha_composite(tile,(x,y))
            results.append(image)
        assert results[0].tobytes() == results[1].tobytes(), name+' stale buffer'
        preview = OUT/'verification'/(name+'.png')
        preview.parent.mkdir(parents=True,exist_ok=True)
        results[0].save(preview)
        files.append(preview.name)
        offset += count*32
    if contact_sheets:
        selected = ['phase3-1200ms','phase3-2192ms','phase4-1200ms','phase4-2192ms',
                    'phase5-1200ms','phase5-2192ms']
        contact = Image.new('RGB',(1280,1500),'#0c091a')
        for n, name in enumerate(selected):
            contact.paste(Image.open(OUT/'verification'/(name+'.png')).convert('RGB'),((n%2)*640,(n//2)*500+20))
            ImageDraw.Draw(contact).text(((n%2)*640+12,(n//2)*500+4),name,fill='white')
        contact.save(OUT/'verification/rotation-contact.png')
        petals = Image.new('RGB', (1920,500), '#0c091a')
        for n, count in enumerate((4,5,6)):
            name = f'rose{count}-first-burst'
            petals.paste(Image.open(OUT/'verification'/(name+'.png')).convert('RGB'),(n*640,20))
            ImageDraw.Draw(petals).text((n*640+12,4),f'{count} petals / fixed launch direction',fill='white')
        petals.save(OUT/'verification/petals-contact.png')
    return files


def main():
    # Rice directions and replacement circles must contain real visible artwork.
    atlas = Image.open(OUT/'atlas.png').convert('RGBA')
    for color in range(4):
        for angle in range(8):
            assert atlas.crop((512+angle*16,color*16,528+angle*16,color*16+16)).getchannel('A').getbbox(), 'Missing directional rice sprite'
        assert atlas.crop((448+color*16,64,464+color*16,80)).getchannel('A').getbbox(), 'Missing replacement circle'
    # The live beam's opaque diameter is >3x the old 8 px body.
    beam=atlas.crop((576,96,608,128)).getchannel('A')
    assert sum(beam.getpixel((x,16))==255 for x in range(32)) >= 24
    for color in range(4):
        assert atlas.crop((448+color*16,64,464+color*16,80)).tobytes()==atlas.crop((448,color*16,464,color*16+16)).tobytes()
    compiler = next((c for c in ('cl','gcc','clang','cc') if shutil.which(c)),None)
    if not compiler: raise SystemExit('Run scripts/run_lunaria_checks.cmd with MSVC installed')
    with tempfile.TemporaryDirectory(prefix='lunaria-check-') as folder:
        temp = Path(folder)
        exe = temp/('lunaria.exe' if os.name=='nt' else 'lunaria')
        units = [ROOT/'sim/test_lunaria.c',ROOT/'software/lunaria/lunaria.c',ROOT/'software/lunaria/lunaria_render.c']
        flags = ['/nologo','/TC','/W4','/WX','/O2','/D_CRT_SECURE_NO_WARNINGS'] if compiler=='cl' else ['-std=c99','-Wall','-Wextra','-Werror','-O2']
        output = ['/Fe:'+str(exe)] if compiler=='cl' else ['-o',str(exe)]
        subprocess.run([compiler,*flags,*map(str,units),*output],cwd=temp,check=True)
        trace = temp/'commands.bin'
        result = subprocess.run([str(exe),str(trace)],cwd=ROOT,text=True,capture_output=True)
        print(result.stdout,end=''); print(result.stderr,end='')
        result.check_returncode()
        files = rasterize(trace)
    (OUT/'verification/host-checks.json').write_text(json.dumps({
        'logic_render':'passed','board_tested':False,
        'source':'native lunaria.c and lunaria_render.c; accelerator command rasterization',
        'output':result.stdout,'frames':files,
        'source_sha256':{p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest()
            for p in [ROOT/'sim/test_lunaria.c',ROOT/'software/lunaria/lunaria.c',ROOT/'software/lunaria/lunaria.h',ROOT/'software/lunaria/lunaria_render.c',ROOT/'software/lunaria/lunaria_render.h']},
        'atlas_sha256':hashlib.sha256((OUT/'atlas.argb').read_bytes()).hexdigest()},indent=2),encoding='utf8')
    print('PASS native renderer, alignment/window bounds, alpha and dirty double buffers')


if __name__ == '__main__': main()
