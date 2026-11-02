"""Build/package a separate stress firmware without replacing the normal ELF."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'tools'))
from game_debug_bridge import ElfImage, RAM_END
from lunaria_debug_bridge import read_assets, fnv_words

out = ROOT/'delivery/lunaria_stress'
assets = ROOT/'output/lunaria'
bit = ROOT/'delivery/lunaria_v12/ti60f225_oob.bit'
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
normal = ROOT/'delivery/lunaria_v12'
normal_hashes = {p.name: sha(p) for p in normal.iterdir() if p.is_file()}
assert sha(bit) == json.loads((normal/'manifest.json').read_text())['artifacts'][bit.name]
# Repack only the stress atlas, without touching shared/normal artwork.
# The round bullet's nontransparent bounding box is exactly (2,2)-(14,14).
out.mkdir(exist_ok=True)
atlas = Image.frombytes('RGBA',(640,480),(assets/'atlas.argb').read_bytes(),'raw','BGRA')
original = atlas.crop((448,0,464,16))
assert original.getchannel('A').getbbox() == (2,2,14,14)
tile = original.crop((2,2,14,14))
atlas.paste(tile,(448,64))
data = atlas.tobytes('raw','BGRA')
asset_manifest = json.loads((assets/'assets.json').read_text())
asset_manifest['assets']['atlas'].update(fnv_words=fnv_words(data),sha256=hashlib.sha256(data).hexdigest())
asset_manifest['bullet_size'] = 12
asset_manifest['stress_bullet_rect'] = [448,64,12,12]
defines = ['LN_STRESS_ATLAS_HASH='+hex(fnv_words(data)), 'GAME_DISPLAY_WINDOW=1', 'GAME_ALLOW_SCALE2=1', 'LUNARIA_PIXEL_X=1', 'LN_STRESS_TEST=1']
with tempfile.TemporaryDirectory(prefix='lunaria-stress-build-') as folder:
    temp = Path(folder)
    command = [sys.executable, '-B', str(ROOT/'scripts/build_apb_software.py'),
               '--program', 'lunaria', '--opt', 'O2', '--ide-root',
               'D:/Efinity/efinity-riscv-ide-2026.1', '--output', str(temp)]
    for define in defines:
        command += ['--define', define]
    subprocess.run(command, cwd=ROOT, check=True)
    image = ElfImage(temp/'lunaria.elf')
    assert image.symbol_u32('g_lunaria_stress_test') == 1
    assert image.symbol_u32('g_lunaria_required_hardware') == 0xc0000
    assert image.symbol('_sp') <= RAM_END
    artwork = read_assets(assets/'assets.json')
    assert [artwork[0][1],fnv_words(data)] == [image.symbol_u32('g_lunaria_asset_hashes', i) for i in range(2)]
    (out/'atlas.argb').write_bytes(data)
    shutil.copy2(assets/'background.argb',out/'background.argb')
    (out/'assets.json').write_text(json.dumps(asset_manifest,indent=2)+'\n',encoding='utf8')
    out.mkdir(exist_ok=True)
    for name in ('lunaria.elf', 'lunaria.map'):
        shutil.copy2(temp/name, out/name)
    sources = list((ROOT/'software/lunaria').glob('*.c')) + list((ROOT/'software/lunaria').glob('*.h'))
    sources += [ROOT/'scripts/build_lunaria_stress.py', ROOT/'scripts/build_apb_software.py']
    build = dict(variant='stress', defines=defines, elf_sha256=sha(out/'lunaria.elf'),
                 sources={p.relative_to(ROOT).as_posix(): sha(p) for p in sources},
                 assets={n: sha(out/n) for n in ('assets.json', 'atlas.argb', 'background.argb')})
    (out/'build-info.json').write_text(json.dumps(build, indent=2)+'\n', encoding='utf8')
    headroom = RAM_END-image.symbol('_sp')
shutil.copy2(bit, out/bit.name)
shutil.copy2(ROOT/'docs/LUNARIA_STRESS.md', out/'README.md')
report = ROOT/'output/lunaria/verification/stress-checks.json'
if report.exists():
    data = json.loads(report.read_text())
    if data.get('elf_sha256') == sha(out/'lunaria.elf'):
        shutil.copy2(report, out/report.name)
    elif (out/report.name).exists():
        (out/report.name).unlink()
manifest = dict(variant='stress', core_hz=100000000, default_bullets=256, maximum_bullets=832,
                revision='stress-round2', bullet_texture_size=12,
                previous_user_report={'stable_bullets':610,'fps':60,'fps_at_640':30,'applies_to_this_revision':False},
                always_invincible=True, board_tested=False, stable_60_fps_measured=False,
                ocram_headroom=headroom,
                artifacts={p.name: sha(p) for p in out.iterdir() if p.is_file() and p.name!='manifest.json'})
(out/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n', encoding='utf8')
assert normal_hashes == {p.name: sha(p) for p in normal.iterdir() if p.is_file()}
print('PASS independent stress package:', out, '; RAM headroom:', headroom)
