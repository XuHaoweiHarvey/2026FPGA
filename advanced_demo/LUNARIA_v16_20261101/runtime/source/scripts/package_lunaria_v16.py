"""Assemble a separate verified v16 package; never touch the v15.1 delivery."""
from pathlib import Path
import hashlib,json,shutil,sys
ROOT=Path(__file__).resolve().parents[1]
STAGE=ROOT/'output/lunaria_v16_candidate'
OUT=ROOT/'output/lunaria_v16'
sys.path.insert(0,str(ROOT/'tools'))
from game_debug_bridge import ElfImage,RAM_START,RAM_END
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def copy(a,b):
    b.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(a,b);assert sha(a)==sha(b)
def verified(path):
    r=json.loads(path.read_text(encoding='utf8'))
    assert r.get('status',r.get('logic_render'))=='passed',path
    for key in ('sources','source_sha256'):
        for n,h in r.get(key,{}).items():assert sha(ROOT/n)==h,'Stale check: '+n
    return r
def main():
    records={}
    for n in ('hardware-v16','host','loader','parity','memory','pool','cost','render','beam','startup'):
        p=STAGE/f'verification/{n}-checks.json';records[n]=verified(p)
    hardware=records['hardware-v16']
    for item in hardware['checks'].values():assert sha(ROOT/item['path'])==item['sha256'],item
    extras={'tile-trace':'output/lunaria_v16_trace/trace-tile-checks.json',
       'tile-fault':'output/lunaria_v16_faults/checks.json',
       'tile-contract':'output/lunaria_v16_contract/checks.json',
       'tile-latency':'output/lunaria_v16_latency/checks.json',
       'integration':'output/lunaria_v16_integration_final/checks.json',
       'queue':'output/lunaria_v16_queue/checks.json','legacy-ddr':'output/lunaria_v15_checks/checks.json',
       'upload-ddr':'output/lunaria_v151_upload/checks.json'}
    for n,path in extras.items():records[n]=verified(ROOT/path)
    elf=ROOT/'software/lunaria/build/lunaria.elf';image=ElfImage(elf)
    build=json.loads((elf.parent/'build-info.json').read_text(encoding='utf8'))
    assert sha(elf)==build['elf_sha256']
    for n,h in build['sources'].items():assert sha(ROOT/n)==h,n
    for n,h in build['assets'].items():assert sha(STAGE/n)==h,n
    for n in ('loader','memory','startup'):assert records[n]['elf_sha256']==sha(elf),n
    pc=json.loads((STAGE/'pc-build-info.json').read_text(encoding='utf8'))
    for n,h in pc['sources'].items():assert sha(ROOT/n)==h,n
    for n,h in pc['dlls'].items():assert sha(STAGE/n)==h,n
    for n in ('parity','render','beam'):
        for name,h in records[n]['dlls'].items():assert pc['dlls'][name]==h,name
    assert records['tile-trace']['dll_sha256']==records['cost']['dll_sha256']==sha(STAGE/'lunaria_pc.dll')
    assert records['tile-trace']['atlas_sha256']==records['render']['atlas_sha256']==sha(STAGE/'atlas.argb')
    assert image.symbol_u32('g_lunaria_v16_compatible')==0x80000
    assert image.symbols['__stack_size'][0]==8192 and image.symbol('_sp')<=RAM_END
    protected=json.loads((ROOT/'output/showcase_protected.json').read_text(encoding='utf8'))
    for n,h in protected.items():assert sha(ROOT/n)==h,n
    # Check the entire existing delivery before writing the new, separate one.
    for folder in (ROOT/'output/lunaria',ROOT/'output/lunaria_v151_delivery'):
        for row in (folder/'SHA256SUMS.txt').read_text(encoding='utf8').splitlines():
            h,n=row.split('  ',1)
            # Historical manifests included Python's disposable runtime cache.
            if '__pycache__' in Path(n).parts:continue
            assert sha(folder/n)==h,'Baseline changed: '+str(folder/n)
    OUT.mkdir(exist_ok=True)
    for n in ('lunaria.elf','lunaria.map','lunaria.disasm','build-info.json'):copy(elf.parent/n,OUT/n)
    for n in ('atlas.argb','background.argb','assets.json','atlas.png','background.png','pc-build-info.json',*pc['dlls']):copy(STAGE/n,OUT/n)
    for n in ('game_debug_bridge.py','game_debug_window.py','keyboard_uart.py','lunaria_debug_bridge.py','lunaria_debug_window.py','lunaria_pc.py'):
        copy(ROOT/'tools'/n,OUT/'tools'/n)
    for n in ('debug_ti.cfg','ftdi_ti.cfg'):copy(ROOT/'software/apb_reg_test/openocd'/n,OUT/'software/apb_reg_test/openocd'/n)
    copy(ROOT/'embedded_sw/soc_control/cpu0.yaml',OUT/'embedded_sw/soc_control/cpu0.yaml')
    for n in ('start_debug.cmd','start_preview.cmd'):copy(STAGE/n,OUT/n)
    copy(ROOT/'docs/LUNARIA_DDR_V16.md',OUT/'使用说明.md')
    buildroot=ROOT/'output/lunaria_v16_hardware'
    for n,target in (('outflow/ti60f225_oob.bit','ti60f225_oob.bit'),('outflow/ti60f225_oob.timing.rpt','timing.rpt'),
                     ('outflow/ti60f225_oob.place.rpt','placement.rpt'),('source_manifest.json','source_manifest.json')):
        copy(buildroot/n,OUT/'hardware/v16'/target)
    assert sha(OUT/'hardware/v16/ti60f225_oob.bit')==hardware['bit_sha256']
    for n in records:
        p=ROOT/extras[n] if n in extras else STAGE/f'verification/{n}-checks.json'
        copy(p,OUT/f'verification/{n}-checks.json')
    for item in hardware['checks'].values():
        if item['path'].endswith('.log'):copy(ROOT/item['path'],OUT/'verification'/Path(item['path']).name)
    source_names=set(build['sources'])|set(pc['sources'])
    for r in records.values():source_names.update(r.get('sources',{}));source_names.update(r.get('source_sha256',{}))
    source_names.update(('scripts/package_lunaria_v16.py','scripts/check_lunaria_v16_delivery.py','docs/LUNARIA_DDR_V16.md'))
    for n in sorted(source_names):copy(ROOT/n,OUT/'source'/n)
    manifest=dict(name='LUNARIA v16',revision='v16-tile-compositor',recommended_hardware='v16',
        hardware_version='0x00100000',capabilities='0x000ffffb',board_tested=False,stable_60_fps_measured=False,
        read_outstanding=1,elf_sha256=sha(elf),bit_sha256=hardware['bit_sha256'],
        settings=dict(minimum_bullets=64,maximum_bullets=4096,default_bullets=256),
        ocram=dict(stack_bytes=8192,used_including_stack=image.symbol('_sp')-RAM_START,headroom=RAM_END-image.symbol('_sp')),
        source_window=[640,300,640,480],display_window=[320,60,1280,960],
        checks={n:sha(OUT/f'verification/{n}-checks.json') for n in records},
        source_snapshot='Review sources; rebuild from the full workspace.',ea05_recovery_board_verified=False)
    (OUT/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
    files=sorted(p for p in OUT.rglob('*') if p.is_file() and p.name!='SHA256SUMS.txt' and '__pycache__' not in p.parts)
    (OUT/'SHA256SUMS.txt').write_text(''.join(sha(p)+'  '+p.relative_to(OUT).as_posix()+'\n' for p in files),encoding='utf8')
    print(f'PASS separate v16 delivery: {OUT}; {len(files)} files; no board connection')
if __name__=='__main__':main()
