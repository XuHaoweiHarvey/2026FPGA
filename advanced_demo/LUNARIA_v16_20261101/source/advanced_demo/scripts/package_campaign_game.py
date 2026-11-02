"""Create a matched, hash-verified full-screen campaign bit/ELF packet."""
from pathlib import Path
import hashlib
import json
import shutil
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / "tools"))
from game_debug_bridge import ElfImage, RUNTIME_FIELDS

bit = root / "outflow/ti60f225_oob.bit"
elf = root / "software/interactive_demo/build/game/survival_game.elf"
checks = root / "output/campaign_validation"
assert bit.is_file() and elf.is_file()
image = ElfImage(elf)
assert image.symbol("g_game_required_caps", 4)
assert image.symbol("g_game_runtime", len(RUNTIME_FIELDS) * 4)
assert "g_flash_result" not in image.symbols
interactive = (checks / "interactive_checks.log").read_text(encoding="utf8")
alpha = (checks / "alpha_checks.log").read_text(encoding="utf8")
matrix = (checks / "build_matrix.txt").read_text(encoding="utf8")
assert "Ran 22 tests" in interactive and "OK" in interactive
assert "PASS FULLSCREEN BLIT:" in alpha
assert len([line for line in matrix.splitlines() if line.startswith("PASS build")]) == 6

target = root / "output/campaign_game"
target.mkdir(exist_ok=True)
files = []
for source in (bit, elf):
    output = target / source.name
    shutil.copy2(source, output)
    files.append({"file": output.name, "bytes": output.stat().st_size,
                  "sha256": hashlib.sha256(output.read_bytes()).hexdigest()})
manifest = {
    "version": "2026-10-25 fullscreen campaign game with queued rendering",
    "hardware_version": "0x00070000",
    "required_hardware_capabilities": "0x00000600",
    "game_config": {"GAME_FULLSCREEN": 1, "GAME_TEAM_SPRITES": 1,
                     "GAME_FLASH_ENABLE": 0, "optimization": "O2"},
    "campaign": {"waves": 3, "wave_duration_ms": 22000, "boss_max_hp": 90,
                 "stress_enemies": 48, "stress_enemy_bullets": 64},
    "board_tested": False,
    "verification": {"interactive_tests": 22, "full_screen_background_dma": True,
                      "burst_aware_background_restore": True,
                      "per_frame_health_and_keyboard_polling": True,
                      "render_path_diagnostics": True,
                      "queued_graphics_commands": True,
                      "all_six_build_configurations_fit_ocram": True,
                      "stable_60_fps_measured": False},
    "files": files,
}
(target / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf8")
(target / "SHA256SUMS.txt").write_text(
    "".join(f'{item["sha256"]}  {item["file"]}\n' for item in files), encoding="ascii")
(target / "使用说明.txt").write_text(
    "全屏海岛战役版：配套 FPGA bit + 游戏 ELF\n\n"
    "1. 停止键盘串口发送，关闭调试窗口和 Efinity IDE Debug，释放 JTAG。\n"
    "2. 若板上已经是本目录配套全屏 bit 且素材未变，不必重配；旧 v6 bit 或换过素材时，\n"
    "   才在 Efinity Programmer 配置本目录 ti60f225_oob.bit。\n"
    "3. 关闭 Programmer，启动 advanced_demo/start_game_debug.cmd。\n"
    "4. 在调试窗口选择本目录 survival_game.elf，点击“连接 / 读取”再“加载并运行 ELF”。\n"
    "   初始化素材和图集需要时间，等到标题页出现。无需写 Flash。\n"
    "5. 选择板卡 COM 口并开始发送键盘。标题页按空格开始；方向键/WASD 移动，\n"
    "   空格/Ctrl 射击，P 暂停。三波后进入 Boss，击败后可重开。\n"
    "6. 测 60 FPS：点“满负载场景”，等约 3 秒，再点“连续测量 60 秒”。\n"
    "   等窗口显示结果；测量期间不要读取板卡、调参、重开或连接另一个调试器。\n"
    "   重点检查平均/最低秒窗 FPS、绘制命令提交/等待耗时、DDR 写节流/读停顿、\n"
    "   最大换帧间隔、绘制超预算数、重复旧帧数和硬件错误。\n"
    "   尚未在板卡上测量，稳定 60 FPS 目前仍是目标而非已验证结果。\n\n"
    "修改源码后运行 scripts/build_team_game.cmd。不要上传 output/ 生成物到 Git。\n"
    "完整说明见 docs/FULLSCREEN_GAME.md 和 docs/RESIDENT_GAME_DEBUG.md。\n",
    encoding="utf8")
print(json.dumps(manifest, ensure_ascii=False, indent=2))
