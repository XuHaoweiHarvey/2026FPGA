# 高级图形与游戏演示

> 2026-10-24 新增 Flash 游戏实现：SPI0、图片/特效图集、最高分和难度存档、维护与只读导出工具。每次仍由电脑 JTAG/IDE 下载运行。详见 [Flash 封装与操作交付](docs/FLASH_DELIVERY.md) 和 [验证记录](docs/FLASH_VALIDATION.md)。下文原游戏报告保留为 Flash 接入前的基线记录。

2026-10-24 已合并常驻调试/弹幕与 Flash 两套改动。默认构建启用 Flash，需要带 SPI0
的硬件和已准备的素材；继续使用原来的常驻调试版本时，构建参数加
`--define GAME_FLASH_ENABLE=0`，使用现有 UART/Alpha/Color Key v6 bit。
两种模式都保留背景初始化、弹幕、调试命令和测量接口；当前全屏版使用 BLIT 恢复背景，
并由 v7 硬件的 8 项 FIFO 缓冲绘图命令，减少每条命令等待引擎完成造成的 CPU 空转。
合并验证的 ELF 保存在 `output/merge_validation_20261024/`。

**全屏海岛战役版已接入**：活动范围扩展到 1920×1080，含标题页、三波敌机、
双阶段 Boss 和胜负结果；硬件字形缓存、16×16 双缓冲背景恢复和满负荷测量入口，
用来验证稳定 60 FPS 目标。
调试窗口默认 ELF `software/interactive_demo/build/game/survival_game.elf` 已构建为
不依赖 Flash 的全屏战役版。旧 v6 bit 不支持全屏背景窗口和绘图命令队列；若板上已配置配套 v7 bit
且素材未变，只加载新 ELF 即可。更换素材时再重新配置同一 bit，以清除封存状态。
新 bit 已完成编译与时序检查。
v7 最终布线的 100 MHz `core_clk` setup slack 为 +2.340 ns；XLR 使用率为 90.22%。
配套文件在 `output/campaign_game/`；上一版 bit/ELF 备份在
`output/fullscreen_validation/before_fullscreen/`。
操作、重建命令及验证结果见 [全屏版说明](docs/FULLSCREEN_GAME.md)。
本次沿用已编译的全屏 bit；更换图集需重新配置以解除封存。
60 FPS 尚待板上完整测量确认；本次没有操作板卡或写 Flash。

居中 640×480 性能对照版已接入：HDMI 仍为 1920×1080@60 Hz，游戏视口固定在
(640,300)，两个显示缓冲的外围背景只在启动时初始化，正常帧只清理/绘制视口。
它使用相同 v7 bit、队友精灵、Alpha/Color Key 和 48 敌机/64 敌弹满载入口，独立输出
到 software/interactive_demo/build/game-centered/，不会覆盖全屏基线。构建和 60 秒验收
步骤见 docs/CENTERED_GAME.md；交付包在 output/campaign_game_centered/。
该包的 board_tested 和 stable_60_fps_measured 保持为 false，等待实板测量。


`advanced_demo` 用于完成赛题高级挑战：硬件 Alpha 混合、不规则精灵图的
Color Key 透明处理，以及由 RISC-V CPU 运行、FPGA 加速绘图的高负载互动游戏。
`basic_demo` 仍是单独保留的 M2 基线工程。

键盘 WASD 或方向键移动，空格或 Ctrl 开火，P 暂停。玩家和敌人使用 Color Key，
子弹和爆炸使用 Alpha 混合。常规战役为三波敌机后挑战双阶段 Boss；另有固定满负载场景
持续补足 48 架敌机、64 发敌弹，供连续 60 秒性能测量。

全屏常驻版游戏 ELF 通过普通 `OP_BLIT` 恢复背景、Color Key 绘制飞机、Alpha 绘制
子弹/光晕/爆炸。保留的 M2 回归继续测试普通复制。高级游戏中没有 CPU/FPGA 对照模式。

## 当前构建和上板状态

已在重新生成的 Sapphire SoC/BSP 中启用 UART0。控制模块已将
`system_uart_0_io_rxd` 接到板卡 UART 接收端，将 `system_uart_0_io_txd` 接到板卡
UART 发送端。串口配置为 115200 波特率、8 数据位、无校验、1 停止位。TI60F225I3-V4
引脚约束为 RX：R4/GPIOL_02，TX：R14/GPIOR_28，均为 3.3 V LVCMOS。
`scripts/check_project.py` 已通过，并确认生成的 SoC/BSP 端口连接正确。

Efinity 2026.1.132 已完成包含 8 项绘图命令队列的 v7 全屏版完整编译，当前配套文件为：

- FPGA 配置文件：`outflow/ti60f225_oob.bit`
- 游戏程序：`software/interactive_demo/build/game/survival_game.elf`
- UART 诊断程序：`software/interactive_demo/build/keyboard-test/uart_keyboard_test.elf`

这些文件位于 Git 忽略的构建目录中，普通 Git 提交和推送不会包含它们。烧录时需要
使用包含全屏背景与绘图命令队列能力的 advanced v7 bit 与新 ELF，不能混用旧 bit。
2026-10-24 用户已反馈上一版小区域素材游戏已完成测试；本轮全屏背景仍需上板验证。
板卡 UART 对应的 COM、按键实际接收、
自测结果及持续帧率仍需保存板端验证记录，不能用电脑端发送成功代替。详见
[构建报告](docs/GAME_BUILD_REPORT.md)、[键盘串口说明](docs/KEYBOARD_UART_INPUT.md)
和[上板验证清单](docs/BOARD_VALIDATION_CHECKLIST.md)。

新全屏版首次运行按[全屏版说明](docs/FULLSCREEN_GAME.md)先配置新 bit，
解除旧素材封存，再加载新 ELF。

上板前的配套文件整理、诊断与游戏专用调试配置和中文烧录步骤见
[上板操作说明](docs/BOARD_READY_GUIDE.md)。封存包默认输出到 Git 忽略的
`output/board_ready/`；生成命令和本机工具核对结果也记录在该说明及包内报告中。

## 常驻调试与弹幕扩展

当前源码新增了桌面调试窗口和常驻游戏命令：首次加载新 ELF 后，可直接重开、暂停、
调参、验证 FILL/Color Key/Alpha、切换固定满负载场景，并测量独立 60 秒区间。
双击 `start_game_debug.cmd`，具体步骤见[常驻调试说明](docs/RESIDENT_GAME_DEBUG.md)。
旧封存包不会自动更新，本次请从源码目录使用新 ELF 和窗口。
本版作为阶段性开发版本保存，尚未完成最终性能验收。上传范围、排除文件和可复制的
提交说明见[上传说明](docs/UPLOAD_GUIDE.md)。

## 构建与运行

在本机 PowerShell 中进入 `advanced_demo` 目录后，可用 Efinity 自带的 Python
运行工程脚本。`PYTHONHOME` 只影响当前 PowerShell 窗口：

```powershell
$env:PYTHONHOME = 'D:\Efinity\python311'
$efxPython = 'D:\Efinity\python311\bin\python.exe'
& $efxPython scripts\check_project.py
& $efxPython scripts\build_apb_software.py --program game --ide-root 'D:/Efinity/efinity-riscv-ide-2026.1' --define GAME_FLASH_ENABLE=0
& $efxPython scripts\build_apb_software.py --program keyboard-test --ide-root 'D:/Efinity/efinity-riscv-ide-2026.1'
& $efxPython tools\keyboard_uart.py --list
& $efxPython tools\keyboard_uart.py COMx
```

其他装有可用 Python 3 启动器的电脑，可以用 `py -3` 替代 `$efxPython`。
`--ide-root` 需改为本机实际安装目录；需要 Flash 版时去掉 `GAME_FLASH_ENABLE=0`，
并先按 Flash 交付说明准备兼容的硬件和素材。将
`COMx` 换成接上板卡后实际显示的串口号；Windows 可能在不同电脑或 USB 插口上分配
不同编号。启动键盘发送程序前，先关闭占用该 COM 口的串口终端。键盘测试和游戏
运行顺序见串口说明。

初次验证时，在 Efinity Programmer 中通过 JTAG 临时配置 bit，不要写入 SPI Flash。
再通过 Efinity RISC-V IDE 加载与之匹配的诊断 ELF 或游戏 ELF。建议先运行诊断程序
确认串口收到按键，再运行游戏。不要把这些 ELF 与早期仅含 Alpha 演示的 v6 bit
混用。

## 验证

可在 PowerShell 中运行以下检查：

```powershell
$env:PYTHONHOME = 'D:\Efinity\python311'
$efxPython = 'D:\Efinity\python311\bin\python.exe'
& $efxPython scripts\check_project.py
& $efxPython scripts\run_game_logic_checks.py
& $efxPython scripts\run_uart_keyboard_checks.py
& $efxPython scripts\run_alpha_checks.py
powershell -ExecutionPolicy Bypass -File scripts\run_color_key_checks.ps1
```

游戏逻辑和 UART 协议的 C 回归需要本机 C 编译器。主机测试不能验证板卡串口接线、
显示时序、实际图像或帧率。上板时请记录显示帧率、最大精灵数量、`error`、
`reader_error`、underflow、missed 计数变化以及 UART 接收计数。只有在目标板上才能
确认键盘操作和持续 60 FPS 的表现。

工程中保留的 M2 对照代码和回归脚本用于基线兼容性检查，不属于高级游戏模式，也
没有链接进游戏 ELF。
