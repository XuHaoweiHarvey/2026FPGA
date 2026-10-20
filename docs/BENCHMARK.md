# v5 固定工作量性能测试（软件模式 4）

该模式测量当前硬件在持续显示、原有 DDR 服务保护开启时，执行 FILL、普通 BLIT 和色键 BLIT 的软件可见耗时。它为赛题的软硬件性能对比提供硬件端测量入口。已收到三轮全屏板级数据，见 [V5_BOARD_BENCHMARK](V5_BOARD_BENCHMARK.md)；CPU 逐像素对照与加速比仍待完成，接入方案见 [CPU_RENDER_PLAN](CPU_RENDER_PLAN.md)。

只新增 OCRAM 软件，不改变 RTL、寄存器或 VERSION/CAPABILITIES。使用包含时序修复的 v5 bit，重新构建并下载 ELF 即可，无需为本功能重新 Compile FPGA。

## 1. 测试内容

| cases 下标 | 矩形大小 | 依次执行的 op |
|---|---|---|
| 0、1、2 | 64×64 | 0=FILL、1=BLIT、2=Color Key BLIT |
| 3、4、5 | 320×240 | 同上 |
| 6、7、8 | 640×480 | 同上 |
| 9、10、11 | 1920×1080 | 同上 |

每组独立完成以下步骤：

1. 用 FILL 构造源图：矩形左半为紫色色键，右半为白色不透明像素，然后 swap 成 Front。源中 X 字节非零，色键只比较 RGB24。
2. 将 Back 全屏设为深蓝背景。显示持续读取 Front，BLIT 也读取这个 Front。
3. 默认预热一次，再测量八次。每次绘制前都先恢复 Back 中目标矩形的背景；恢复背景不计入绘制时间。
4. 每次计时从调用命令 API 前开始，到 `accel_wait_done()` 成功返回后结束，包含参数提交、软件计数和轮询，完成仍要求最后成功 B、BUSY=0、writer ownership 释放。
5. 全部绘制完成后，将最终 Back 显示出来；这次 swap 的请求及等待单独计时，不纳入绘制时间。

源图准备、清背景、预热、诊断读取和换帧不计入 `draw_ticks_total`。它们仍执行真实命令，并包含在命令/诊断累计差值里。没有固定画面停留，测试中画面会切换；最后一组应为左半深蓝、右半白色。

默认共 12 组、96 条被计时命令、12 条预热命令，加上准备/恢复背景合计 **252 条命令、24 次 swap**。每组命令数为 `3 + 2*(samples+warmups)`，swap 数为 2。程序有限运行，完成后进入 `apb_test_done`。

当前色键源精确包含 50% 透明像素，分界按四像素对齐。该工作量用于重复测速；部分 WSTRB、复杂图案和逐像素正确性仍由功能回归及板级验收覆盖。

## 2. A 同学上板操作

1. 确认板上是当前 v5 bit：ID=`0x4143434C`、VERSION=`0x00050000`、CAPABILITIES=`0x000000FB`。记录 bit 来源的提交号；版本号本身不能区分时序修复前后。
2. 将 `software/apb_reg_test/demo_config.h` 的 `DEMO_MODE` 设置为 `4u`，使用正式 BSP Build，并让 Debug 使用刚生成的 ELF。也可用构建脚本的宏覆盖，见下面的命令。
3. 在 `apb_test_done` 设置断点，取消计时过程中的其他断点，然后 Resume。计时中不要暂停、单步或修改变量；尽量在终点统一读取结果，避免调试访问影响测量。
4. 停止后展开 `g_benchmark_result` 及 `cases[0]`～`cases[11]`，保存变量值/截图，并检查下表。`g_apb_test_result` 保留通用失败诊断。
5. 至少重复运行三次，记录每次结果。CPU Debug 重跑不会清平台历史计数，比较程序记录的 baseline 差值。

模式 4 在初始化之后一次性执行，不使用 `g_hold_frames`、`g_frame_limit` 或原演示的场景循环；默认 `DEMO_MODE` 仍为 0。若在 main 断点修改 `g_demo_mode=4`，需在第一次 Resume 前完成。

| 观察项 | 默认预期 |
|---|---|
| `g_benchmark_result.pass` / `g_apb_test_result.pass` | 都为 1 |
| `g_benchmark_result.error_code` / `g_apb_test_result.errors` | 都为 0 |
| `completed_cases` / `case_count` / `phase` | 12 / 12 / 5 |
| `timer_hz` / `samples` / `warmups` | 100000000 / 8 / 1 |
| `commands_issued` / `commands_completed` / `command_delta` | 252 / 252 / 252 |
| `swaps_requested` / `swaps_completed` / `swap_delta` | 24 / 24 / 24 |
| `underflow_delta` / `missed_delta` | 0 / 0 |
| 每组 `complete` / `samples_completed` | 1 / 8 |
| 每组 `command_delta` / `swap_delta` | 21 / 2 |
| 每组 `draw_ticks_total` / `swap_ticks` | 大于 0，记录真实值 |

模式 4 的分组与样本数以 `g_benchmark_result` 为准，原模式 2/3 专用的 BLIT/色键软件计数字段不用于此模式。模式 4 的 pass 表示计时流程、命令数、角色及连续性检查通过；程序没有 CPU 读回 DDR 的像素校验能力，仍需保留板级照片和功能验收。

在仓库根目录构建独立产物（使用已配置的 Python 和正式 IDE 工具链）：

```powershell
python scripts/build_apb_software.py --define DEMO_MODE=4 --output output/graphics/benchmark_v5
```

本机使用已有 Xilinx GNU RISC-V GCC 13.3.0 配正式 Sapphire BSP 的可复现命令：

```powershell
$env:PYTHONHOME = 'D:\Efinity\python311'
& 'D:\Efinity\python311\bin\python.exe' scripts/build_apb_software.py --toolchain-prefix 'D:/Xilinx/2025.1/gnu/riscv/nt/riscv64-unknown-elf/bin/riscv64-unknown-elf-' --define DEMO_MODE=4 --output output/graphics/benchmark_v5
```

本机产物为 `output/graphics/benchmark_v5/apb_reg_test.elf`，该生成目录不提交。改变 `BENCHMARK_SAMPLES`（1～64）或 `BENCHMARK_WARMUPS`（0～8）需要重新 Build；构建脚本支持额外 `--define BENCHMARK_SAMPLES=16` 等覆盖。

## 3. 时间和吞吐字段怎样理解

CLINT 频率取正式 BSP 的 `SYSTEM_CLINT_HZ`，当前为 100 MHz。使用高/低/高重读获得 RV32 下的一致 64 位时间，跨过低 32 位约 42.95 秒的回绕仍可计时。不会写 CLINT 或改变计数器配置。

| 每组字段 | 含义 |
|---|---|
| `draw_ticks_total/min/max` | 被计时命令的总时间、最短/最长单次时间，单位 CLINT tick |
| `draw_us_total/mean/min/max` | 同上，换算为整数微秒并向下取整；保留 ticks 供精确重算 |
| `swap_ticks` / `swap_us` | 最后一幅画面的 swap 请求至完成的等待时间，含 API/轮询 |
| `rectangle_pixels_total` | `width*height*samples`，色键透明像素也算被处理像素 |
| `opaque_pixels_total` | FILL/BLIT 等于矩形总像素；本模式色键工作量为总像素的一半 |
| `rectangle_pixels_per_second` | 总矩形像素×timer_hz / draw_ticks_total |
| `opaque_pixels_per_second` | 根据测试图案推算的非透明像素吞吐，非独立硬件 strobe 统计 |
| `writer_bursts_delta` / `writer_throttle_cycles_delta` | 整组含准备/预热/恢复背景的写 burst 数和写准入等待周期差值 |
| `reader_frames_delta` | 整组期间显示 reader 完成帧数差值 |

这些是 **持续显示条件下、CPU 轮询 API 的端到端测量**，不是纯 DMA 内核周期、DDR 实际带宽、CPU 占用率或屏幕 FPS。CPU 仍在轮询等待；不能用这份结果宣称 CPU 已空闲。色键透明拍仍会完成 AXI 事务，不能将非透明像素数直接当作总线传输字节。

`timer_read_ticks_min` 是 16 次相邻计时读取之间的最小间隔，用于观察计时开销；不从样本中扣除，避免人为抬高短命令吞吐。32 位硬件诊断差值按模 2^32 计算，极长单组运行可能多次回绕；64 位绘制时间单独保存。

推荐留证表（每个 case 填一行，每次运行单独保存）：

| bit提交号 / ELF提交号 | 次数 | op | width×height | samples | mean/min/max µs | pixels/s | swap µs | underflow/missed增量 |
|---|---:|---|---|---:|---|---:|---:|---|
| 待实测 | | | | | | | | |

后续 CPU 软件对照需要先提供合法的 CPU framebuffer 访问路径，并统一场景、像素量、计时范围和显示条件。当前 CPU 是控制专用 OCRAM 配置，不能把仿真耗时或另一个平台的 CPU 数字作为此板加速比。

## 4. 失败记录与本机验证

任何失败都保留 `active_case`、`failure_phase`、`error_code` 和通用诊断，然后停止继续提交。不会清除硬件错误、复位 DDR、取消 swap 或强制释放在途事务。

新增软件错误：`0xE200` 配置/样本范围不符，`0xE201` 时钟未前进或倒退，`0xE202` 命令/swap计数不符，`0xE203` 缓冲角色/reader base 不符。原 API 超时与硬件错误码直接保留，`0xE109` 表示运行期间 underflow/missed 增长。阶段为 1准备、2预热、3绘制、4换帧、5完成、255失败。

2026-10-19 本机验证：

- 原模式 0/2/3 及新增模式 4 均以正式 BSP 和 RV32IM 配置构建；`-Wall -Wextra -Werror`，LOAD/结果符号/栈位于 OCRAM，保留 OpenOCD 空间。
- 原生 C 行为后端检查全部 12 组的像素结果、源保持、50%色键背景保持、预热排除、时间最小/最大/总量及吞吐换算；覆盖默认参数、另一初始 Front、最大样本数和变化延迟。
- 检查 64 位时钟读取跨低字回绕、硬件累计计数回绕、冻结时钟、非法配置、旧版本、reader错误、提交拒绝、写失败、显示欠载/边界丢失、计数不符和缓冲角色错误；失败后不继续换帧或发布成功。
- 工程/50个寄存器契约检查通过；旧调试配置检查因本机缺少其默认路径下的 IDE GDB 而跳过，不安装工具或改动团队 Debug 配置。
- 原生后端是软件行为测试，不执行 Sapphire/RISC-V 指令、RTL 或真实 DDR；本轮跳过已有权限受限的 Unicorn 入口。后续收到的真实板级时间与画面单独记录于 [V5_BOARD_BENCHMARK](V5_BOARD_BENCHMARK.md)，不与本机测试混写。

运行原生软件检查需要已有本机 C 编译器：

```powershell
python scripts/run_benchmark_checks.py
# MSVC 在已初始化的 Developer Command Prompt / Developer PowerShell 中执行：
python scripts/run_benchmark_checks.py --cc cl
```

实现入口：[accel_benchmark.h](../software/apb_reg_test/accel_benchmark.h)、[benchmark_clock.h](../software/apb_reg_test/benchmark_clock.h)、[main.c](../software/apb_reg_test/main.c)。
