"""Assemble a standalone local LUNARIA delivery without accessing a board."""
from pathlib import Path
import hashlib
import json
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT/'output/lunaria'
sys.path.insert(0,str(ROOT/'tools'))
from game_debug_bridge import BUILD_CONFIG_FIELDS, ElfImage, RAM_END, RAM_START
from lunaria_debug_bridge import LunariaBridge, DEFAULT_ELF, read_assets


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def copy(source, target):
    target.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(source,target)
    assert sha(source) == sha(target), str(target)


def main():
    image = ElfImage(DEFAULT_ELF)
    bridge = LunariaBridge()
    assets = read_assets(OUT/'assets.json')
    assert bridge.asset_hashes == [h for _,h in assets]
    report = json.loads((OUT/'verification/host-checks.json').read_text(encoding='utf8'))
    assert report['logic_render'] == 'passed' and report['board_tested'] is False
    build = json.loads((DEFAULT_ELF.parent/'build-info.json').read_text(encoding='utf8'))
    assert build['elf_sha256'] == sha(DEFAULT_ELF), 'Stale build record'
    for name,digest in build['sources'].items():
        assert sha(ROOT/name) == digest, 'Source changed after compilation: '+name
    for name,digest in build['assets'].items():
        assert sha(OUT/name) == digest, 'Assets changed after compilation: '+name
    for name,digest in report['source_sha256'].items():
        assert sha(ROOT/name) == digest, 'Source changed after host checks: '+name
    assert report['atlas_sha256'] == sha(OUT/'atlas.argb'), 'Host render used stale artwork'
    loader = json.loads((OUT/'verification/loader-checks.json').read_text(encoding='utf8'))
    assert loader['status'] == 'passed' and loader['elf_sha256'] == sha(DEFAULT_ELF)
    for name,digest in loader['sources'].items():
        assert sha(ROOT/name) == digest, 'Loader changed after checks: '+name
    parity = json.loads((OUT/'verification/parity-checks.json').read_text(encoding='utf8'))
    memory = json.loads((OUT/'verification/memory-checks.json').read_text(encoding='utf8'))
    pool = json.loads((OUT/'verification/pool-checks.json').read_text(encoding='utf8'))
    cost = json.loads((OUT/'verification/cost-checks.json').read_text(encoding='utf8'))
    render = json.loads((OUT/'verification/render-checks.json').read_text(encoding='utf8'))
    hardware = json.loads((OUT/'verification/hardware-v14-checks.json').read_text(encoding='utf8'))
    beam = json.loads((OUT/'verification/beam-checks.json').read_text(encoding='utf8'))
    startup = json.loads((OUT/'verification/startup-checks.json').read_text(encoding='utf8'))
    pc_build = json.loads((OUT/'pc-build-info.json').read_text(encoding='utf8'))
    ddr=json.loads((OUT/'verification/ddr-v14-checks.json').read_text(encoding='utf8'))
    trace=json.loads((OUT/'verification/trace-v14-checks.json').read_text(encoding='utf8'))
    assert trace['dll_sha256']==sha(OUT/'lunaria_pc.dll')
    assert trace['atlas_sha256']==sha(OUT/'atlas.argb')
    for check in (parity,memory,pool,cost,render,hardware,startup,beam,ddr,trace):
        assert check['status'] == 'passed'
        for name,digest in check['sources'].items():
            assert sha(ROOT/name) == digest, 'Changed after verification: '+name
    assert memory['elf_sha256'] == sha(DEFAULT_ELF)
    assert startup['elf_sha256'] == sha(DEFAULT_ELF)
    assert cost['dll_sha256'] == sha(OUT/'lunaria_pc.dll')
    for name,digest in beam['dlls'].items():
        assert sha(OUT/name)==digest==pc_build['dlls'][name]
    for name,digest in render['dlls'].items():
        assert sha(OUT/name) == digest == pc_build['dlls'][name]
    assert render['atlas_sha256'] == sha(OUT/'atlas.argb')
    for name,digest in pc_build['sources'].items():
        assert sha(ROOT/name) == digest, 'Changed after PC build: '+name
    for name,digest in parity['dlls'].items():
        assert sha(OUT/name) == digest == pc_build['dlls'][name], 'Stale PC DLL: '+name
    for name,digest in parity['assets'].items():
        assert sha(OUT/name) == digest, 'PC preview used stale artwork: '+name
    preview = json.loads((ROOT/'design/lunaria_preview/preview-checks.json').read_text(encoding='utf8'))
    assert preview['status'] == 'passed' and preview['sourceSha256'] == sha(ROOT/'design/lunaria_preview/lunaria-dream-barrage.html')
    protected = json.loads((ROOT/'output/showcase_protected.json').read_text(encoding='utf8'))
    for name,digest in protected.items():
        assert sha(ROOT/name) == digest, 'Protected baseline changed: '+name
    for name in ('lunaria.elf','lunaria.map','lunaria.disasm','build-info.json'):
        copy(DEFAULT_ELF.parent/name,OUT/name)
    for name in ('game_debug_bridge.py','game_debug_window.py','keyboard_uart.py',
                 'lunaria_debug_bridge.py','lunaria_debug_window.py','lunaria_pc.py'):
        copy(ROOT/'tools'/name,OUT/'tools'/name)
    for name in ('debug_ti.cfg','ftdi_ti.cfg'):
        copy(ROOT/'software/apb_reg_test/openocd'/name,OUT/'software/apb_reg_test/openocd'/name)
    copy(ROOT/'embedded_sw/soc_control/cpu0.yaml',OUT/'embedded_sw/soc_control/cpu0.yaml')
    copy(ROOT/'docs/LUNARIA_GAME.md',OUT/'使用说明.md')
    copy(ROOT/'docs/LUNARIA_DDR_V14.md',OUT/'DDR优化说明.md')
    for label in ('integration','queue','ddr-checks','alpha-legacy-checks','debug-regression'):
        copy(ROOT/f'output/lunaria-v14-{label}.log',OUT/f'verification/v14-{label}.log')
    copy(ROOT/'design/lunaria_preview/lunaria-inspection.html',OUT/'preview.html')
    copy(ROOT/'design/lunaria_preview/preview-checks.json',OUT/'verification/preview-checks.json')
    for version,source in (('v10','showcase_v10_fallback'),('v11','showcase_v11')):
        copy(ROOT/'output'/source/'ti60f225_oob.bit',OUT/'hardware'/version/'ti60f225_oob.bit')
        copy(ROOT/'output'/source/'manifest.json',OUT/'hardware'/version/'original_manifest.json')
    v14 = ROOT/'output/lunaria_v14_hardware'
    assert sha(v14/'outflow/ti60f225_oob.bit') == hardware['bit_sha256']
    assert sha(v14/'outflow/ti60f225_oob.timing.rpt') == hardware['timing_sha256']
    assert sha(v14/'source_manifest.json') == hardware['source_manifest_sha256']
    copy(v14/'outflow/ti60f225_oob.bit',OUT/'hardware/v14/ti60f225_oob.bit')
    copy(v14/'outflow/ti60f225_oob.timing.rpt',OUT/'hardware/v14/timing.rpt')
    copy(v14/'source_manifest.json',OUT/'hardware/v14/source_manifest.json')
    # No automatic device connection. Launching only opens a window.
    launcher = ('@echo off\nsetlocal\ncd /d "%~dp0"\n'
                'set "PYTHONHOME=D:\\Efinity\\python311"\n'
                '"%PYTHONHOME%\\bin\\python.exe" -B tools\\lunaria_debug_window.py '
                '--elf "%~dp0lunaria.elf" --assets "%~dp0assets.json"\n'
                'if errorlevel 1 pause\n')
    (OUT/'start_debug.cmd').write_text(launcher,encoding='ascii')
    (OUT/'start_preview.cmd').write_text(
        '@echo off\nsetlocal\ncd /d "%~dp0"\n'
        'set "PYTHONHOME=D:\\Efinity\\python311"\n'
        '"%PYTHONHOME%\\bin\\python.exe" -B tools\\lunaria_pc.py --folder "%~dp0."\n'
        'if errorlevel 1 pause\n',encoding='ascii')
    sources = []
    for folder in ('software/lunaria','design/lunaria_preview/assets'):
        sources.extend(p for p in (ROOT/folder).rglob('*') if p.is_file() and 'build' not in p.relative_to(ROOT).parts)
    sources.extend(ROOT/name for name in ('sim/test_lunaria.c','scripts/build_lunaria.py',
        'scripts/build_apb_software.py','scripts/prepare_lunaria_assets.py',
        'scripts/run_lunaria_checks.py','scripts/run_lunaria_checks.cmd',
        'scripts/run_lunaria_loader_checks.py','scripts/package_lunaria.py',
        'sim/test_lunaria_pool.c','sim/tb_cpu_ddr_bridge.v',
        'scripts/build_lunaria_pc.cmd','scripts/build_lunaria_pc.py',
        'scripts/run_lunaria_parity_checks.py','scripts/run_lunaria_memory_checks.py',
        'scripts/run_lunaria_cost_checks.py','scripts/prepare_lunaria_trim.py',
        'scripts/prepare_lunaria_hardware.py','scripts/check_lunaria_hardware.py',
        'scripts/run_lunaria_render_checks.py','sim/tb_lunaria_alpha_cache.v',
        'scripts/run_lunaria_beam_checks.py','sim/tb_lunaria_beam.v',
        'scripts/prepare_lunaria_v13_hardware.py','scripts/check_lunaria_v13_hardware.py',
        'scripts/run_lunaria_startup_checks.py','scripts/run_lunaria_startup_checks.cmd',
        'sim/test_lunaria_startup.c','software/apb_reg_test/accel_api.h',
        'software/apb_reg_test/accel_regs.h',
        'rtl/accelerator/alpha_blit_engine.v','rtl/accelerator/graphics_engine.v',
        'rtl/framebuffer/rgb_framebuffer.v','rtl/ti60f225_oob_top.v'))
    sources.extend(ROOT/name for name in ('scripts/prepare_lunaria_v14_hardware.py',
        'scripts/check_lunaria_v14_hardware.py','scripts/run_lunaria_ddr_checks.py',
        'scripts/run_lunaria_trace_checks.py','scripts/check_lunaria_delivery.py',
        'sim/tb_lunaria_overlap.v','sim/tb_lunaria_perf_regs.v',
        'sim/tb_lunaria_trace.v','sim/tb_alpha_blit_engine.v','sim/tb_checkpoint_d.v',
        'scripts/run_d_checks.py','scripts/check_project.py','rtl/control/accel_regs.v',
        'rtl/control/sapphire_control.v','docs/REGISTER_MAP.md','docs/LUNARIA_DDR_V14.md'))
    sources.extend(ROOT/'design/lunaria_preview'/name for name in
                   ('lunaria-dream-barrage.html','inspect-lunaria.cjs','preview-checks.json','README.md'))
    for path in sources:
        copy(path,OUT/'source'/path.relative_to(ROOT))
    stack_top = image.symbol('_sp')
    stack_size = image.symbols['__stack_size'][0]
    assert stack_size == 8192 and stack_top <= RAM_END
    assert not any(name.startswith(('__addsf','__mulsf','__divsf','__floats','__adddf','__muldf','__divdf'))
                   for name in image.symbols), 'Floating-point runtime linked'
    manifest = {
        'name':'LUNARIA 星海梦境','date':'2026-10-31','core_hz':100000000,
        'revision':'v14-overlapped-ddr-20261031',
        'settings':{'minimum_bullets':64,'maximum_bullets':4096,'default_bullets':256,
                    'spin_patterns_optional':True,'resets_current_pattern_on_apply':True},
        'preview':{'entry':'start_preview.cmd','implementation':'same C logic, pager, render commands and 32px art',
                   'phases':8,'maximum_bullets':4096,'compared_frames':parity['compared_frames'],
                   'board_tested':False,'fixed_tick_ms_per_render':16},
        'design_reference':{'entry':'preview.html','scenes':16,'source_sha256':preview['sourceSha256'],
                            'assertions':preview['assertionCount'],'firmware_simulator':False},
        'memory_checks':memory,'pool_checks':pool,'parity_checks':parity,'cost_checks':cost,
        'render_checks':render,'hardware_v14_checks':hardware,'ddr_checks':ddr,'trace_checks':trace,'beam_checks':beam,
        'pc_build':pc_build,
        'loader_checks':loader,'startup_checks':startup,'build_sources':build['sources'],
        'board_tested':False,'stable_60_fps_measured':False,'board_endurance_tested':False,
        'hardware_compile_required':False,'hardware_reconfiguration_for_full_optimization':True,
        'recommended_hardware':'v14','compatible_hardware':['v13','v14'],
        'historical_hardware':['v10','v11','v12','v13'],
        'source_window':[640,300,640,480],
        'display':{'v13':[320,60,1280,960],'v14':[320,60,1280,960]},
        'build_config':{name:image.symbol_u32('g_game_build_config',n)
                        for n,name in enumerate(BUILD_CONFIG_FIELDS)},
        'elf_sha256':sha(OUT/'lunaria.elf'),
        'ocram':{'start':hex(RAM_START),'stack_bytes':stack_size,'stack_top':hex(stack_top),
                 'used_including_stack':stack_top-RAM_START,
                 'bytes_before_debug_reserved':RAM_END-stack_top,
                 'debug_reserved':['0xf900fc00','0xf9010000']},
        'host_checks':report,'asset_transfer_bytes':sum(len(data) for data,_ in assets),
        'hardware_sha256':{v:sha(OUT/'hardware'/v/'ti60f225_oob.bit') for v in ('v10','v11','v12','v13','v14')},
        'protected_baselines_unchanged':protected,
        'manual_acceptance':'使用说明.md / 已验证与待验收',
        'note':'source/ is the new-source review snapshot; rebuild from the full project workspace'}
    (OUT/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
    files = sorted(p for p in OUT.rglob('*') if p.is_file() and p.name != 'SHA256SUMS.txt')
    (OUT/'SHA256SUMS.txt').write_text(''.join(sha(p)+'  '+p.relative_to(OUT).as_posix()+'\n' for p in files),encoding='utf8')
    for path in files: assert path.stat().st_size, str(path)
    print('PASS independent LUNARIA delivery: '+str(OUT))
    print(f'RAM incl. 8 KiB stack: {stack_top-RAM_START} bytes; debug reserve headroom: {RAM_END-stack_top} bytes')
    print('Existing bitstreams and protected packages unchanged; board verification pending')


if __name__ == '__main__': main()
