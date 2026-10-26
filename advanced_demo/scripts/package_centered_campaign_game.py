"""Package the centered 640x480 campaign ELF with the matching v7 bitstream."""
from pathlib import Path
import hashlib
import json
import shutil
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / "tools"))
from game_debug_bridge import ElfImage, RUNTIME_FIELDS, BUILD_CONFIG_FIELDS

bit = root / "outflow/ti60f225_oob.bit"
elf = root / "software/interactive_demo/build/game-centered/survival_game.elf"
if not bit.is_file() or not elf.is_file():
    raise SystemExit("请先运行 scripts\\build_centered_game.cmd，且确认配套 v7 bit 在 outflow\\")
image = ElfImage(elf)
image.symbol("g_game_required_caps", 4)
image.symbol("g_game_runtime", len(RUNTIME_FIELDS) * 4)
image.symbol("g_game_build_config", len(BUILD_CONFIG_FIELDS) * 4)
image.symbol("g_game_measurement_complete", 4)
config = {name: image.symbol_u32("g_game_build_config", i)
          for i, name in enumerate(BUILD_CONFIG_FIELDS)}
expected = {"magic": 0x47424331, "version": 1, "fullscreen": 0,
            "view_x": 640, "view_y": 300, "view_width": 640, "view_height": 480,
            "pixel_scale": 1, "flash_enabled": 0, "team_sprites": 1,
            "path_diagnostics": 1, "submit_timing": 0, "require_queue": 1,
            "enemy_limit": 48, "enemy_bullet_limit": 64,
            "output_width": 1920, "output_height": 1080}
if config != expected or image.symbol_u32("g_game_required_caps") != 0x600:
    raise SystemExit("ELF 不是保留海岛背景的居中 640×480 命令队列版本")
for name in ("game_background_palette", "game_background_pixels", "team_player_pixels",
             "team_enemy_pixels", "team_player_bullet_pixels", "team_enemy_bullet_pixels"):
    image.symbol(name, 4)
image.symbol("initialize_centered_island_background", 4)
if "g_flash_result" in image.symbols:
    raise SystemExit("中心窗口交付包必须关闭 Flash")

target = root / "output/campaign_game_centered"
target.mkdir(parents=True, exist_ok=True)
files = []
for source in (bit, elf):
    output = target / source.name
    shutil.copy2(source, output)
    files.append({"file": output.name, "bytes": output.stat().st_size,
                  "sha256": hashlib.sha256(output.read_bytes()).hexdigest()})
manifest = {
    "version": "2026-10-26 centered 640x480 campaign game with supplied island artwork",
    "hardware_version": "0x00070000",
    "required_hardware_capabilities": "0x00000600",
    "display": {"output": "1920x1080@60Hz", "game_viewport": {"x": 640, "y": 300,
        "width": 640, "height": 480}, "outside_viewport_initialized_once_per_buffer": True},
    "game_config": {"GAME_FULLSCREEN": 0, "GAME_TEAM_SPRITES": 1, "GAME_TEAM_BACKGROUND": 1,
                     "GAME_FLASH_ENABLE": 0, "optimization": "O2"},
    "campaign": {"waves": 3, "wave_duration_ms": 22000, "boss_max_hp": 90,
                 "stress_enemies": 48, "stress_enemy_bullets": 64,
                 "alpha": True, "color_key": True},
    "board_tested": False,
    "stable_60_fps_measured": False,
    "verification": {
        "same_v7_bit_as_fullscreen": True,
        "two_physical_buffers_initialized": True,
        "supplied_island_and_sprite_assets_present": True,
        "per_frame_clear_limited_to_viewport": True,
        "display_priority_write_admission_preserved": True,
        "awaiting_board_60_second_measurement": True,
    },
    "files": files,
}
(target / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf8")
(target / "SHA256SUMS.txt").write_text(
    "".join(f'{item["sha256"]}  {item["file"]}\n' for item in files), encoding="ascii")
(target / "start_centered_game_debug.cmd").write_text(
    '@echo off\ncall "%~dp0..\\..\\start_game_debug.cmd" --elf "%~dp0survival_game.elf"\n',
    encoding="ascii")
(target / "使用说明.txt").write_text(
    "居中 640×480 满载版：配套 FPGA bit + 游戏 ELF\n\n"
    "输出仍为 1920×1080@60 Hz，游戏绘制区域为中央 (640,300)-(1280,780)。\n"
    "保留你提供的整幅海岛背景和飞机、子弹、六帧爆炸图片。\n"
    "海岛背景在启动时复制到两个显示缓冲，游戏帧只恢复和绘制中央区域。\n\n"
    "1. 停止键盘串口、调试窗口和 Efinity Debug，释放 JTAG。\n"
    "2. 从旧居中版/全屏版切换到本修复版时，先重新配置本目录同一个 v7 bit，\n"
    "   清除旧素材封存，再加载本目录的 ELF；本轮无需重新综合硬件。\n"
    "3. 双击本目录 start_centered_game_debug.cmd，已预选本目录 survival_game.elf；\n"
    "   点击“连接 / 读取”再“加载并运行 ELF”，等待素材初始化和校验完成。\n"
    "4. 点击“满负载场景”，等待约 3 秒，应用无敌后点击“连续测量 60 秒”。\n"
    "   测量期间不要读取板卡或改变参数。保存完整日志、ELF/bit 哈希和配置。\n"
    "5. 记录平均 FPS、最低秒窗、超预算帧、重复旧帧、underflow/missed、硬件错误，\n"
    "   以及写节流/读停顿和命令提交/帧末等待字段。当前包尚无实板 60 秒结果，\n"
    "   不能把主机检查或时序报告当成稳定 60 FPS 证明。\n\n"
    "构建：scripts\\build_centered_game.cmd；打包：python -B scripts\\package_centered_campaign_game.py。\n"
    "同一 bit 下切换全屏/居中 ELF 时，GAME_PIXEL_SCALE 和封存图集不同，必须重新配置 bit。\n",
    encoding="utf8")
print(json.dumps(manifest, ensure_ascii=False, indent=2))
