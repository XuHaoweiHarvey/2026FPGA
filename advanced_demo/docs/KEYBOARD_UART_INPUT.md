# 通过 UART 使用电脑键盘控制高级游戏

游戏通过 USB-UART 串口接收电脑键盘状态。电脑端小程序每秒发送 50 次完整按键状态；
板端解析程序会拒绝校验错误、重复或过期的数据帧。如果连续 150 ms 没有收到有效帧，
板端会释放全部按键，避免串口断开后角色一直移动。

## 数据帧格式

串口参数为 115200 波特率、8-N-1，按标准 UART 顺序发送。每帧共 6 字节：

| 字节 | 含义 |
|---|---|
| 0–1 | 帧同步标志：`A5 5A` |
| 2 | 协议版本：`01` |
| 3 | 无符号序号，每发送一帧加一，最大 255 后回到 0 |
| 4 | 当前按键位图 |
| 5 | CRC-8/ATM，生成多项式 `07`、初值 `00`、不反射且无异或输出；校验字节 2–4 |

按键位定义：bit 0 上、bit 1 下、bit 2 左、bit 3 右、bit 4 开火、bit 5 暂停；
保留位必须为 0。板端只接受模 256 后序号差为 1–127 的新帧，因此允许序号回绕，
拒绝重复帧和重放帧。每帧携带完整按键状态，不只发送按下/抬起事件。电脑程序退出时
会连续发送两帧“全部松开”；板端的 150 ms 超时也是一层保护。

## 电脑端键盘发送程序

`tools/keyboard_uart.py` 使用 Python 标准库和 Windows 自带的 Win32 键盘、串口接口；
不需要安装 pyserial，也不需要管理员权限。先关闭已经占用该 COM 口的串口终端。在
`advanced_demo` 目录下打开 PowerShell，运行：

```powershell
$env:PYTHONHOME = 'D:\Efinity\python311'
$efxPython = 'D:\Efinity\python311\bin\python.exe'
& $efxPython tools\keyboard_uart.py --list
& $efxPython tools\keyboard_uart.py COMx
```

把 `COMx` 替换为接上板卡后 `--list` 显示的板卡 UART 串口号。COM 编号由 Windows
分配，不同电脑或 USB 插口可能不同。本机当前的 `py -3` 启动器无法正常启动它登记的
Python，因此本机请使用上面的 Efinity Python 命令。`PYTHONHOME` 仅影响当前
PowerShell 窗口。

发送程序在后台读取全局键盘状态，不要求窗口处于前台。WASD 或方向键移动，空格或
Ctrl 开火，P 暂停，Esc 退出并发送松键状态。若固件串口参数改变，可通过 `--baud`
和 `--rate` 更改发送端的波特率和发送频率。

## FPGA 接入情况

UART0 已在 `ip/soc_control/settings.json` 中启用，并已生成到 Sapphire SoC 和 BSP。
`rtl/control/sapphire_control.v` 将生成端口 `system_uart_0_io_rxd` 和
`system_uart_0_io_txd` 接到板卡 UART 输入、输出。TI60F225I3-V4 的引脚约束如下：

| 信号 | FPGA 方向 | 引脚 | IO 标准 |
|---|---|---|---|
| `uart_rx` | 输入 | R4 / GPIOL_02 | 3.3 V LVCMOS |
| `uart_tx` | 输出 | R14 / GPIOR_28 | 3.3 V LVCMOS |

Efinity 2026.1.132 完整编译和两个固件构建已于 2026-10-23 完成。
`scripts/check_project.py` 检查了生成的 SoC/BSP 端口和 V4 引脚连接，目前通过。
实体板尚未测试：FT4232 UART 通道与 COM 号的对应关系、JTAG 和 UART 是否能同时使用、
按键是否能收到以及游戏实际效果都需要拿到板后确认。本机目前能看到的 COM 口是蓝牙
虚拟串口，不能据此判断板载 UART 的端口号。

## 建议的上板测试顺序

1. 接上 TI60F225I3-V4 板卡和 USB 线。在 Windows 设备管理器中查看新出现的 FT4232
   UART COM 口。UART 串口与 JTAG 是不同通道；不要照搬其他电脑上的 COM 编号。
2. 在 Efinity Programmer 中通过 JTAG 加载 `outflow/ti60f225_oob.bit`。第一次验证先
   使用临时 JTAG 配置，不要写入 SPI Flash。
3. 在 Efinity RISC-V IDE 中加载
   `software/interactive_demo/build/keyboard-test/uart_keyboard_test.elf`，运行 CPU，
   并在调试器中查看 `g_uart_keyboard_result`。
4. 在上面的 PowerShell 命令中选择板卡 COM 口并运行键盘发送程序。依次按下、松开方向
   键、开火键和暂停键。`phase` 应为 2，`accepted_frames` 应持续增加，`buttons` 应
   对应按键位图；bad CRC、version、flags、stale 计数应保持为 0。按 Esc 退出后确认
   `buttons == 0`；停止串口数据后确认 `timeout_releases` 增加。
5. 停止或复位诊断程序，加载
   `software/interactive_demo/build/game/survival_game.elf`，使用同一个 bitstream 运行
   游戏和键盘发送程序，测试移动、开火、暂停/恢复、重新开始以及按键释放。

游戏和诊断 ELF 是两个不同程序。不要把诊断 ELF 当作游戏运行，也不要将这两个 ELF
与早期仅含 v6 Alpha 演示的 bit 混用。上面所有文件必须来自同一 UART 版本和同一次
源码构建。bit 和 ELF 都被 Git 忽略，需要单独复制给烧录人员，或在对方电脑上重新构建。

## 离线检查

在 `advanced_demo` 目录下的 PowerShell 中运行工程连接检查和 UART 协议回归：

```powershell
$env:PYTHONHOME = 'D:\Efinity\python311'
$efxPython = 'D:\Efinity\python311\bin\python.exe'
& $efxPython scripts\check_project.py
& $efxPython scripts\run_uart_keyboard_checks.py
```

UART 协议回归需要本机 C 编译器，例如在 Visual Studio Developer PowerShell 中运行。
它会检查 CRC、垃圾数据和不完整帧恢复、错误或不支持的帧、序号重放和回绕、超时释放、
重连以及毫秒计数回绕。模拟 MMIO FIFO 的测试还会检查 UART 初始化、单次读取上限、
按键状态和按下/抬起事件。离线测试只能检查软件，不能确认 USB-UART 通道选择或板卡接线。

## 本机重新生成 SoC/BSP 时的 Java 提示

当前源码中的 UART0 已启用并已生成；仅为上板使用不需要再次生成 IP。如果将来修改硬件
后，在 Efinity IP Configuration 生成时遇到 `'java' is not recognized`，请关闭所有
Efinity 和 IP Configuration 窗口，并在任务管理器中确认 `efinity.exe` 已退出。然后在
`advanced_demo` 目录运行 `open_efinity_with_java.cmd`，它会用本机 Efinity 安装自带的
Java 启动 Efinity。也可以在命令提示符中运行 `open_efinity_with_java.cmd --check`，
先检查 Java 和 Efinity 是否存在。该脚本路径针对本机 `D:\Efinity` 安装；重新生成时
保持 UART0 启用，并重新运行 `scripts/check_project.py` 和完整 Efinity 编译。
