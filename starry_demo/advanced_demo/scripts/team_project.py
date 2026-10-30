"""Portable entry points for the complete LUNARIA teammate project."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT.parent
DELIVERY = ROOT / 'delivery/lunaria'
OUTPUT = ROOT / 'output/lunaria'

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def ide_path(require=False):
    explicit = os.environ.get('RISCV_IDE_ROOT')
    candidates = [Path(explicit)] if explicit else []
    efinity = os.environ.get('EFINITY_ROOT')
    if efinity:
        candidates += sorted(Path(efinity).glob('efinity-riscv-ide-*'), reverse=True)
    for drive in 'CDEFGH':
        candidates += sorted(Path(drive + ':/Efinity').glob('efinity-riscv-ide-*'), reverse=True)
    selected = next((p for p in candidates if (p/'openocd/bin/openocd.exe').is_file()), None)
    if require and selected is None:
        raise FileNotFoundError('Set RISCV_IDE_ROOT in paths.local.cmd to the Efinity RISC-V IDE folder.')
    if selected is not None:
        os.environ['RISCV_IDE_ROOT'] = str(selected)
    return selected

def run_script(name, *args):
    subprocess.run([sys.executable, '-B', str(ROOT/'scripts'/name), *map(str,args)], cwd=ROOT, check=True)

def assets_for_build():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for name in ('assets.json','atlas.argb','background.argb','atlas.png','background.png'):
        if not (OUTPUT/name).exists():
            shutil.copy2(DELIVERY/name,OUTPUT/name)

def verify():
    sys.path.insert(0,str(ROOT/'tools'))
    from game_debug_bridge import ElfImage, inspection_config, RAM_END
    from lunaria_debug_bridge import LunariaBridge, read_assets
    xml = ET.parse(ROOT/'ti60f225_oob.xml').getroot()
    namespace = {'e':'http://www.efinixinc.com/enf_proj'}
    names = [n.attrib['name'] for n in xml.findall('.//e:design_file',namespace)]
    assert len(names) == len(set(names)), 'Duplicate FPGA source'
    paths = names + [n.attrib['name'] for tag in ('sdc_file','peri_file','default_peri_file')
                     for n in xml.findall('.//e:'+tag,namespace)]
    paths += [n.attrib['path'] for n in xml.findall('.//e:ip',namespace)]
    assert all((ROOT/name).is_file() for name in paths), 'Missing FPGA project input'
    image = ElfImage(DELIVERY/'lunaria.elf')
    bridge = LunariaBridge(DELIVERY/'lunaria.elf',assets=DELIVERY/'assets.json')
    assert bridge.asset_hashes == [h for _,h in read_assets(DELIVERY/'assets.json')], 'ELF / asset mismatch'
    build = json.loads((DELIVERY/'build-info.json').read_text(encoding='utf8'))
    assert sha(DELIVERY/'lunaria.elf') == build['elf_sha256'], 'ELF differs from build record'
    for name,digest in build['sources'].items():
        assert sha(ROOT/name) == digest, 'Source changed; rebuild: '+name
    for name,digest in build['assets'].items():
        assert sha(DELIVERY/name) == digest, 'Asset changed; rebuild: '+name
    assert image.symbol('_sp') <= RAM_END, 'OCRAM overflow'
    inspection_config()
    manifest = json.loads((DELIVERY/'manifest.json').read_text(encoding='utf8'))
    for variant,digest in manifest['hardware_sha256'].items():
        assert sha(DELIVERY/'hardware'/variant/'ti60f225_oob.bit') == digest, 'Hardware differs: '+variant
    checked = 0
    checksum_file = PACKAGE/'SHA256SUMS.txt'
    if checksum_file.is_file():
        for line in checksum_file.read_text(encoding='utf8').splitlines():
            if not line.strip():
                continue
            digest,name = line.split('  ',1)
            path = (PACKAGE/name).resolve()
            assert path.is_relative_to(PACKAGE.resolve()), 'Invalid checksum path'
            assert sha(path) == digest, 'Package changed since delivery: '+name
            checked += 1
    print('PASS: FPGA inputs, source/build record, ELF, assets, v10/v11 bitstreams, OpenOCD configuration')
    print('PASS: package SHA256 files checked:',checked)
    print('Board operation and actual FPS require board verification.')

def refresh_delivery():
    for name in ('lunaria.elf','lunaria.map','lunaria.disasm','build-info.json'):
        shutil.copy2(ROOT/'software/lunaria/build'/name,DELIVERY/name)
    for name in ('assets.json','atlas.argb','background.argb','atlas.png','background.png'):
        shutil.copy2(OUTPUT/name,DELIVERY/name)
    sys.path.insert(0,str(ROOT/'tools'))
    from game_debug_bridge import ElfImage, BUILD_CONFIG_FIELDS, RAM_START, RAM_END
    image = ElfImage(DELIVERY/'lunaria.elf')
    build = json.loads((DELIVERY/'build-info.json').read_text(encoding='utf8'))
    manifest = json.loads((DELIVERY/'manifest.json').read_text(encoding='utf8'))
    for key in ('host_checks','loader_checks'):
        manifest.pop(key,None)
    manifest.update(elf_sha256=sha(DELIVERY/'lunaria.elf'),build_sources=build['sources'],
                    build_config={key:image.symbol_u32('g_game_build_config',i)
                                  for i,key in enumerate(BUILD_CONFIG_FIELDS)},
                    board_tested=False,stable_60_fps_measured=False,
                    manual_acceptance='../../../README.md',
                    note='Complete editable project is in advanced_demo; built from GitHub 6f021a8.')
    manifest['ocram'] = {'start':hex(RAM_START),'stack_top':hex(image.symbol('_sp')),
                         'stack_bytes':image.symbols['__stack_size'][0],
                         'used_including_stack':image.symbol('_sp')-RAM_START,
                         'bytes_before_debug_reserved':RAM_END-image.symbol('_sp')}
    (DELIVERY/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
    print('Updated delivery/lunaria with the newly built ELF and matching assets.')

def prepare_hardware(variant):
    target = ROOT/'output'/('lunaria_hardware_'+variant)
    target.mkdir(parents=True,exist_ok=True)
    for name in ('rtl','ip','embedded_sw','constraints'):
        shutil.copytree(ROOT/name,target/name,dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns('build','__pycache__','.metadata'))
    for name in ('ti60f225_oob.xml','ti60f225_oob.peri.xml','ti60f225_oob.sdc'):
        shutil.copy2(ROOT/name,target/name)
    (target/'software/flash').mkdir(parents=True,exist_ok=True)
    shutil.copy2(ROOT/'software/flash/jtag_wait.hex',target/'software/flash/jtag_wait.hex')
    top = target/'rtl/ti60f225_oob_top.v'
    text = top.read_text(encoding='utf8')
    for key,value in {'DISPLAY_WINDOW_ENABLE':1,'DISPLAY_SCALE2_ENABLE':int(variant=='v11'),
                      'ALPHA_STREAM_ENABLE':1,'ALPHA_SPRITE_CACHE_ENABLE':1}.items():
        text,count = re.subn(r'(parameter '+key+r' = )\d+(,)',lambda m:m[1]+str(value)+m[2],text)
        assert count == 1,key
    text,count = re.subn(r'(parameter \[31:0\] HARDWARE_VERSION = )[^,]+,',
                         lambda m:m[1]+"32'h000"+('b' if variant=='v11' else 'a')+'0000,',text)
    assert count == 1
    top.write_text(text,encoding='utf8')
    print('Prepared editable hardware project:',target/'ti60f225_oob.xml')
    print('Open this XML in Efinity and Compile. This command does not configure a board.')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=('run','build','verify','loader-checks','hardware'))
    parser.add_argument('--prepare-assets',action='store_true')
    parser.add_argument('--variant',choices=('v10','v11'),default='v11')
    args = parser.parse_args()
    if args.action == 'verify':
        verify()
    elif args.action == 'hardware':
        prepare_hardware(args.variant)
    elif args.action == 'build':
        ide = ide_path(require=True)
        assets_for_build()
        build_args = ['--ide-root',str(ide)]
        if args.prepare_assets:
            build_args += ['--prepare-assets']
        run_script('build_lunaria.py',*build_args)
        refresh_delivery()
        checksums = PACKAGE/'SHA256SUMS.txt'
        if checksums.exists():
            checksums.unlink()
        print('Rebuilt package; regenerate delivery checksums before redistributing changes.')
    elif args.action == 'loader-checks':
        assets_for_build()
        build = ROOT/'software/lunaria/build'
        build.mkdir(parents=True,exist_ok=True)
        if not (build/'lunaria.elf').exists():
            shutil.copy2(DELIVERY/'lunaria.elf',build/'lunaria.elf')
        (OUTPUT/'verification').mkdir(parents=True,exist_ok=True)
        run_script('run_lunaria_loader_checks.py')
    else:
        ide_path()
        subprocess.run([sys.executable,'-B',str(ROOT/'tools/lunaria_debug_window.py'),
                        '--elf',str(DELIVERY/'lunaria.elf'),'--assets',str(DELIVERY/'assets.json')],
                       cwd=ROOT,check=True)

if __name__ == '__main__':
    main()
