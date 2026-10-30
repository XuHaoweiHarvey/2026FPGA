"""Pack original LUNARIA textures into the existing guarded DDR windows."""
from pathlib import Path
import hashlib
import json
import math
import struct
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'design/lunaria_preview/assets'
OUT = ROOT / 'output/lunaria'
CODE = ROOT / 'software/lunaria'

def fnv_words(data):
    value = 2166136261
    for (word,) in struct.iter_unpack('<I', data):
        value = ((value ^ word) * 16777619) & 0xffffffff
    return value

def font(size, chinese=False):
    candidates = ['msyh.ttc', 'simhei.ttf'] if chinese else ['georgia.ttf', 'segoeui.ttf', 'arial.ttf']
    for name in candidates:
        path = Path('C:/Windows/Fonts') / name
        if path.is_file():
            return ImageFont.truetype(str(path), size)
    raise RuntimeError('No suitable system font')

def label(image, text, box, size, color, chinese=False):
    draw = ImageDraw.Draw(image)
    f = font(size, chinese)
    bounds = draw.textbbox((0, 0), text, font=f)
    x, y, w, h = box
    draw.text((x+(w-bounds[2]+bounds[0])/2-bounds[0],
               y+(h-bounds[3]+bounds[1])/2-bounds[1]), text, font=f, fill=color)

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    CODE.mkdir(parents=True, exist_ok=True)
    atlas = Image.new('RGBA', (640, 480))
    for name, xy in [('boss-atlas-112px-16frames.png',(0,0)),
                     ('player-atlas-32px-8frames.png',(448,96)),
                     ('hit-atlas-32px-8frames.png',(448,160))]:
        atlas.paste(Image.open(SOURCE/name).convert('RGBA'), xy)
    original = Image.open(SOURCE/'bullet-atlas-32px.png').convert('RGBA')
    for row in range(3):
        for col in range(4):
            tile = original.crop((col*32,row*32,col*32+32,row*32+32))
            atlas.paste(tile.resize((16,16), Image.Resampling.LANCZOS), (448+col*16,row*16))
    # Directional rice sprites and true five-point stars occupy previously
    # unused atlas cells, without changing the protected hardware windows.
    stars = Image.open(SOURCE/'star-bullet-atlas-32px.png').convert('RGBA')
    for row in range(3):
        rice = original.crop((32,row*32,64,row*32+32))
        for angle in range(8):
            tile = rice.rotate(-angle*45,resample=Image.Resampling.BICUBIC)
            atlas.paste(tile.resize((16,16),Image.Resampling.LANCZOS),(512+angle*16,row*16))
        tile = stars.crop((row*32,0,row*32+32,32))
        atlas.paste(tile.resize((16,16),Image.Resampling.LANCZOS),(512+row*16,48))
    f = ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf', 17)
    draw = ImageDraw.Draw(atlas)
    for index in range(64):
        char = chr(32+index)
        x, y = 448+index%12*16, 224+index//12*24
        bounds = draw.textbbox((0,0),char,font=f)
        draw.text((x+(16-bounds[2]+bounds[0])/2-bounds[0],y+1),char,font=f,fill='#f4eafa')
    label(atlas,'L U N A R I A',(0,448,256,32),25,'#f5eaff')
    label(atlas,'星 海 梦 境',(256,448,192,32),20,'#d7bfe9',True)
    label(atlas,'VICTORY',(448,368,192,40),31,'#ffe6ae')
    label(atlas,'WARNING',(448,408,192,32),23,'#ffc1ee')
    atlas.save(OUT/'atlas.png')
    background = Image.open(SOURCE/'starfield-640x480.png').convert('RGBA')
    background.save(OUT/'background.png')
    files = {}
    hashes = []
    for name, image in [('background',background),('atlas',atlas)]:
        data = image.tobytes('raw','BGRA')
        (OUT/(name+'.argb')).write_bytes(data)
        h = fnv_words(data); hashes.append(h)
        files[name] = {'file':name+'.argb','bytes':len(data),'width':640,'height':480,
                       'fnv_words':h,'sha256':hashlib.sha256(data).hexdigest()}
    sines = [round(math.sin(i*math.tau/256)*16384) for i in range(256)]
    angles = [round(math.atan(i/128)/math.tau*65536) for i in range(129)]
    rows = lambda a: ',\n'.join('    '+','.join(str(n) for n in a[i:i+16]) for i in range(0,len(a),16))
    header = '#ifndef LUNARIA_TABLES_H\n#define LUNARIA_TABLES_H\n#include <stdint.h>\n'
    header += 'static const int16_t ln_sine[256] = {\n'+rows(sines)+'\n};\n'
    header += 'static const uint16_t ln_atan[129] = {\n'+rows(angles)+'\n};\n'
    header += '#endif\n'
    (CODE/'lunaria_tables.h').write_text(header,encoding='utf8')
    (CODE/'lunaria_asset_ids.h').write_text(
        '#ifndef LUNARIA_ASSET_IDS_H\n#define LUNARIA_ASSET_IDS_H\n'
        f'#define LN_BACKGROUND_HASH UINT32_C(0x{hashes[0]:08x})\n'
        f'#define LN_ATLAS_HASH UINT32_C(0x{hashes[1]:08x})\n#endif\n',encoding='utf8')
    manifest = {'version':1,'format':'little-endian ARGB8888','assets':files,
                'sprite_window':{'base':0x01384000,'stride':2560,'bytes':1228800},
                'render':{'x':640,'y':300,'width':640,'height':480},
                'bullet_size':16,'board_tested':False,'art_source':'Original procedural LUNARIA preview'}
    (OUT/'assets.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf8')
    print('PASS packed LUNARIA assets into existing 640 x 480 atlas; '+str(sum(v['bytes'] for v in files.values()))+' transfer bytes')

if __name__ == '__main__':
    main()
