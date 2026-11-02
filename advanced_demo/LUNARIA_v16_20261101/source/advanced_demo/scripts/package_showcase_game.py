"""Verify and package independent v11 and v10 fallback, without accessing a board."""
from pathlib import Path
import configparser
import hashlib
import json
import re
import shutil
import sys
import zipfile

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from game_debug_bridge import ElfImage, BUILD_CONFIG_FIELDS

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def write_json(path,value):
    path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n',encoding='utf8')

protected=json.loads((ROOT/'output/showcase_protected.json').read_text(encoding='utf8'))
for name,digest in protected.items():
    assert sha(ROOT/name)==digest, 'Protected baseline changed: '+name

hardware=ROOT/'output/showcase_v11_hardware'
out=hardware/'outflow'
state=configparser.ConfigParser()
state.read(out/'ti60f225_oob.proj_state.ini')
assert state.get('state','last_run_state')=='pass' and state.get('state','last_run_flow')=='bitstream'
snapshot=json.loads((hardware/'source_manifest.json').read_text(encoding='utf8'))
assert snapshot['hardware_version']=='0x000b0000' and snapshot['capabilities']=='0x00007ffb'
for name,digest in snapshot['sources'].items():
    if name=='ti60f225_oob.xml':
        # Efinity removes the final newline when saving the project. Check the
        # original bytes against their digest and allow only this exact change.
        assert sha(ROOT/name)==digest
        assert (hardware/name).read_text(encoding='utf8')==(ROOT/name).read_text(encoding='utf8').rstrip('\n')
    else:
        assert sha(hardware/name)==digest, 'Compiled snapshot changed: '+name
    if name!='rtl/ti60f225_oob_top.v':
        assert sha(ROOT/name)==digest, 'Source changed since compile: '+name
expected_top=(ROOT/'rtl/ti60f225_oob_top.v').read_text(encoding='utf8')
for parameter in ('DISPLAY_WINDOW_ENABLE','DISPLAY_SCALE2_ENABLE','ALPHA_STREAM_ENABLE','ALPHA_SPRITE_CACHE_ENABLE'):
    expected_top=expected_top.replace(f'parameter {parameter} = 0,',f'parameter {parameter} = 1,')
expected_top=expected_top.replace('parameter [31:0] HARDWARE_VERSION = 0,',
                                "parameter [31:0] HARDWARE_VERSION = 32'h000b0000,")
assert expected_top==(hardware/'rtl/ti60f225_oob_top.v').read_text(encoding='utf8')
assert sha(ROOT/'software/flash/jtag_wait.hex')==sha(hardware/'software/flash/jtag_wait.hex')
bit=out/'ti60f225_oob.bit'
assert bit.stat().st_mtime>max((hardware/name).stat().st_mtime for name in snapshot['sources']
                              if name!='ti60f225_oob.xml')

timing=(out/'ti60f225_oob.timing.rpt').read_text(encoding='utf8',errors='replace')
relation=timing.split('Setup (Max) Clock Relationship',1)[1].split('---------- Clock Relationship Summary (end)',1)[0]
setup_text,hold_text=relation.split('Hold (Min) Clock Relationship',1)
def timing_rows(text):
    return re.findall(r'^(\S+)\s+(\S+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+\([RF]-[RF]\)',text,re.M)
setup,hold=timing_rows(setup_text),timing_rows(hold_text)
assert setup and hold and all(float(row[3])>=0 for row in setup+hold), 'Setup/hold failed'
timing_summary={'core_hz':100000000,
                'core_setup_slack_ns':float(next(row[3] for row in setup if row[:2]==('core_clk','core_clk'))),
                'minimum_setup_slack_ns':min(float(row[3]) for row in setup),
                'minimum_hold_slack_ns':min(float(row[3]) for row in hold)}
resources=(out/'ti60f225_oob.place.rpt').read_text(encoding='utf8')
def resource(name):
    match=re.search(r'^'+name+r': (\d+) / (\d+) \(([\d.]+)%\)',resources,re.M)
    assert match, name
    return {'used':int(match[1]),'available':int(match[2]),'percent':float(match[3])}
resource_summary={name:resource(name) for name in ('XLRs','Memory Blocks','DSP Blocks')}
map_report=(out/'ti60f225_oob.map.rpt').read_text(encoding='utf8',errors='replace')
assert re.search(r'scaled_window_output\.composer:window_scale2_composer.*8\(8\)',map_report), 'Scaler RAM inference missing'

configs={}
for variant,capacity in (('game-showcase',256),('game-showcase-benchmark',512)):
    elf=ROOT/'software/interactive_demo/build'/variant/'survival_game.elf'
    image=ElfImage(elf)  # validates every load segment, including BSS and stack
    config={key:image.symbol_u32('g_game_build_config',i) for i,key in enumerate(BUILD_CONFIG_FIELDS)}
    assert config['view_width']==640 and config['view_height']==480
    assert config['view_x']==640 and config['view_y']==300
    assert not config['fullscreen'] and not config['flash_enabled'] and config['require_queue']
    assert config['team_sprites']==1 and config['enemy_bullet_limit']==capacity
    assert image.symbol_u32('g_game_scale2_compatible')==0x4000
    assert image.symbol_u32('g_game_required_caps')==0xE00
    assert image.symbol_u32('g_game_stress_limits',3)==capacity
    assert image.symbols['g_debug_control'][1]==32
    if capacity==256: assert image.symbol_u32('g_game_showcase_available')==1
    else: assert 'g_game_showcase_available' not in image.symbols
    map_text=elf.with_suffix('.map').read_text(encoding='utf8')
    stack=re.search(r'^\.stack\s+(0x[\da-f]+)\s+(0x[\da-f]+)',map_text,re.M)
    assert stack and int(stack[2],16)==8192
    stack_base=int(stack[1],16)
    stack_top=image.symbols['_sp'][0]
    assert stack_top==stack_base+8192 and stack_top<=0xF900FC00
    assert stack_base>=image.symbols['_end'][0]
    assert elf.stat().st_mtime>=max(p.stat().st_mtime for folder in ('software/interactive_demo','software/apb_reg_test')
                                  for p in (ROOT/folder).glob('*') if p.suffix in ('.c','.h'))
    configs[variant]={'config':config,'elf_sha256':sha(elf),'stack_bytes':8192,
                     'stack_base':hex(stack_base),'stack_top':hex(stack_top),
                     'bytes_before_debug_reserved':0xF900FC00-stack_top,
                     'debug_reserved':[hex(0xF900FC00),hex(0xF9010000)]}

checks={
    'showcase_host_checks.log':'PASS showcase host checks (no board connected)',
    'showcase_scale2_checks.log':'REAL_CVO=1 SCALE2=1',
    'showcase_scale2_unit_checks.log':'reset/blank with pending reads',
    'showcase_legacy_software_checks.log':'PASS real OpenOCD Jim Tcl',
    'showcase_debug_checks.log':'Ran 35 tests',
    'showcase_alpha_checks.log':'PASS Alpha arithmetic/DMA/APB',
    'showcase_hardware_compile.log':'pgm :',
    'showcase_software_build.log':'game-showcase-benchmark',
}
for name,marker in checks.items():
    log=(ROOT/'output'/name).read_text(encoding='utf8',errors='replace')
    assert marker in log and 'Traceback (most recent call last)' not in log, 'Incomplete check: '+name

packages=[]
for version in (11,10):
    target=ROOT/('output/showcase_v11' if version==11 else 'output/showcase_v10_fallback')
    target.mkdir(parents=True,exist_ok=True)
    pairs=[(bit if version==11 else ROOT/'output/window640_alpha_v10/ti60f225_oob.bit','ti60f225_oob.bit'),
           (ROOT/'software/interactive_demo/build/game-showcase/survival_game.elf','survival_game.elf'),
           (ROOT/'software/interactive_demo/build/game-showcase-benchmark/survival_game.elf','benchmark.elf'),
           (ROOT/'docs/SHOWCASE_GAME.md','使用说明.md'),
           (ROOT/'output/showcase_preview.png','showcase_preview.png')]
    for source,name in pairs: shutil.copy2(source,target/name)
    reports=target/'evidence'
    reports.mkdir(exist_ok=True)
    for name in checks: shutil.copy2(ROOT/'output'/name,reports/name)
    if version==11:
        for source in (hardware/'source_manifest.json',out/'ti60f225_oob.timing.rpt',
                       out/'ti60f225_oob.place.rpt',out/'ti60f225_oob.map.rpt',out/'ti60f225_oob.proj_state.ini'):
            shutil.copy2(source,reports/source.name)
    else:
        for name in ('ti60f225_oob.timing.rpt','ti60f225_oob.place.rpt','manifest.json'):
            shutil.copy2(ROOT/'output/window640_alpha_v10'/name,reports/('original_v10_'+name))
    for file,elf in (('start_debug.cmd','survival_game.elf'),('start_benchmark.cmd','benchmark.elf')):
        (target/file).write_text('@echo off\ncall "%~dp0..\\..\\start_game_debug.cmd" --elf "%~dp0'+elf+'"\n',encoding='ascii')
    manifest={'hardware_version':f'0x{version*0x10000:08x}',
              'capabilities':'0x00007ffb' if version==11 else '0x00003ffb',
              'board_tested':False,'stable_60_fps_measured':False,'board_endurance_tested':False,
              'presentation_window':[320,60,1280,960] if version==11 else [640,300,640,480],
              'source_window':[640,300,640,480],'output':[1920,1080,60],
              'source_beats_per_frame':76800,'source_bytes_per_second_at_60hz':73728000,
              'core_hz':100000000,'software':configs,
              'matched_benchmark':'same benchmark.elf, original pressure assets, 48/470, Alpha225',
              'showcase_background':'full supplied island fitted at upload, original header unchanged',
              'showcase_atlas':'original team aircraft/explosions + downsampled hit frames + orange enemy shot',
              'timing':timing_summary if version==11 else 'See evidence/original_v10_manifest.json',
              'resources':resource_summary if version==11 else 'See evidence/original_v10_manifest.json',
              'protected_artifacts_unchanged':protected,
              'manual_acceptance':'使用说明.md / 用户板端验收',
              'host_playthrough_ms':[46144,46144,46144],
              'host_playthrough_debug_invincibility':True,'host_endurance_seconds':600}
    write_json(target/'manifest.json',manifest)
    files=sorted(p for p in target.rglob('*') if p.is_file() and p.name!='SHA256SUMS.txt')
    (target/'SHA256SUMS.txt').write_text(''.join(f'{sha(p)}  {p.relative_to(target).as_posix()}\n' for p in files),encoding='utf8')
    packages.append(target)

# Bundle the launchers' exact relative dependencies and a reproducible source snapshot.
archive=ROOT/'output/showcase_delivery_20261029.zip'
paths=set()
for folder in ('rtl','constraints','ip','embedded_sw','scripts','sim','tools','docs'):
    for path in (ROOT/folder).rglob('*'):
        if path.is_file() and not any(part in ('build','__pycache__','.metadata') for part in path.relative_to(ROOT).parts):
            paths.add(path)
for folder in ('interactive_demo','apb_reg_test','flash','m1b_compare'):
    for path in (ROOT/'software'/folder).rglob('*'):
        if path.is_file() and not any(part in ('build','__pycache__') for part in path.relative_to(ROOT).parts):
            paths.add(path)
for target in packages:
    paths.update(p for p in target.rglob('*') if p.is_file())
for name in protected:
    paths.add(ROOT/name)
paths.update(p for p in (ROOT/'output/window640_alpha_v10').rglob('*') if p.is_file())
for name in ('README.md','start_game_debug.cmd','start_showcase_debug.cmd','start_showcase_benchmark_debug.cmd',
             'ti60f225_oob.xml','ti60f225_oob.peri.xml','ti60f225_oob.sdc','output/showcase_protected.json'):
    paths.add(ROOT/name)
# Root starters use the packaged ELFs instead of ignored compiler output.
archive_launchers={
    'start_showcase_debug.cmd':'@echo off\ncall "%~dp0output\\showcase_v11\\start_debug.cmd"\n',
    'start_showcase_benchmark_debug.cmd':'@echo off\ncall "%~dp0output\\showcase_v11\\start_benchmark.cmd"\n'}
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as zipped:
    entries={}
    for path in sorted(paths):
        name=path.relative_to(ROOT).as_posix()
        data=archive_launchers[name].encode('ascii') if name in archive_launchers else path.read_bytes()
        zipped.writestr('advanced_demo/'+name,data)
        entries[name]=hashlib.sha256(data).hexdigest()
    zipped.writestr('advanced_demo/source_delivery_manifest.json',json.dumps(entries,indent=2)+'\n')
with zipfile.ZipFile(archive) as zipped:
    assert zipped.testzip() is None
    for target in packages:
        for line in (target/'SHA256SUMS.txt').read_text(encoding='utf8').splitlines():
            digest,name=line.split('  ',1)
            data=zipped.read('advanced_demo/'+target.relative_to(ROOT).as_posix()+'/'+name)
            assert hashlib.sha256(data).hexdigest()==digest
    for name,digest in protected.items():
        assert hashlib.sha256(zipped.read('advanced_demo/'+name)).hexdigest()==digest
(archive.with_suffix('.zip.sha256')).write_text(sha(archive)+'  '+archive.name+'\n',encoding='ascii')
print(json.dumps({'packages':[str(p) for p in packages],'zip':str(archive),
                  'timing':timing_summary,'resources':resource_summary,
                  'software':configs,'board_tested':False},ensure_ascii=False,indent=2))
