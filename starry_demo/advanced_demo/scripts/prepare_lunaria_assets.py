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
    # Pixel-native, bounded artwork: solid cores and a one-pixel low-alpha rim.
    palette = [(55,160,191),(143,86,190),(205,142,54),(205,105,153)]
    rim_palette = [(108,170,186),(157,131,183),(191,164,112),(190,148,172)]
    def bullet(color, shape=0):
        rim = rim_palette[palette.index(color)]
        tile = Image.new('RGBA',(16,16)); d = ImageDraw.Draw(tile)
        highlight=tuple(c+(245-c)*3//5 for c in color)
        if shape == 1:
            d.ellipse((4,1,11,14),fill=(*rim,12)); d.ellipse((5,2,10,13),fill=(*color,255))
            d.ellipse((6,3,9,10),fill=(*highlight,255))
        elif shape == 3:
            d.polygon([(8,1),(14,8),(8,14),(1,8)],fill=(*rim,12))
            d.polygon([(8,2),(13,8),(8,13),(2,8)],fill=(*color,255))
            d.polygon([(8,3),(11,7),(8,11),(5,7)],fill=(*highlight,255))
        else:
            d.ellipse((2,2,13,13),fill=(*rim,12)); d.ellipse((3,3,12,12),fill=(*color,255))
            d.ellipse((5,4,10,9),fill=(*highlight,255))
        return tile
    for row,color in enumerate(palette):
        for col in range(4): atlas.paste(bullet(color,col),(448+16*col,16*row))
        for angle in range(8):
            atlas.paste(bullet(color,1).rotate(-angle*45,resample=Image.Resampling.BICUBIC),(512+angle*16,row*16))
        # Retired star slots also contain circles; old shape IDs cannot show stars.
        atlas.paste(bullet(color),(448+row*16,64))
    # Wide beam: 28 px solid body (previously 8), 32 px tile, 12 px sampling.
    # Four times the tile area and four times the sample stride keep work bounded.
    for sx,warning in ((576,False),(608,True)):
        tile=Image.new('RGBA',(32,32));d=ImageDraw.Draw(tile)
        if warning:
            d.ellipse((2,2,29,29),fill=(168,150,121,20))
            d.ellipse((14,14,17,17),fill=(211,155,63,210))
        else:
            # Uniform opaque body avoids overlapping highlight scallops.
            # Preserve the existing faint rim and all beam dimensions.
            d.ellipse((1,1,30,30),fill=(190,161,184,18))
            d.ellipse((2,2,29,29),fill=(190,78,150,255))
        atlas.paste(tile,(sx,96))
    # Dedicated warning bead, player needle, live beam and life icon.
    for sx in (512,528,544,560):
        tile=Image.new('RGBA',(16,16));d=ImageDraw.Draw(tile)
        if sx==512: d.ellipse((6,6,9,9),fill=(255,199,91,230))
        elif sx==528:
            d.line((8,1,8,14),fill=(222,249,255,255),width=2)
            d.line((7,5,7,13),fill=(99,178,210,100),width=1)
        elif sx==544:
            d.ellipse((1,1,14,14),fill=(255,144,189,32));d.ellipse((4,4,11,11),fill=(255,177,210,230));d.ellipse((6,6,9,9),fill=(255,253,243,255))
        else: d.polygon([(8,2),(13,8),(8,13),(3,8)],fill=(175,229,243,255))
        atlas.paste(tile,(sx,64))
    for frame in range(4):
        tile=Image.new('RGBA',(16,16));d=ImageDraw.Draw(tile);radius=2+frame*2
        d.ellipse((8-radius,8-radius,7+radius,7+radius),outline=(253,220,178,220-frame*40),width=1)
        d.line((8,4,8,11),fill=(255,249,220,255-frame*55));d.line((4,8,11,8),fill=(255,249,220,255-frame*55))
        atlas.paste(tile,(448+frame*16,80))
    # Bake the halo into existing Boss frames: no extra runtime draw or larger sprite.
    for frame in range(16):
        sx,sy=frame%4*112,frame//4*112
        boss=atlas.crop((sx,sy,sx+112,sy+112)); halo=Image.new('RGBA',(112,112));d=ImageDraw.Draw(halo)
        d.ellipse((5,5,106,106),outline=(132,167,217,55),width=1)
        d.arc((10,10,101,101),frame*22,frame*22+100,fill=(196,191,242,110),width=1)
        halo.alpha_composite(boss);atlas.paste(halo,(sx,sy))
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
    # Dark, calm playfield; preserve more of the original nebula near the edge.
    pixels=background.load()
    for y in range(480):
        for x in range(640):
            red,green,blue,_=pixels[x,y]
            edge=min(1.0,abs(x-320)/320)
            gain=0.34+0.25*edge*edge
            pixels[x,y]=(int(red*gain),int(green*gain),int(blue*gain),255)
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
