# UART 键盘游戏上板操作说明

这份说明用于封存包中的 UART 键盘游戏版本。先测串口，再运行游戏。本包由已有的 bit
和两个 ELF 复制得到，本次整理没有重新编译 FPGA 或游戏，也还没有接实体板验证。

## 第一次先看这些文件

| 文件或目录 | 用途 |
|---|---|
| `bit/ti60f225_oob.bit` | 用 Efinity Programmer 临时配置 FPGA |
| `ide_project/firmware/uart_keyboard_test.elf` | 第一步运行的键盘串口诊断固件 |
| `ide_project/firmware/survival_game.elf` | 串口确认后运行的游戏固件 |
| `ide_project/uart_keyboard_test_ti.launch` | 诊断程序专用调试配置 |
| `ide_project/survival_game_ti.launch` | 游戏专用调试配置 |
| `tools/keyboard_uart.py` | 把电脑键盘状态发送到板卡 |
| `01_工具检查报告.md` | 本机工具路径和离线检查结果 |
| `manifest.json` | 源码 Git 提交号、封存时间、文件来源和 SHA-256 |
| `refresh_debug.cmd` | 在本机移动或解压包之后，重新生成正确的本地调试路径 |

全部使用同一包中的文件。不要用旧 Alpha 演示 bit 配这两个 ELF，也不要在诊断配置中
选择游戏 ELF。包里的调试项目名为 `advanced_board_debug`，不使用旧 M2 调试配置。

## 今天准备好

1. 保留完整 ZIP，解压到路径只包含英文、数字的目录。本机也可以直接使用已经生成的
   包目录，避免到处找原始构建目录。
2. 确认板卡型号为 TI60F225I3-V4，明天准备板卡配套电源、可传数据的 USB 线、HDMI 线
   和显示器。接口位置及供电方式以板卡手册和板上标识为准。
3. 记住两个工具的作用：Efinity Programmer 加载 bit 到 FPGA；Efinity RISC-V IDE
   加载 ELF 到 FPGA 内的 RISC-V CPU。只加载 bit 并不等于已经运行游戏程序。

## 从源码目录生成封存包

在原工程的 `advanced_demo` 目录打开 PowerShell，运行：

```powershell
$env:PYTHONHOME = 'D:\Efinity\python311'
& 'D:\Efinity\python311\bin\python.exe' -B scripts\prepare_board_package.py
```

脚本只复制已有产物并检查工具和调试配置，不重新编译，也不下载到板卡。输出在
`output/board_ready/advanced_uart_日期_提交号/`，同时生成 ZIP 和 ZIP 的 SHA-256 文件。
已有同名包时会停止，避免覆盖；需要再次整理时用 `--output` 指定一个新的输出目录。
包内 `01_工具检查报告.md` 是这次整理实际得到的检查结果。

## 第一步：接板并确认设备

1. 按板卡手册接好电源和 USB，连接 HDMI。打开 Windows 设备管理器。
2. 查看板卡接入前后新增的 USB 和 COM 设备，记录端口名和 COM 号。不能把本机原有的
   蓝牙 COM 口当成板卡 UART；也不要照抄别人的 COM 号。
3. 若出现未知 USB 设备或下载器无法识别，先保存设备名称和报错，按实际设备确认驱动。
   不要给所有 FTDI 通道批量更换驱动，UART 通道和 JTAG 通道需要分别确认。

## 第二步：用 Programmer 配置 FPGA

1. 打开 Efinity。在菜单 `Tools` 中打开 Programmer。
2. 选择实际检测出的板卡下载器，确认目标为 Ti60F225。
3. 选择 JTAG 配置 FPGA 的模式，文件选择本包的 `bit/ti60f225_oob.bit`。
   初次验证不要选择写 SPI Flash 的模式。
4. 开始下载，等待完成提示。保存失败时的完整报错，不要看到进度条结束就认定成功。
5. 下载成功后退出 Programmer，释放 USB/JTAG，随后再启动 RISC-V 调试会话。

本次只离线核对了 Programmer 的安装与入口路径；按钮名称及硬件选择需要明天结合
实际界面确认。临时 JTAG 配置断电后会丢失，重新上电需要再次加载 bit。

## 第三步：导入专用调试项目

1. 如果移动过包，先双击包根目录 `refresh_debug.cmd`。它使用本机 `D:\Efinity` 下的
   Python 和 RISC-V IDE，刷新路径并进行不接板的配置检查，不会烧录。
2. 打开 Efinity RISC-V IDE，建议选一个单独的高级游戏 workspace，避免混入 basic_demo。
3. 选择 `File → Import → General → Existing Projects into Workspace`。
4. `Select root directory` 选择本包的 `ide_project`，选中 `advanced_board_debug`。
   不勾选 `Copy projects into workspace`，点击 Finish。
5. 进入 `Run → Debug Configurations → GDB OpenOCD Debugging`，应能看到
   `uart_keyboard_test_ti` 和 `survival_game_ti`。若未显示，先在项目上右键 Refresh，
   然后通过 `File → Import → Run/Debug → Launch Configurations` 导入包内两个 `.launch`。

这是用于加载预编译 ELF 的调试项目，不需要执行 Build。配置中已经分别设置了主程序、
下载镜像、符号文件和入口地址；原工程的旧 `apb_reg_test_ti` 仍指向 M2，不要选错。
入口 PC 填 `f9000000`，不带 `0x`；IDE 会自动添加前缀。

## 第四步：先运行 UART 诊断

1. 选择 `uart_keyboard_test_ti`，点击 Debug。正常会在 `main` 处暂停。
2. 按 Resume/F8 让 CPU 运行。在调试器的 Expressions 中添加 `g_uart_keyboard_result`。
   有些字段需要点击 Suspend 后刷新查看；查看完后再次 Resume，按键接收需要 CPU 运行。
3. 在包根目录打开 PowerShell，运行：

```powershell
$env:PYTHONHOME = 'D:\Efinity\python311'
$efxPython = 'D:\Efinity\python311\bin\python.exe'
& $efxPython -B tools\keyboard_uart.py --list
```

根据设备管理器和接板前后的变化选出板卡 UART COM 号。例如实际是 COM8，才运行：

```powershell
& $efxPython -B tools\keyboard_uart.py COM8
```

4. 按 W、A、S、D、空格和 P，然后松开，确认 `accepted_frames` 增加，`buttons` 对应
   按键。`phase == 2` 表示接收循环已启动。正常情况下各类错误帧计数保持为 0。
5. 按 Esc 停止电脑发送程序。确认板端 `buttons` 归零，停止数据超过 150 ms 后
   `timeout_releases` 增加。若调试器挂起过 CPU，应先恢复再观察超时。
6. 结束这个调试会话。下一步同一时间只运行一个 OpenOCD/GDB 会话。

若首次暂停在启动代码，按 F8 到 `main` 后再按 F8；最后以 IDE 显示 Running 为准。
诊断程序不绘制游戏画面；这一阶段即使显示器没有游戏也不能据此判定诊断失败。

## 第五步：运行游戏

1. 确认诊断会话已结束，选择 `survival_game_ti`，点击 Debug，在 `main` 停下后按 F8。
2. 按上一步方法在正确 COM 口启动键盘发送程序。
3. WASD/方向键移动，空格或 Ctrl 开火，P 暂停/恢复。游戏结束后松开开火键，再按一次
   开火键重新开始。Esc 只退出电脑端发送程序。
4. 检查玩家和敌人的 Color Key 透明背景，以及光晕、子弹和受击效果的 Alpha 混合。
5. 让游戏连续运行至少 60 秒，记录画面的 FPS、SPR、MAX，以及 `g_game_result` 中的
   `error`、`reader_error`、`underflow_delta` 和 `missed_delta`。

测 FPS 时保持 CPU 运行，暂停调试会影响测量。需要看完整结构时，可以在测量结束后
暂停 CPU 记录。错误记录和验收表见包内 `docs/上板验证清单.md`；其中提到的原工程
`outflow` 和 `software/.../build` 路径是文件来源，本包请按本页的 `bit`、`firmware` 路径选择。

## 文件校验和移动到另一台电脑

可在包根目录的 PowerShell 运行：

```powershell
$env:PYTHONHOME = 'D:\Efinity\python311'
$efxPython = 'D:\Efinity\python311\bin\python.exe'
& $efxPython -B tools\verify_package.py
```

该检查只核对封存文件的 SHA-256，不操作板卡。移动或解压包后，在导入项目之前运行
`refresh_debug.cmd`，避免调试配置仍指向原路径。如果换了电脑且工具安装位置不同，
在该电脑使用可用 Python 3 运行：

```powershell
python tools\refresh_board_debug.py --package . --ide-root '实际RISC-V-IDE安装目录'
```

这里的 IDE 安装目录应包含 `Efinity-RISCV-IDE`、`openocd` 和 `toolchain` 三个子目录。
刷新路径只改包内 `.project`、`.cproject` 和两个 `.launch`，不改 bit/ELF。
封存包、ZIP 和本机 IDE workspace 不需要加入 Git，准备脚本和这份操作说明可随源码提交。
