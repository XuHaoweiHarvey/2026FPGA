# UART 键盘游戏构建报告

## 构建结果

UART 键盘高级游戏工程于 2026-10-23 使用 Efinity 2026.1.132 完成 Ti60F225 完整
bitstream 编译。生成的配置文件为 `outflow/ti60f225_oob.bit`。游戏和键盘诊断固件基于
重新生成的 Sapphire SoC/BSP 构建：

| 文件 | 路径 |
|---|---|
| FPGA 配置文件 | `outflow/ti60f225_oob.bit` |
| 游戏固件 | `software/interactive_demo/build/game/survival_game.elf` |
| UART 诊断固件 | `software/interactive_demo/build/keyboard-test/uart_keyboard_test.elf` |

启用 UART 的 SoC 端口为 `system_uart_0_io_rxd` 和 `system_uart_0_io_txd`，控制模块
已将它们接到板卡 UART 引脚。重新生成的 BSP 将 UART0 映射到 `0xF8010000`，参考时钟
为 100 MHz，串口配置为 115200、8-N-1。`scripts/check_project.py` 检查了 SoC 输入端口、
控制模块连接、UART 方向、引脚唯一性和 V4 引脚映射，检查通过。

## 编译报告

最终时序报告将 `core_clk` 约束为 100 MHz。同域路径的 setup slack 为正 0.701 ns，
hold slack 为正 0.026 ns。报告中最小的 hold slack 是 400 MHz `sdram_clk` 路径的
0.023 ns。资源报告显示 XLR 使用 51,076/60,800（84.01%）、存储器块 167/256
（65.23%）、DSP 46/160（28.75%），PLL 为 4/4。Bitstream 生成器运行完成，工程状态
报告标记 bitstream 编译流程通过。

布线报告将 `pll_inst4_RSTN` 列为未分配的核心输出。布局问题报告还提示 GPIO
GPIOR_P_09 与 LVDS `tmds_tx_clk` 接口的间距问题。这些情况已记录供上板调试检查，
目前没有实板证据证明它们可以忽略。

## 验证范围

工程结构以及 UART SoC/引脚连接检查通过。游戏 ELF 和诊断 ELF 已完成交叉编译，完整
FPGA 编译生成了 bitstream。本次环境没有找到本机 C 编译器，因此没有运行游戏逻辑和
UART 协议 C 回归。当前电脑的 Windows `py -3` 启动器也无法启动所登记的 Python；在
当前 PowerShell 设置 `PYTHONHOME=D:\Efinity\python311` 后，可以使用 Efinity 自带
Python 运行工程脚本。

目前没有完成实体板验证。FT4232 的 UART 通道/COM 口对应关系、JTAG 和 UART 能否同时
使用、键盘数据接收、游戏画面、实际帧率、最大同时精灵数量和运行时显示计数都需要在
TI60F225I3-V4 上确认。FPGA 编译通过不能代替上板验证。

## 上传和交付说明

上述 bitstream 和两个 ELF 位于 Git 忽略的 `outflow`/`build` 目录，普通 Git 提交和推送
不会上传它们。需要将文件单独复制给上板人员，或在对方电脑上从源码重新构建。使用时，
bitstream 必须与同一源码和 BSP 状态构建出的诊断 ELF 或游戏 ELF 配对；诊断程序与游戏
程序是不同的固件镜像。
