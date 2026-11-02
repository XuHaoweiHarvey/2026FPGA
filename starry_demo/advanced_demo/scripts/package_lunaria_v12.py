"""Refresh the existing v12 delivery in place; keep firmware and artwork matched."""
from pathlib import Path
import hashlib
import json
import shutil
import sys
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'tools'))
from game_debug_bridge import ElfImage, RAM_END
hw = ROOT/'output/lunaria_hardware_v12'
bit = hw/'outflow/ti60f225_oob.bit'
elf = ROOT/'software/lunaria/build/lunaria.elf'
image = ElfImage(elf)
assert image.symbol_u32('g_lunaria_required_hardware') == 0xc0000
assert image.symbol('_sp') <= RAM_END
assert bit.is_file(), 'Complete Efinity compilation before packaging'
# Reject stale RTL and firmware before producing a reviewable candidate.
for source in (ROOT/'rtl').rglob('*.v'):
    prepared = hw/source.relative_to(ROOT)
    if source.name != 'ti60f225_oob_top.v':
        assert source.read_text(encoding='utf8') == prepared.read_text(encoding='utf8'), str(source)
build_info = json.loads((elf.parent/'build-info.json').read_text(encoding='utf8'))
for name,digest in build_info['sources'].items():
    assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest() == digest, name

assert hashlib.sha256(elf.read_bytes()).hexdigest() == build_info['elf_sha256']
for name,digest in build_info['assets'].items():
    assert hashlib.sha256((ROOT/'output/lunaria'/name).read_bytes()).hexdigest() == digest, name

out = ROOT/'delivery/lunaria_v12'
out.mkdir(parents=True, exist_ok=True)
for name in ('lunaria.elf','lunaria.map','build-info.json'):
    shutil.copy2(elf.parent/name, out/name)
for name in ('assets.json','atlas.argb','background.argb'):
    shutil.copy2(ROOT/'output/lunaria'/name, out/name)
shutil.copy2(bit, out/bit.name)
shutil.copy2(ROOT/'docs/LUNARIA_V12.md',out/'README.md')
for p in (hw/'outflow').glob('*.rpt'):
    if any(k in p.name for k in ('timing','place','route')): shutil.copy2(p,out/p.name)
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
sources = [p for folder in ('rtl','software/lunaria','tools','scripts') for p in (ROOT/folder).rglob('*')
           if p.is_file() and p.suffix in ('.v','.c','.h','.py') and 'build' not in p.parts]
manifest = dict(version='v12', core_hz=100000000, maximum_bullets=640, default_bullets=256,
    revision='bullet-contrast-2026-11-01',
    board_tested=False, stable_60_fps_measured=False,
    previous_user_report={'count':551,'fps':60,'applies_to_current_revision':False},
    ocram_headroom=RAM_END-image.symbol('_sp'),
    sources={str(p.relative_to(ROOT)):sha(p) for p in sources},
    artifacts={p.name:sha(p) for p in out.iterdir() if p.is_file() and p.name!='manifest.json'})
(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf8')
print('Packaged candidate:',out)
print('Board FPS qualification is still required.')
