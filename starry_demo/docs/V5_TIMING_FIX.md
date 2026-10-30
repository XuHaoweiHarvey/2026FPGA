# v5 BLIT 时序修复记录（2026-10-19）

## 问题与原因

首次 Efinity 2026.1.132 完整编译生成了 bitstream，但最终时序报告中 `core_clk` 的建立时间裕量为 -0.331 ns，未满足 100 MHz。流程执行成功和时序满足要求需要分别判断。

最差路径在 `blit_engine` 内，从 `copy_height[1]` 到 `dst_row[11]` 的寄存器使能端，经过 51 级逻辑。源结束地址检查将以下运算放在同一个组合路径内：

```text
source_end = source + (height - 1) * source_stride + width * 4
source_end <= 0x100000000 → 允许初始化目标行寄存器
```

减法、宽位乘法、加法、范围比较及寄存器使能连续连接，导致该路径延迟超出一个 10 ns 周期。它属于普通 BLIT 和色键 BLIT 共用的参数检查路径。

## 修改

`rtl/accelerator/blit_engine.v` 把检查拆成四拍：

1. `CHECK` 保存几何/对齐检查、`height-1` 以及目的起始地址。
2. `CHECK_SPAN` 保存完整 64 位源行跨度乘积。
3. `CHECK_END` 保存完整 64 位结束地址。
4. `CHECK_RANGE` 拒绝非法参数，或初始化执行寄存器。

命令启动增加 3 个 core 周期（100 MHz 下为 30 ns），每个 burst 的 AXI 流程不变。检查期间保持 BUSY，不发出 AR/AW；参数仍来自命令快照。最高有效地址仍为 `0xFFFFFFFF`，半开结束地址恰为 `0x100000000` 合法，超过则报 `0x21`。零高度单独拒绝，不能通过高度减法回绕接受命令。

寄存器、操作码、VERSION/CAPABILITIES、软件 API、最后 B 后完成、Back ownership 和换帧合同保持原值；不需要升级到 v6。不修改 SDC、时钟频率、PLL 或 DDR/HDMI 物理配置。

## Efinity 结果

同一台机器、Efinity/Elitestek Edition 2026.1.132、Ti60F225/I3、原有约束，完整运行综合、Interface、布局布线和配置文件生成。修复后最终报告时间为 2026-10-19 20:19:28。

| 指标 | 修复前 | 修复后 |
|---|---:|---:|
| core_clk 要求 | 100 MHz | 100 MHz |
| core_clk 建立时间裕量 | -0.331 ns | +1.449 ns |
| core_clk 估算最高频率 | 96.796 MHz | 116.945 MHz |
| 全部已分析关系的最差建立裕量 | -0.331 ns | +0.417 ns |
| 全部已分析关系的最差保持裕量 | +0.027 ns | +0.026 ns |
| XLR | 27940 / 60800 | 28001 / 60800 |
| Memory Blocks | 141 / 256 | 141 / 256 |
| DSP Blocks | 15 / 160 | 12 / 160 |

当前约束下报告的建立/保持检查均为正；116.945 MHz 是分析估算值，实际 core 时钟仍为 100 MHz。结果未经过板卡验证，不作为真实吞吐或 HDMI 运行证据。

本机证据（生成目录均不提交）：

- `outflow/ti60f225_oob.timing.rpt`：修复后的最终时序报告。
- `outflow/ti60f225_oob.place.rpt`：资源及接口未匹配项。
- `outflow/ti60f225_oob.bit`：当前修复后的配置文件。
- `output/graphics/timing_fix/before/`：原 RTL、时序、布局、外围与 CDC 报告备份。
- `output/graphics/timing_fix/efinity_compile.log`：命令行完整流程的阶段 PASS 记录；详细工具日志位于 `outflow/`。

Efinity GUI 中点击 Result 下的刷新图标读取新报告；若仍保留旧结果，重新打开根工程。此次复验通过命令行启动，GUI Console 可能保留上次日志，需按报告时间识别。

## 功能验证

`run_blit_checks.ps1` 原有 32+5+5 场景通过，另加 7 个地址空间顶部场景：最后一个/两个 beat、跨行结束地址恰为 4 GiB、越界一拍、跨度乘积越界、零高度与巨大高度。合法命令执行真实模拟读写并逐像素比较；非法命令无 AXI 事务。故意破坏像素的负对照也被检测。

统一 FILL/BLIT/色键入口、源窗口检查、读仲裁、双缓冲和负对照回归通过。APB WAIT0/1/3 的旧配置和 v5 配置检查通过。完整共享显示系统 WAIT0/1/3 均通过，每组6次swap、42个完整帧和1,407,777次显示像素比较，正常绘制underflow/missed增量0，详细覆盖见 [VALIDATION](VALIDATION.md)。本轮不运行 CPU 指令仿真。

复验入口（在仓库根目录执行，Python 使用可运行且配置正确的解释器）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_blit_checks.ps1 -NoWave
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_graphics_checks.ps1 -NoWave
python scripts/run_d_checks.py --color-key --apb-waits 0 1 3 --output output/graphics/timing_fix/color_key_system
python scripts/run_apb_checks.py
```

## 保留的接口与工具告警

- `Missing Interface Pins=58` 包含未使用的摄像头/MIPI、部分 JTAG、`CLK_5M` 和 DDR 高地址接口。RTL 的 `ROW_WIDTH=14`，而外围保留 `ddr_addr[15:0]`，因此 `[14]`、`[15]` 在列表中；不据此更改板卡 DDR 地址宽度。
- 唯一 `Unassigned Core Pins` 为顶层残留的 `pll_inst4_RSTN`。当前外围 `pll_inst4` 的 `reset_name` 为空，顶层仅声明了该输出；这与当前时序失败路径不同，保留待负责人核对。
- 外围报告有 HDMI 时钟 LVDS 与邻近 GPIO 距离告警；PnR 日志有组合环切断告警。上述告警未因本次时序修改消失，需对照原已上板基线继续审查，不用正裕量替代接口/CDC/板级验收。

当前交付结论是“BLIT 长路径已修复，功能回归及当前约束下静态时序通过”；下一步由 A/C 使用匹配软件完成真实 DDR、1080p HDMI、色键 WSTRB 和持续显示验收，见 [集成验收清单](V5_INTEGRATION_ACCEPTANCE.md)。
