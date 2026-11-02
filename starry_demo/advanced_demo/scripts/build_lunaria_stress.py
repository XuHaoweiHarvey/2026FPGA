"""Build/package a separate stress firmware without replacing the normal ELF."""
from pathlib import Path
import argparse
import hashlib
import re
import json
import shutil
import subprocess
import sys
import tempfile
import time
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'tools'))
from game_debug_bridge import ElfImage, RAM_END
from lunaria_debug_bridge import read_assets, fnv_words

out = ROOT/'delivery/lunaria_stress'
assets = ROOT/'output/lunaria'
hw = ROOT/'output/lunaria_hardware_v12'  # Reuse the existing complete build tree.
bit = hw/'outflow/ti60f225_oob.bit'
HARDWARE_VERSION = 0xD0000
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--hardware', choices=('prepare','compile','package'), default='package')
parser.add_argument('--efinity', type=Path, default=Path('D:/Efinity/2026.1'))
args = parser.parse_args()
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
normal = ROOT/'delivery/lunaria_v12'
normal_hashes = {p.name: sha(p) for p in normal.iterdir() if p.is_file()}
# Only changed inputs are rewritten, so package can reject a stale bit by mtime.
# The historical directory name stays unchanged; its project now builds stress v13.
def prepared_top():
    text = (ROOT/'rtl/ti60f225_oob_top.v').read_text(encoding='utf8')
    for name in ('DISPLAY_WINDOW_ENABLE','DISPLAY_SCALE2_ENABLE','ALPHA_PIXEL_X_ENABLE',
                 'ALPHA_STREAM_ENABLE','ALPHA_SPRITE_CACHE_ENABLE'):
        old = f'parameter {name} = 0,'
        assert text.count(old) == 1, name
        text = text.replace(old, f'parameter {name} = 1,')
    old = 'parameter [31:0] HARDWARE_VERSION = 0,'
    assert text.count(old) == 1
    return text.replace(old, f"parameter [31:0] HARDWARE_VERSION = 32'h{HARDWARE_VERSION:08x},")

def hardware_sources():
    files = [p for folder in ('rtl','ip','constraints','embedded_sw') for p in (hw/folder).rglob('*')
             if p.is_file() and p.suffix in ('.v','.sv','.vh','.sdc','.json','.hex')]
    return files+[hw/n for n in ('ti60f225_oob.xml','ti60f225_oob.peri.xml','ti60f225_oob.sdc','software/flash/jtag_wait.hex')]

def input_digest(path):
    # Efinity rewrites only the project XML's trailing whitespace on completion.
    data = path.read_bytes().strip() if path == hw/'ti60f225_oob.xml' else path.read_bytes()
    return hashlib.sha256(data).hexdigest()

if args.hardware in ('prepare','compile'):
    assert (hw/'ip/soc_control/soc_control.v').exists(), 'Existing generated IP is required'
    for source in (ROOT/'rtl').rglob('*'):
        if source.is_file() and source.suffix in ('.v','.sv','.vh'):
            target = hw/source.relative_to(ROOT)
            data = prepared_top().encode('utf8') if source.name == 'ti60f225_oob_top.v' else source.read_bytes()
            assert target.exists(), f'Expected existing project file: {target}'
            if target.read_bytes() != data:
                target.write_bytes(data)
    # Reuse the existing build-info file to carry input provenance across a GUI
    # compile. This also catches project XML changes despite Efinity's late touch.
    pending = dict(prepared_at=time.time(), sources={p.relative_to(hw).as_posix():input_digest(p)
                   for p in hardware_sources()})
    previous = json.loads((out/'build-info.json').read_text(encoding='utf8'))
    previous['hardware_pending'] = pending
    (out/'build-info.json').write_text(json.dumps(previous,indent=2)+'\n',encoding='utf8')
    print('Prepared stress v13 in existing project:', hw, flush=True)
    if args.hardware == 'prepare':
        print('Run Efinity full Compile, then this script with --hardware package.')
        sys.exit(0)
    compile_inputs = {p:input_digest(p) for p in hardware_sources()}
    compile_start = time.time()
    subprocess.run(['cmd','/c',str(args.efinity/'bin/efx_run.bat'),
                    'ti60f225_oob.xml','--flow','compile'],cwd=hw,check=True)
    assert all(input_digest(p)==digest for p,digest in compile_inputs.items()), 'Inputs changed during compilation'
    assert bit.stat().st_mtime >= compile_start, 'Compiler did not replace the bit'

assert (hw/'rtl/ti60f225_oob_top.v').read_text(encoding='utf8') == prepared_top(), 'Run --hardware prepare/compile first'
for source in (ROOT/'rtl').rglob('*'):
    if source.is_file() and source.suffix in ('.v','.sv','.vh') and source.name != 'ti60f225_oob_top.v':
        assert sha(source) == sha(hw/source.relative_to(ROOT)), f'Unprepared RTL: {source}'
hw_sources = hardware_sources()
current_inputs = {p.relative_to(hw).as_posix():input_digest(p) for p in hw_sources}
previous = json.loads((out/'build-info.json').read_text(encoding='utf8'))
pending = previous.get('hardware_pending')
if pending:
    assert current_inputs == pending['sources'], 'Prepared hardware inputs changed: prepare and compile again'
    assert bit.exists() and bit.stat().st_mtime >= pending['prepared_at'], 'Compile the prepared hardware first'
else:
    recorded = previous.get('hardware', {})
    assert current_inputs == recorded.get('sources'), 'Hardware inputs changed: run --hardware prepare/compile'
    assert bit.exists() and sha(bit) == recorded.get('bit_sha256'), 'Unrecorded bit: prepare and compile before packaging'
# The tool rewrites project XML after bit generation; use its content hash, not mtime.
input_time = max(p.stat().st_mtime for p in hw_sources if p != hw/'ti60f225_oob.xml')
assert bit.exists(), 'Complete Efinity compilation before packaging'
assert bit.stat().st_mtime >= input_time, 'Stale bit: run full Efinity Compile'
timing_path = hw/'outflow/ti60f225_oob.timing.rpt'
assert timing_path.stat().st_mtime >= input_time, 'Stale timing report'
if pending:
    assert timing_path.stat().st_mtime >= pending['prepared_at'], 'Compile did not update timing report'
timing = timing_path.read_text(errors='replace')
relationship = timing.split('Setup (Max) Clock Relationship',1)[1].split('---------- Clock Relationship Summary (end)',1)[0]
setup_text, hold_text = relationship.split('Hold (Min) Clock Relationship')
slacks = lambda text: [float(m[1]) for m in re.findall(r'^\s*\S+\s+\S+\s+(-?[\d.]+)\s+(-?[\d.]+)\s+\(',text,re.M)]
setup, hold = slacks(setup_text), slacks(hold_text)
assert setup and hold and min(setup) >= 0 and min(hold) >= 0, 'Timing closure failed'
assert re.search(r'^core_clk\s+10\.000\s+100\.000', timing, re.M), 'Unexpected core clock'
core_setup = float(re.search(r'^core_clk\s+core_clk\s+10\.000\s+([\d.]+)',setup_text,re.M)[1])
place = (hw/'outflow/ti60f225_oob.place.rpt').read_text(errors='replace')
resources = {}
for label in ('XLRs','Memory Blocks','DSP Blocks'):
    used,total = re.search(r'^'+label+r': (\d+) / (\d+)',place,re.M).groups()
    resources[label] = dict(used=int(used),available=int(total))
hardware = dict(version=hex(HARDWARE_VERSION),core_hz=100000000,
                project=hw.relative_to(ROOT).as_posix()+'/ti60f225_oob.xml',
                setup_min_ns=min(setup),hold_min_ns=min(hold),core_setup_ns=core_setup,resources=resources,
                bit_sha256=sha(bit),timing_sha256=sha(timing_path),
                sources=current_inputs)
# Repack only the stress atlas, without touching shared/normal artwork.
# Shrink the existing high-contrast round bullet for an 8x8 stress workload.
out.mkdir(exist_ok=True)
atlas = Image.frombytes('RGBA',(640,480),(assets/'atlas.argb').read_bytes(),'raw','BGRA')
original = atlas.crop((448,0,464,16))
assert original.getchannel('A').getbbox() == (2,2,14,14)
tile = original.crop((2,2,14,14)).resize((8,8), Image.Resampling.LANCZOS)
atlas.paste(tile,(448,64))
data = atlas.tobytes('raw','BGRA')
asset_manifest = json.loads((assets/'assets.json').read_text())
asset_manifest['assets']['atlas'].update(fnv_words=fnv_words(data),sha256=hashlib.sha256(data).hexdigest())
asset_manifest['bullet_size'] = 8
asset_manifest['stress_bullet_rect'] = [448,64,8,8]
defines = ['LN_STRESS_ATLAS_HASH='+hex(fnv_words(data)), 'GAME_DISPLAY_WINDOW=1', 'GAME_ALLOW_SCALE2=1', 'LUNARIA_PIXEL_X=1', 'LN_STRESS_TEST=1', 'LUNARIA_HARDWARE_VERSION='+hex(HARDWARE_VERSION)]
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
    assert image.symbol_u32('g_lunaria_required_hardware') == HARDWARE_VERSION
    assert image.symbol('_sp') <= RAM_END
    assert image.symbol_u32('g_lunaria_settings',10) == 2048
    artwork = read_assets(assets/'assets.json')
    assert [artwork[0][1],fnv_words(data)] == [image.symbol_u32('g_lunaria_asset_hashes', i) for i in range(2)]
    (out/'atlas.argb').write_bytes(data)
    shutil.copy2(assets/'background.argb',out/'background.argb')
    (out/'assets.json').write_text(json.dumps(asset_manifest,indent=2)+'\n',encoding='utf8')
    out.mkdir(exist_ok=True)
    for name in ('lunaria.elf', 'lunaria.map'):
        shutil.copy2(temp/name, out/name)
    sources = list((ROOT/'software/lunaria').glob('*.c')) + list((ROOT/'software/lunaria').glob('*.h'))
    sources += [ROOT/'scripts/build_lunaria_stress.py', ROOT/'scripts/build_apb_software.py', ROOT/'software/apb_reg_test/accel_api.h']
    build = dict(variant='stress', defines=defines, elf_sha256=sha(out/'lunaria.elf'), hardware=hardware,
                 sources={p.relative_to(ROOT).as_posix(): sha(p) for p in sources},
                 assets={n: sha(out/n) for n in ('assets.json', 'atlas.argb', 'background.argb')})
    (out/'build-info.json').write_text(json.dumps(build, indent=2)+'\n', encoding='utf8')
    headroom = RAM_END-image.symbol('_sp')
if not (out/bit.name).exists() or sha(bit) != sha(out/bit.name):
    shutil.copy2(bit, out/bit.name)
shutil.copy2(ROOT/'docs/LUNARIA_STRESS.md', out/'README.md')
report = ROOT/'output/lunaria/verification/stress-checks.json'
if report.exists():
    data = json.loads(report.read_text())
    if (data.get('elf_sha256') == sha(out/'lunaria.elf') and
            data.get('bit_sha256') == sha(bit) and
            all((ROOT/name).exists() and sha(ROOT/name)==digest for name,digest in data.get('sources',{}).items())):
        shutil.copy2(report, out/report.name)
    elif (out/report.name).exists():
        (out/report.name).unlink()
manifest = dict(variant='stress', core_hz=100000000, default_bullets=256, maximum_bullets=2048,
                revision='stress-round4', bullet_texture_size=8, hardware=hardware,
                previous_user_report={'stable_bullets':1280,'fps':60,'revision':'stress-round3','applies_to_this_revision':False},
                always_invincible=True, board_tested=False, stable_60_fps_measured=False,
                ocram_headroom=headroom,
                artifacts={p.name: sha(p) for p in out.iterdir() if p.is_file() and p.name!='manifest.json'})
(out/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n', encoding='utf8')
assert normal_hashes == {p.name: sha(p) for p in normal.iterdir() if p.is_file()}
print('PASS independent stress package:', out, '; RAM headroom:', headroom)
