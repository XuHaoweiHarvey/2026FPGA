"""Package PixelForge using the existing v13 hardware and 16px sprites and luminous round/laser artwork."""
from pathlib import Path
import hashlib,json,math,shutil,subprocess,sys,tempfile
from PIL import Image,ImageDraw
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from game_debug_bridge import ElfImage,RAM_END
from lunaria_debug_bridge import fnv_words,read_assets
from prepare_lunaria_assets import label
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
normal=ROOT/'delivery/lunaria_v12';stress=ROOT/'delivery/lunaria_stress'
protected={p:sha(p) for folder in (normal,stress) for p in folder.iterdir() if p.is_file()}
out=ROOT/'delivery/PixelForge';out.mkdir(exist_ok=True)
atlas=Image.frombytes('RGBA',(640,480),(normal/'atlas.argb').read_bytes(),'raw','BGRA')
original=atlas.copy()
ImageDraw.Draw(atlas).rectangle((0,448,255,479),fill=(0,0,0,0))
label(atlas,'PixelForge',(0,448,256,32),29,'#f5eaff')
# Pixel-native procedural assets: fixed-size tiles, no new runtime layers.
ImageDraw.Draw(atlas).rectangle((256,448,447,479),fill=(0,0,0,0))
label(atlas,'像素熔炉',(256,448,192,32),22,'#d7bfe9',True)
palette=[(55,160,191),(143,86,190),(205,142,54),(205,105,153)]
def round_bullet(color):
    tile=Image.new('RGBA',(16,16))
    for y in range(16):
        for x in range(16):
            radius=((x-7.5)**2+(y-7.5)**2)**.5
            if radius<=4.15:
                # Smaller white centre; retain hue across the luminous body.
                light=.90 if radius<=2.35 else .64 if radius<=3.6 else .12
                rgb=tuple(round(c+(255-c)*light) for c in color)
                tile.putpixel((x,y),(*rgb,255))
            elif radius<=5:
                tile.putpixel((x,y),(*color,80))
    return tile
for row,color in enumerate(palette):
    tile=round_bullet(color)
    for col in (0,2):atlas.paste(tile,(448+col*16,row*16))
    atlas.paste(tile,(448+row*16,64))
# Relocate the eight unchanged hit frames to free atlas tiles. This frees a
# tall strip for horizontal beam slices without enlarging the sealed atlas.
for frame in range(8):
    tile=original.crop((448+frame%4*32,160+frame//4*32,480+frame%4*32,192+frame//4*32))
    target=(448+frame*32,448) if frame<6 else (576,64+(frame-6)*32)
    atlas.paste(tile,target)
# Beam slices never overlap along their major axis. Seventeen local slopes
# approximate only an 8px segment (<=0.22px transverse error), not the ray angle.
# Pixel positions use the actual angle, so direction error cannot accumulate.
for index in range(17):
    slope=(index-8)/8
    vertical=Image.new('RGBA',(56,8))
    for y in range(8):
        for x in range(56):
            distance=abs(x-27.5-slope*(y-3.5))/math.sqrt(1+slope*slope)
            if distance<=5:
                rgba=(255,242,252,255)
            elif distance<=10:
                t=(distance-5)/5
                rgba=(246,round(218-90*t),round(244-30*t),255)
            elif distance<16:
                t=(distance-10)/6
                rgba=(213,91,177,round(230*(1-t)))
            else:rgba=(0,0,0,0)
            vertical.putpixel((x,y),rgba)
    if index<8:target=(584,160+index*8)
    elif index<12:target=(576,128+(index-8)*8)
    elif index<16:target=(512+(index-12)%2*64,344+(index-12)//2*8)
    else:target=(512,360)
    atlas.paste(vertical,target)
    atlas.paste(vertical.transpose(Image.Transpose.TRANSPOSE),(448+index*8,160))

# Round muzzle with the same radial colour/alpha profile as the beam sides.
cap=Image.new('RGBA',(32,32))
for y in range(32):
    for x in range(32):
        distance=math.hypot(x-15.5,y-15.5)
        if distance<=5:rgba=(255,242,252,255)
        elif distance<=10:
            t=(distance-5)/5
            rgba=(246,round(218-90*t),round(244-30*t),255)
        elif distance<16:
            rgba=(213,91,177,round(230*(16-distance)/6))
        else:rgba=(0,0,0,0)
        cap.putpixel((x,y),rgba)
atlas.paste(cap,(608,64))

data=atlas.tobytes('raw','BGRA');digest=fnv_words(data)
assets=json.loads((normal/'assets.json').read_text(encoding='utf8'))
assets['art_source']='PixelForge / 像素熔炉; luminous round bullets and laser'
assets['assets']['atlas'].update(sha256=hashlib.sha256(data).hexdigest(),fnv_words=digest)
hardware=json.loads((stress/'build-info.json').read_text(encoding='utf8'))['hardware']
assert hardware['version']=='0xd0000' and sha(stress/'ti60f225_oob.bit')==hardware['bit_sha256']
defines=['PIXELFORGE=1','LN_STRESS_ATLAS_HASH='+hex(digest),'GAME_DISPLAY_WINDOW=1','GAME_ALLOW_SCALE2=1','LUNARIA_PIXEL_X=1','LUNARIA_HARDWARE_VERSION=0xd0000']
with tempfile.TemporaryDirectory(prefix='pixelforge-build-') as folder:
    temp=Path(folder)
    command=[sys.executable,'-B',str(ROOT/'scripts/build_apb_software.py'),'--program','lunaria','--opt','Os','--ide-root','D:/Efinity/efinity-riscv-ide-2026.1','--output',str(temp)]
    for define in defines:command+=['--define',define]
    subprocess.run(command,cwd=ROOT,check=True)
    elf=ElfImage(temp/'lunaria.elf')
    assert elf.symbol('_sp')<=RAM_END
    assert elf.symbol_u32('g_pixelforge_available')==1
    assert elf.symbol_u32('g_lunaria_required_hardware')==0xd0000
    assert elf.symbol_u32('g_lunaria_asset_hashes',1)==digest
    capacity=elf.symbol_u32('g_lunaria_settings',10)
    for ext in ('elf','map'):shutil.copy2(temp/('lunaria.'+ext),out/('PixelForge.'+ext))
(out/'atlas.argb').write_bytes(data)
(out/'assets.json').write_text(json.dumps(assets,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
shutil.copy2(normal/'background.argb',out/'background.argb')
if not (out/'ti60f225_oob.bit').exists() or sha(out/'ti60f225_oob.bit')!=hardware['bit_sha256']:shutil.copy2(stress/'ti60f225_oob.bit',out/'ti60f225_oob.bit')
if (ROOT/'docs/PIXELFORGE.md').exists():shutil.copy2(ROOT/'docs/PIXELFORGE.md',out/'README.md')
sources=list((ROOT/'software/lunaria').glob('*.c'))+list((ROOT/'software/lunaria').glob('*.h'))+[ROOT/'software/apb_reg_test/accel_api.h',Path(__file__).resolve(),ROOT/'scripts/build_apb_software.py']
build=dict(name='PixelForge',defines=defines,maximum_bullets=capacity,bullet_texture_size=16,hardware=hardware,ocram_headroom=RAM_END-elf.symbol('_sp'),elf_sha256=sha(out/'PixelForge.elf'),sources={p.relative_to(ROOT).as_posix():sha(p) for p in sources})
(out/'build-info.json').write_text(json.dumps(build,indent=2)+'\n',encoding='utf8')
if (out/'checks.json').exists():
    report=json.loads((out/'checks.json').read_text(encoding='utf8'))
    if report.get('elf_sha256')!=sha(out/'PixelForge.elf'):(out/'checks.json').unlink()
manifest=dict(name='PixelForge',maximum_bullets=capacity,bullet_texture_size=16,board_tested=False,stable_60_fps_measured=False,stress_reference={'bullets':1855,'fps':60,'bullet_size':8,'applies_to_game':False},artifacts={p.name:sha(p) for p in out.iterdir() if p.is_file() and p.name!='manifest.json'})
(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf8')
assert all(sha(p)==h for p,h in protected.items())
print('PASS PixelForge package; capacity',capacity,'RAM headroom',build['ocram_headroom'])
