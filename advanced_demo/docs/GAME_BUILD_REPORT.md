# UART 键盘游戏构建报告

## 最新 v7 队列版（2026-10-25）

### 性能对照配置

2026-10-26 修复居中版图片丢失：使用独立的 `GAME_TEAM_BACKGROUND=1` 编入原海岛图，
启动时将整幅背景复制到两个物理缓冲，游戏帧仅恢复中央 640×480 区域。队伍飞机、子弹和
六帧爆炸继续使用原素材。修复版 ELF 要求背景与队列能力 `0x00000600`，沿用同一 v7 bit；
由旧纯色版切换时须重新配置 bit，清除素材封存。交叉编译、OCRAM 链接、三种显示/背景配置
的主机回归、22 项调试检查及打包校验通过；未进行本轮实板测试。

已增加独立的 GAME_FULLSCREEN=0 构建入口 scripts/build_centered_game.cmd。它输出
software/interactive_demo/build/game-centered/survival_game.elf，视口为
640×480@(640,300)，HDMI 时序仍为 1920×1080@60 Hz。启动时两个物理缓冲都写入外围
海岛背景，正常帧只恢复视口；Alpha、Color Key、队友精灵、O2、无 Flash 和 v7 命令队列保持
与全屏满载对照一致。scripts/package_centered_campaign_game.py 会复制同一 bit、写入
哈希和配置清单，且不会覆盖 build/game 全屏 ELF。

当前居中包仍未进行实板 60 秒测量。主机回归和交叉编译只能证明几何/ABI/链接正确，不能
证明稳定 60 FPS。切换全屏与居中 ELF 时由于图集缩放不同，必须重新配置同一 v7 bit，
再加载目标 ELF。

测量 ABI 新增 g_game_measurement_complete 冻结标记和 g_game_build_config 配置快照。
窗口在提交计时标志关闭但提交字段非零时会提示数据不具备 CPU 入队归因资格；队列背压
时间仍只能结合帧末等待、写节流和读停顿判断。

针对高负载画面提交绘制命令后 CPU 反复等待的问题，高级图形通路增加 8 项 FIFO，
并将队首描述符寄存化；源区域校验使用窄化后的常数除法输入，缩短绘图命令启动路径。
游戏 ELF 在每条命令成功入队后继续提交画面，帧末统一等待 FIFO 和绘图引擎排空，
满队列时按 ready 状态背压。v6 API 同步行为保留。

Efinity 2026.1.132 的 map、interface、pnr、pgm 全流程通过，生成 v7 bit 和 O2 全屏
战役 ELF。最终 100 MHz `core_clk` setup slack 为 **+2.340 ns**；资源使用为 XLR
54,856/60,800（90.22%）、Memory Blocks 169/256（66.02%）、DSP 46/160（28.75%）。
硬件版本为 `0x00070000`，完整能力为 `0x000007FB`，本 ELF 要求全屏背景与命令队列能力
掩码 `0x00000600`。配套哈希和烧录说明位于 `output/campaign_game/`。

FIFO 顺序/满队列/回绕/错误清空、v7 APB、九条命令的真实 DMA 入队/背压/排空、Alpha 与
源地址 guard、双缓冲、RGB 顶层、游戏逻辑和 O2 ELF 构建检查通过。板卡尚未加载本轮
bit/ELF；稳定 60 FPS 是验收目标，不能由仿真或时序分析代替实板 60 秒满负载测量。

以下为旧 v6 构建记录，保留作历史基线；其时序、资源和验证环境描述不代表当前 v7。

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
