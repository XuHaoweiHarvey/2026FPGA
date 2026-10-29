"""Package only the isolated v8 window bitstream and its dedicated artwork ELF."""
from pathlib import Path
import configparser
import hashlib
import json
import re
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from game_debug_bridge import ElfImage, BUILD_CONFIG_FIELDS, RUNTIME_FIELDS

hardware = ROOT / "output/window640_hardware"
outflow = hardware / "outflow"
bit = outflow / "ti60f225_oob.bit"
elf = ROOT / "software/interactive_demo/build/game-window640/survival_game.elf"
target = ROOT / "output/campaign_game_window640"
def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

state = configparser.ConfigParser()
state.read(outflow / "ti60f225_oob.proj_state.ini")
if (not bit.is_file() or not elf.is_file() or
        state.get("state", "last_run_state", fallback="") != "pass" or
        state.get("state", "last_run_flow", fallback="") != "bitstream"):
    raise SystemExit("Build the isolated hardware and scripts/build_window_game.cmd first")
source_manifest = json.loads((hardware / "source_manifest.json").read_text(encoding="utf8"))
for name in ("ti60f225_oob.xml", "ti60f225_oob.peri.xml", "ti60f225_oob.sdc",
             "software/flash/jtag_wait.hex"):
    # Efinity rewrites the project XML without its final newline.
    if (ROOT / name).read_text(encoding="utf8").strip() != (hardware / name).read_text(encoding="utf8").strip():
        raise SystemExit("Staged project configuration differs: " + name)
for name, digest in source_manifest["sources"].items():
    if sha(ROOT / name) != digest:
        raise SystemExit("Hardware sources changed after snapshot: " + name)
    if name != "rtl/ti60f225_oob_top.v" and sha(hardware / name) != digest:
        raise SystemExit("Staged hardware source differs: " + name)
original_top = (ROOT / "rtl/ti60f225_oob_top.v").read_text(encoding="utf8")
expected_top = original_top.replace("parameter DISPLAY_WINDOW_ENABLE = 0,",
                                    "parameter DISPLAY_WINDOW_ENABLE = 1,")
if (hardware / "rtl/ti60f225_oob_top.v").read_text(encoding="utf8") != expected_top:
    raise SystemExit("Staged hardware is not the dedicated window configuration")
if bit.stat().st_mtime < (hardware / "rtl/ti60f225_oob_top.v").stat().st_mtime:
    raise SystemExit("Bitstream predates the hardware snapshot")

timing_path = outflow / "ti60f225_oob.timing.rpt"
timing_text = timing_path.read_text(encoding="utf8", errors="replace")
relationship = timing_text.split("Setup (Max) Clock Relationship", 1)[1].split(
    "---------- Clock Relationship Summary (end)", 1)[0]
relationships = re.findall(r"^(\S+)\s+(\S+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+\([RF]-[RF]\)",
                           relationship, re.M)
if not relationships or any(float(row[3]) < 0 for row in relationships):
    raise SystemExit("Final timing has a setup/hold violation or is unreadable")
core_slack = next(float(row[3]) for row in relationships if row[:2] == ("core_clk", "core_clk"))

image = ElfImage(elf)
config = {key: image.symbol_u32("g_game_build_config", i)
          for i, key in enumerate(BUILD_CONFIG_FIELDS)}
expected = {"magic": 0x47424331, "version": 1, "fullscreen": 0,
            "view_x": 640, "view_y": 300, "view_width": 640, "view_height": 480,
            "pixel_scale": 1, "flash_enabled": 0, "team_sprites": 1,
            "path_diagnostics": 1, "submit_timing": 0, "require_queue": 1,
            "enemy_limit": 48, "enemy_bullet_limit": 64,
            "output_width": 1920, "output_height": 1080}
if config != expected or image.symbol_u32("g_game_required_caps") != 0xE00:
    raise SystemExit("ELF is not the centered artwork/window configuration")
for name in ("game_background_palette", "game_background_pixels", "team_player_pixels",
             "team_enemy_pixels", "team_player_bullet_pixels", "team_enemy_bullet_pixels",
             "initialize_centered_island_background"):
    image.symbol(name, 4)
image.symbol("g_game_runtime", len(RUNTIME_FIELDS)*4)
image.symbol("g_game_measurement_complete", 4)
if "g_flash_result" in image.symbols:
    raise SystemExit("Window package must have Flash disabled")

target.mkdir(parents=True, exist_ok=True)
files = []
for source in (bit, elf, timing_path, hardware / "source_manifest.json"):
    output = target / source.name
    shutil.copy2(source, output)
    files.append({"file": output.name, "bytes": output.stat().st_size, "sha256": sha(output)})
manifest = {
    "version": "2026-10-28 independent v8 central window",
    "hardware_version": "0x00080000", "capabilities": "0x00000FFB",
    "required_hardware_capabilities": "0x00000E00",
    "display": {"output": "1920x1080@60Hz", "window": [640, 300, 640, 480],
                "outside": "hardware black; no steady-state display DDR reads",
                "framebuffer_stride": 7680, "display_read_beats_per_frame": 76800,
                "display_read_bytes_per_second_at_60Hz": 73728000},
    "game_config": config,
    "assets": "supplied island, aircraft, bullets and six-frame explosion; center crop retained",
    "timing": {"final_core_setup_slack_ns": core_slack,
               "minimum_reported_setup_or_hold_slack_ns": min(float(row[3]) for row in relationships)},
    "board_tested": False, "stable_60_fps_measured": False,
    "files": files,
}
(target / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+"\n", encoding="utf8")
(target / "SHA256SUMS.txt").write_text(
    "".join(f'{item["sha256"]}  {item["file"]}\n' for item in files), encoding="ascii")
(target / "start_window_game_debug.cmd").write_text(
    '@echo off\ncall "%~dp0..\\..\\start_game_debug.cmd" --elf "%~dp0survival_game.elf"\n',
    encoding="ascii")
(target / "使用说明.txt").write_text(
    "v8 中央 640×480：专用 bit + ELF 配套包\n\n"
    "HDMI 仍为 1920×1080@60 Hz。仅中央 (640,300)-(1280,780) 显示游戏，外围硬件输出黑色。\n"
    "保留海岛、飞机、子弹和六帧爆炸素材。中央海岛取景与旧居中版本一致。\n"
    "正常显示只从 DDR 读取中央区域；上电 TPG 仍有一次原有全帧初始化。\n"
    "编译和时序已通过；尚未上板，满载 60 FPS 需要实测。\n\n"
    "1. 关闭串口键盘和调试窗口，释放 JTAG。\n"
    "2. 用 Efinity Programmer 通过 JTAG 配置本目录 ti60f225_oob.bit。\n"
    "3. 双击本目录 start_window_game_debug.cmd，连接后加载并运行 ELF。\n"
    "4. 等待素材加载和画面稳定，选择满负载场景（48 敌机、64 敌弹），\n"
    "   应用无敌，等待约 3 秒，再连续测量 60 秒；测量时不要另行读取板卡。\n"
    "5. 保存完整报告，检查平均/最低秒窗、重复帧、超预算帧与新增硬件错误。\n\n"
    "回到全屏：重新配置原 advanced_demo/outflow/ti60f225_oob.bit（v7），\n"
    "再用原 start_game_debug.cmd 加载原全屏 ELF。旧 bit/ELF 未覆盖。\n"
    "此包启动命令依赖工程根目录的工具；供队友使用时请保留 advanced_demo 工程目录结构。\n",
    encoding="utf8")
print(json.dumps(manifest, ensure_ascii=False, indent=2))
