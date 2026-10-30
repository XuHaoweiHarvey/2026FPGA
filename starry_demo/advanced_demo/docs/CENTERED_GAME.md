# 居中 640×480 游戏性能配置

该配置用于先验证减少每帧像素量能否解决满载吞吐问题。HDMI 时序保持
1920×1080@60 Hz，游戏视口固定为 x=640, y=300, width=640, height=480；外围
保留你提供的整幅海岛背景，启动时复制到两个物理显示缓冲；正常帧仅从封存背景恢复中央
640×480 视口并绘制精灵，外围图像保持静止。飞机、子弹和六帧爆炸继续使用队伍图片。

2026-10-26 修复：上一版 `GAME_FULLSCREEN=0` 同时排除了海岛背景，导致居中版只显示
纯色背景。现在用独立的 `GAME_TEAM_BACKGROUND=1` 保留图片，不再用缩小视口来关闭图片。

## 构建与交付

在 advanced_demo 下运行：

    .\scripts\build_centered_game.cmd D:\Efinity\efinity-riscv-ide-2026.1
    $env:PYTHONHOME = 'D:\Efinity\python311'
    & "$env:PYTHONHOME\bin\python.exe" -B scripts\package_centered_campaign_game.py

ELF 位于 software/interactive_demo/build/game-centered/survival_game.elf，交付目录为
output/campaign_game_centered/。构建使用与全屏版相同的 v7 bit、O2、队友素材、
Alpha 和 Color Key，显式启用 `GAME_TEAM_BACKGROUND=1`，关闭 Flash；满载入口仍固定为
48 架敌机和 64 发敌弹。打包时从 ELF 核对视口、队友图片及海岛像素符号，拒绝旧的纯色版。

software/interactive_demo/build/game/survival_game.elf 是原有 1080p 基线，构建居中版
不会覆盖它。两个 ELF 的图集缩放不同；在同一 bit 上切换 ELF 前，从全屏版切到居中版
或反向切换都要重新配置该 v7 bit，以清除封存素材。

## 首次上板

使用 output/campaign_game_centered/ 中的 bit 和 ELF，先释放其他 JTAG/串口会话，再加载
ELF。由旧纯色居中版/全屏版切换至本修复版时，先重新配置配套的同一个 v7 bit，再加载
本目录 ELF，以清除旧素材封存。无需重编译硬件。修复版要求背景与命令队列能力 `0x00000600`。

双击交付目录的 `start_centered_game_debug.cmd`，窗口会预选同目录的修复版 ELF。点击
“连接 / 读取”再“加载并运行 ELF”，等待初始化完成；不要沿用默认全屏 ELF 或旧备份。

## 60 秒验收

在稳定的满载场景中连续测量 60 秒，期间不做 JTAG 读取。保存窗口导出的完整报告、ELF/bit
SHA-256 和配置宏。目标是平均 FPS 与最低秒窗接近 60、绘制超预算帧为 0、重复旧帧为 0，
且 underflow、missed、reader 和硬件错误不增加。该目录的 manifest.json 明确标记
board_tested=false；主机测试和软件构建不能代替实板结果。

若居中版达到目标而 1080p 未达到，应优先继续减少精灵尺寸、透明边缘和恢复面积，再逐步
扩大视口。若居中版仍受限，先比较命令提交/队列背压与帧末等待，再依据写节流、读停顿
评估批量绘制或短行写事务；不要关闭显示优先写入准入保护换取帧率。
