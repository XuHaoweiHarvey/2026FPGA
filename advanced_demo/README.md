# 高级图形与游戏演示

`advanced_demo` 用于完成赛题高级挑战：硬件 Alpha 混合、不规则精灵图的
Color Key 透明处理，以及由 RISC-V CPU 运行、FPGA 加速绘图的高负载互动游戏。
`basic_demo` 仍是单独保留的 M2 基线工程。

当前阶段实现键盘控制的弹幕生存游戏：WASD 或方向键移动，空格或 Ctrl 开火，P
暂停。玩家和敌人图片使用 Color Key 去除背景，光晕、子弹和受击效果使用 Alpha
混合。敌人波次逐渐增加，敌机上限为 48，另有玩家子弹、敌方弹幕和效果。画面显示游戏帧率、当前
精灵数量和运行期间观察到的最大精灵数量，用于上板测量性能。

游戏 ELF 发送 Color Key 和 Alpha 命令，不发送普通 `OP_BLIT` 命令。RTL 仍保留
BLIT 支持，因为 Color Key 使用共享的源图传输通路，且加速器配置需要该支持；
保留的 M2 回归也会测试普通复制。高级游戏中没有 CPU/FPGA 对照模式。

## 当前构建和上板状态

已在重新生成的 Sapphire SoC/BSP 中启用 UART0。控制模块已将
`system_uart_0_io_rxd` 接到板卡 UART 接收端，将 `system_uart_0_io_txd` 接到板卡
UART 发送端。串口配置为 115200 波特率、8 数据位、无校验、1 停止位。TI60F225I3-V4
引脚约束为 RX：R4/GPIOL_02，TX：R14/GPIOR_28，均为 3.3 V LVCMOS。
`scripts/check_project.py` 已通过，并确认生成的 SoC/BSP 端口连接正确。

Efinity 2026.1.132 于 2026-10-23 完成完整编译，生成以下文件：

- FPGA 配置文件：`outflow/ti60f225_oob.bit`
- 游戏程序：`software/interactive_demo/build/game/survival_game.elf`
- UART 诊断程序：`software/interactive_demo/build/keyboard-test/uart_keyboard_test.elf`

这些文件位于 Git 忽略的构建目录中，普通 Git 提交和推送不会包含它们。烧录时需要
使用启用 UART/Alpha/Color Key 的 advanced v6 bit 与兼容 ELF；本次软件改动只需重建、
加载 ELF，已有兼容 bit 无需重编译。2026-10-24 用户已反馈通过调试窗口加载 ELF 后
游戏正常显示，修复背景跳变后显示正常。板卡 UART 对应的 COM、按键实际接收、
自测结果及持续帧率仍需保存板端验证记录，不能用电脑端发送成功代替。详见
[构建报告](docs/GAME_BUILD_REPORT.md)、[键盘串口说明](docs/KEYBOARD_UART_INPUT.md)
和[上板验证清单](docs/BOARD_VALIDATION_CHECKLIST.md)。

上板前的配套文件整理、诊断与游戏专用调试配置和中文烧录步骤见
[上板操作说明](docs/BOARD_READY_GUIDE.md)。封存包默认输出到 Git 忽略的
`output/board_ready/`；生成命令和本机工具核对结果也记录在该说明及包内报告中。

## 常驻调试与弹幕扩展

当前源码新增了桌面调试窗口和常驻游戏命令：首次加载新 ELF 后，可直接重开、暂停、
调参、验证 FILL/Color Key/Alpha，以及测量独立 60 秒区间；GAME OVER 默认 3 秒自动重开。
玩法增加敌方瞄准弹/扇形弹和波次，保留已有底层与基础工程。
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
& $efxPython scripts\build_apb_software.py --program game
& $efxPython scripts\build_apb_software.py --program keyboard-test
& $efxPython tools\keyboard_uart.py --list
& $efxPython tools\keyboard_uart.py COMx
```

其他装有可用 Python 3 启动器的电脑，可以用 `py -3` 替代 `$efxPython`。将
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
