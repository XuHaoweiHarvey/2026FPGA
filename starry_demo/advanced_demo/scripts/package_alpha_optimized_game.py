"""Verify and package isolated v9/v10 bit/ELF pairs with timing and SHA256 evidence."""
from pathlib import Path
import argparse
import configparser
import hashlib
import json
import re
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'tools'))
from game_debug_bridge import ElfImage, BUILD_CONFIG_FIELDS

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--variant', choices=('stream','cache','both'), default='both')
args = parser.parse_args()
def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

protected = json.loads((ROOT/'output/window640_stress_opt_protected_before.json').read_text(encoding='utf-8-sig'))
for item in protected:
    assert sha(ROOT/item['Path']).lower() == item['SHA256'].lower(), item['Path']
elf = ROOT/'software/interactive_demo/build/game-window640-stress-opt/survival_game.elf'
image = ElfImage(elf)
assert image.symbol_u32('g_game_alpha_hardware_compatible') == 0x3000
assert image.symbol_u32('g_game_window_hud_cache') == 1
assert image.symbol_u32('g_game_required_caps') == 0xE00
assert image.symbol_u32('g_game_stress_limits',3) == 512
assert image.symbols['_sp'][0] <= 0xF900FC00
config = {key: image.symbol_u32('g_game_build_config', i) for i,key in enumerate(BUILD_CONFIG_FIELDS)}
assert config['view_width']==640 and config['view_height']==480 and config['team_sprites']==1
assert config['fullscreen']==0 and config['flash_enabled']==0
for variant in (('stream','cache') if args.variant=='both' else (args.variant,)):
    number = 9 if variant=='stream' else 10
    hardware = ROOT/f'output/window640_alpha_{variant}_hardware'
    out = hardware/'outflow'
    state = configparser.ConfigParser()
    state.read(out/'ti60f225_oob.proj_state.ini')
    assert state.get('state','last_run_state')=='pass' and state.get('state','last_run_flow')=='bitstream'
    snapshot = json.loads((hardware/'source_manifest.json').read_text(encoding='utf8'))
    assert int(snapshot['hardware_version'],16)==number*0x10000
    for name,digest in snapshot['sources'].items():
        assert sha(hardware/name)==digest, 'Modified hardware snapshot: '+name
        if name!='rtl/ti60f225_oob_top.v':
            assert sha(ROOT/name)==digest, 'Sources changed since compile: '+name
    expected_top=(ROOT/'rtl/ti60f225_oob_top.v').read_text(encoding='utf8')
    expected_top=expected_top.replace('parameter DISPLAY_WINDOW_ENABLE = 0,','parameter DISPLAY_WINDOW_ENABLE = 1,')
    expected_top=expected_top.replace('parameter ALPHA_STREAM_ENABLE = 0,','parameter ALPHA_STREAM_ENABLE = 1,')
    expected_top=expected_top.replace('parameter [31:0] HARDWARE_VERSION = 0,',
                                    f"parameter [31:0] HARDWARE_VERSION = 32'h{number*0x10000:08x},")
    if variant=='cache':
        expected_top=expected_top.replace('parameter ALPHA_SPRITE_CACHE_ENABLE = 0,','parameter ALPHA_SPRITE_CACHE_ENABLE = 1,')
    assert expected_top==(hardware/'rtl/ti60f225_oob_top.v').read_text(encoding='utf8')
    bit=out/'ti60f225_oob.bit'
    assert bit.stat().st_mtime>max((hardware/name).stat().st_mtime for name in snapshot['sources'])
    timing=(out/'ti60f225_oob.timing.rpt').read_text(encoding='utf8',errors='replace')
    relation=timing.split('Setup (Max) Clock Relationship',1)[1].split('---------- Clock Relationship Summary (end)',1)[0]
    rows=re.findall(r'^(\S+)\s+(\S+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+\([RF]-[RF]\)',relation,re.M)
    assert rows and all(float(row[3])>=0 for row in rows), 'Final setup/hold violation'
    core=float(next(row[3] for row in rows if row[:2]==('core_clk','core_clk')))
    resources=(out/'ti60f225_oob.place.rpt').read_text(encoding='utf8')
    xlr=re.search(r'^XLRs: (\d+) / (\d+) \(([\d.]+)%\)',resources,re.M)
    ram=re.search(r'^Memory Blocks: (\d+) / (\d+) \(([\d.]+)%\)',resources,re.M)
    dsp=re.search(r'^DSP Blocks: (\d+) / (\d+) \(([\d.]+)%\)',resources,re.M)
    target=ROOT/f'output/window640_alpha_v{number}'
    target.mkdir(parents=True,exist_ok=True)
    files=[]
    for source in (bit,elf,hardware/'source_manifest.json',out/'ti60f225_oob.timing.rpt',out/'ti60f225_oob.place.rpt'):
        dest=target/source.name
        shutil.copy2(source,dest)
        files.append({'file':dest.name,'bytes':dest.stat().st_size,'sha256':sha(dest)})
    (target/'start_debug.cmd').write_text('@echo off\ncall "%~dp0..\\..\\start_game_debug.cmd" --elf "%~dp0survival_game.elf"\n',encoding='ascii')
    manifest={'hardware_version':snapshot['hardware_version'],'variant':variant,'board_tested':False,
              'capabilities':f'0x{0x1FFB if variant=="stream" else 0x3FFB:08x}',
              'game_config':config,'window_hud_shared_snapshot_ms':250,
              'source_cache_bytes':1024 if variant=='cache' else 0,
              'resources':{'xlr':int(xlr[1]),'xlr_percent':float(xlr[3]),'ram_blocks':int(ram[1]),'dsp_blocks':int(dsp[1])},
              'timing':{'final_core_setup_slack_ns':core,'minimum_setup_or_hold_slack_ns':min(float(row[3]) for row in rows)},
              'files':files,'protected_artifacts_unchanged':protected}
    (target/'manifest.json').write_text(json.dumps(manifest,indent=2,ensure_ascii=False)+'\n',encoding='utf8')
    (target/'SHA256SUMS.txt').write_text(''.join(f'{f["sha256"]}  {f["file"]}\n' for f in files),encoding='ascii')
    (target/'使用说明.txt').write_text(
        f'v{number} 中央 640x480 压力优化版（尚未实板验收）\n\n'
        '1. 关闭 IDE Debug、旧游戏调试窗口，释放 JTAG。\n'
        '2. 用 Efinity Programmer 通过 JTAG 配置本目录 ti60f225_oob.bit。\n'
        '3. 双击本目录 start_debug.cmd，连接后加载并运行 ELF。\n'
        '4. 先确认 SPR 数字清晰，再应用 48 架敌机 / 470 发敌弹，Alpha 225。\n'
        '5. 等待 3-5 秒，连续测量 60 秒并导出日志，测量期间不要另行读取板卡。\n'
        '6. 再测 480 和 512，比较最慢绘制、重复帧、最大换帧间隔和错误增量。\n\n'
        f'本版启用 Alpha 连续供数'+('和 1 KiB 敌弹源图缓存。\n' if variant=='cache' else '。\n')+
        'HDMI 仍为 1920x1080@60 Hz，中央游戏区 640x480，素材与数量补充规则保留。\n'
        '两个物理缓冲区使用同一份 250 ms HUD 统计快照。\n'
        '旧 v7/v8 bit 和旧满载 ELF 保留；切回 v8 使用原中央窗口 bit。\n'
        '新 ELF 支持 v8/v9/v10；旧窗口 ELF 不支持 v9/v10。\n'
        '工程目录结构需要保留，启动器依赖 advanced_demo 根目录工具。\n'
        '仿真周期收益不能替代整帧实板测量。本轮没有连接板卡或写 Flash。\n',encoding='utf8')
    print(json.dumps({'package':str(target),'version':number,'resources':manifest['resources'],'timing':manifest['timing']},ensure_ascii=False))
