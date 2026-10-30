# 高级游戏上板验证清单

## 上板前的构建状态

UART 键盘游戏 v7 队列版已完成编译，可以开始实体板验证；实板稳定帧率仍待测：

- Efinity 2026.1.132 于 2026-10-25 完成 v7 完整编译与布线，生成
  `outflow/ti60f225_oob.bit`；100 MHz `core_clk` setup slack 为 +2.340 ns。
- 游戏 ELF：`software/interactive_demo/build/game/survival_game.elf`（O2，全屏战役版）。
- UART 诊断 ELF：`software/interactive_demo/build/keyboard-test/uart_keyboard_test.elf`。
- `scripts/check_project.py` 检查生成的 UART0 和 V4 引脚连接通过。
- XLR 使用 54,856/60,800（90.22%）；最终满负载帧率仍需在板卡上测量。

bit 和 ELF 位于 Git 忽略的构建目录，Git 上传不会带上它们。需要把这三个文件单独
交给上板的人，或在上板电脑上重新构建。使用时请确保 bit 和所加载的 ELF 来自同一
源码构建。编译详情见[游戏构建报告](GAME_BUILD_REPORT.md)。

## 上板前记录

| 项目 | 记录 |
|---|---|
| Ti60F225 完整板卡型号和 PCB 版本 | TI60F225I3-V4 |
| Efinity Programmer、Efinity IDE、RISC-V IDE 版本 | |
| 板卡供电和 USB 线连接方式 | |
| FT4232 UART 通道及设备管理器显示的 COM 号 | |
| JTAG 和 UART 是否可同时使用 | |
| HDMI 显示器型号和输入口 | |

FPGA UART RX 为 R4/GPIOL_02，TX 为 R14/GPIOR_28，均为 3.3 V LVCMOS。电脑端默认
串口参数为 115200、8-N-1。COM 号由 Windows 分配，不要照搬其他电脑上的编号。测试前
关闭可能占用该 COM 口的串口工具。

## 加载与测试

1. 在 Efinity Programmer 中通过 JTAG 加载 `outflow/ti60f225_oob.bit`。第一次验证使用
   临时 JTAG 配置，不要写入 SPI Flash。
2. 在 Efinity RISC-V IDE 中加载
   `software/interactive_demo/build/keyboard-test/uart_keyboard_test.elf`，运行 CPU，
   并在调试器中查看 `g_uart_keyboard_result`。
3. 运行 `tools/keyboard_uart.py --list`，选择新出现的板卡 UART COM 口并启动发送程序。
   按下和松开各个控制键，确认 `phase == 2`、`accepted_frames` 增加，`buttons` 与按键
   对应，CRC/version/flags/stale 计数保持 0。按 Esc 退出后确认 `buttons == 0`；停止
   串口数据后确认 `timeout_releases` 增加。
4. 停止或复位诊断固件，再加载
   `software/interactive_demo/build/game/survival_game.elf`，仍使用同一个 bitstream。
   运行游戏和键盘发送程序，测试移动、开火、暂停/恢复、重新开始和按键自动释放。
5. 先连续观察 60 秒，再进入敌人数量较多的波次，确保画面同时出现 Alpha 和 Color Key
   精灵，并记录游戏画面和调试器计数。

具体串口命令见[键盘 UART 说明](KEYBOARD_UART_INPUT.md)。诊断 ELF 不是游戏程序。两个
ELF 都不能配合早期仅含 v6 Alpha 演示的 bit 使用。

## 验收数据

| 测量项 | 结果 |
|---|---|
| 连续 60 秒的稳定显示帧率 | |
| 可重复运行的最大同时精灵数 | |
| 最大精灵数量时的帧率 | |
| `error` / `phase` | |
| `underflow_delta` / `missed_delta` | |
| `reader_error` / `command_delta` / `swap_delta` | |
| UART 收到帧数 / CRC 错误 / 版本错误 / 标志错误 / 过期帧 / 超时释放次数 | |
| 键盘响应和断开重连表现 | |
| 暂停时效果、防护、冷却和波次计时是否保持 | |

目标是在 Alpha 和 Color Key 同时显示时，以最大可重复精灵负载稳定达到 60 FPS。如果
无法保持 60 FPS，请记录实际测得的精灵数量和相关计数，不要用主机测试代替上板结果。

## 上板注意事项和故障记录

最新布线报告将 `pll_inst4_RSTN` 列为未分配的核心输出；另有 GPIO 与 LVDS 间距警告。
虽然 Efinity 生成了 bitstream，这些报告项还没有通过实板验证确认无影响。上板时请
留意相关现象并记录 Programmer、调试器或显示器的报错。

如果测试失败，请保存屏幕照片、`g_uart_keyboard_result`、`g_game_result`、
Programmer/OpenOCD 输出、板卡版本、COM 口和 bit/ELF 的准确路径。键盘无响应时先检查
COM 通道、UART 计数和 RX/TX 接线；黑屏或画面不稳定时记录游戏 `phase/error`、
`reader_error`、underflow 和 missed 计数。不要把旧 Alpha 对照程序的结果记录成键盘游戏结果。
