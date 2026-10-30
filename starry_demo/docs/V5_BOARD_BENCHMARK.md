# v5 实板性能记录

整理日期：2026-10-20。依据用户在本次联调中提供的开发板画面和调试器截图；这里没有执行新的板卡测试。三轮按截图提交顺序编号，原始截图及人工转录数据保存在 [evidence/v5_benchmark_20261020](evidence/v5_benchmark_20261020/results.json)。

## 测试条件与证据范围

运行软件模式 4，持续输出 1920×1080 HDMI，像素为 XRGB8888。计时频率为 100 MHz，每组预热 1 次、采样 8 次。计时从绘制 API 提交前至完成轮询返回后；准备源图、恢复背景、预热、诊断、换帧排除在绘制样本外。详细流程见 [BENCHMARK](BENCHMARK.md)。

第一轮的 [总结果截图](evidence/v5_benchmark_20261020/run1_summary.png) 显示：

| 字段 | 实测值 |
|---|---:|
| VERSION / CAPABILITIES | 0x00050000 / 0xFB |
| service_read_quota / service_watermarks | 128 / 0x02000180 |
| pass / error_code / phase | 1 / 0 / 5 |
| completed_cases / case_count | 12 / 12 |
| commands_issued / commands_completed / command_delta | 252 / 252 / 252 |
| swaps_requested / swaps_completed / swap_delta | 24 / 24 / 24 |
| underflow_baseline / underflow_delta | 66 / 0 |
| missed_baseline / missed_delta | 0 / 0 |
| timer_read_ticks_min | 118 ticks，即 1.18 µs |

历史 underflow=66 不代表本次测试新增 66 次错误；该计数统计欠载周期，当前运行增量为 0。第一轮完整流程检查通过。后两轮目前只有 cases[9..11] 截图，没有各自的总结果截图，不能补写它们的全局 pass 或其他九组数据。

板上 bit 和 ELF 的确切来源提交号、采集时间、计时期间是否曾暂停调试器尚未提供。仓库本地包含时序修复提交 `9dae649` 和测速软件提交 `62573dc`，但这不能证明板上加载文件就来自这两个提交。正式对外引用前补齐构建来源和测量操作记录。

## 三轮全屏结果

每行均为 1920×1080、8 个计时样本。平均/最短/最长与换帧时间直接采用截图中的整数微秒，再换算为毫秒；不增加原始结果的精度。吞吐中的 M 为 10^6。

| 轮次 | case / 操作 | 平均 ms | 最短～最长 ms | 矩形吞吐 MPixel/s | 换帧 ms | 原始截图 |
|---|---|---:|---|---:|---:|---|
| 1 | 9 / FILL | 62.643 | 62.340～63.188 | 33.101648 | 12.672 | [截图](evidence/v5_benchmark_20261020/run1_case09_fill.png) |
| 1 | 10 / BLIT | 65.651 | 65.630～65.783 | 31.584757 | 0.900 | [截图](evidence/v5_benchmark_20261020/run1_case10_blit.png) |
| 1 | 11 / 色键 BLIT | 65.651 | 65.631～65.783 | 31.584780 | 0.901 | [截图](evidence/v5_benchmark_20261020/run1_case11_key.png) |
| 2 | 9 / FILL | 62.635 | 62.340～63.173 | 33.105584 | 12.694 | [截图](evidence/v5_benchmark_20261020/run2_case09_fill.png) |
| 2 | 10 / BLIT | 65.650 | 65.627～65.777 | 31.585402 | 0.907 | [截图](evidence/v5_benchmark_20261020/run2_case10_blit.png) |
| 2 | 11 / 色键 BLIT | 65.650 | 65.627～65.777 | 31.585492 | 0.907 | [截图](evidence/v5_benchmark_20261020/run2_case11_key.png) |
| 3 | 9 / FILL | 62.643 | 62.340～63.187 | 33.101820 | 12.678 | [截图](evidence/v5_benchmark_20261020/run3_case09_fill.png) |
| 3 | 10 / BLIT | 65.652 | 65.630～65.783 | 31.584601 | 0.900 | [截图](evidence/v5_benchmark_20261020/run3_case10_blit.png) |
| 3 | 11 / 色键 BLIT | 65.650 | 65.627～65.778 | 31.585515 | 0.908 | [截图](evidence/v5_benchmark_20261020/run3_case11_key.png) |

九张截图共同确认 `complete=1`、`samples_completed=8`、`command_delta=21`、`swap_delta=2`、`underflow_delta=0`、`missed_delta=0`。这些是每个全屏 case 的结果，不能扩展为后两轮全程连续性或长期压力测试结论。

按原始 `draw_ticks_total` 汇总每种操作的 24 个样本：

| 操作 | 汇总平均 ms | 汇总矩形吞吐 MPixel/s | 三轮平均值极差 / 均值 |
|---|---:|---:|---:|
| FILL | 62.641 | 33.103018 | 0.0119% |
| BLIT | 65.652 | 31.584920 | 0.0025% |
| 色键 BLIT | 65.651 | 31.585263 | 0.0023% |

换算公式：`平均秒数 = sum(draw_ticks_total)/(100000000*24)`；`矩形吞吐 = (1920*1080*24)*100000000/sum(draw_ticks_total)`。最后一列比较三轮原始 tick 平均值；与截图向下取整后的微秒数略有差别。三轮重复性良好，不代表已经测得跨温度、长期运行或所有尺寸的稳定性。

## 画面与结果解释

[最终画面](evidence/v5_benchmark_20261020/final_color_key.png) 为左半深蓝、右半白，符合最后一组全屏色键操作：源图左半紫色 `RGB=0xFF00FF` 命中色键后保留目标背景 `0x00182838`，右半不透明像素正常复制。用户此前提供的模式 3 机器人照片也与左右普通/色键复制预期一致；该照片未在这批性能截图中重复归档。

中间源图和绘制结果会快速切换，模式 4 没有固定停留。用户描述切换期间看起来会黑一下；仅凭终态截图和计数，不能认定瞬时黑屏的原因已经解决或整段 HDMI 输出绝无异常。如重复出现可辨认的黑屏，应单独记录持续时间、显示器是否重新同步及同期诊断；保留现有显示保护。

色键图案包含 50% 透明像素，非透明像素吞吐约为矩形吞吐一半。透明拍仍完成 AXI 事务，故普通和色键复制耗时相近符合当前实现。`writer_bursts_delta=332640`、节流周期和 reader 帧数覆盖整组准备/预热/恢复/绘制，不能除以仅含计时绘制的时间来推算总线带宽或节流占比。

这些数值属于持续显示条件下轮询 API 的端到端耗时和矩形像素吞吐，不是屏幕刷新率、DDR 带宽或 CPU 占用率。CPU 软件绘图对照尚未实现，当前没有软硬件加速比。

## 下一次采集补充

1. 补齐三轮 bit/ELF 构建来源，确认计时中没有暂停、单步或持续调试读取。
2. 保存后两轮总结果及 `g_apb_test_result` 诊断；需要完整尺寸性能表时再导出 cases[0..8]，当前没有这九组的原始性能值。
3. 在新的 CPU 对照硬件上重新测量硬件组，避免将新互连下的 CPU 数值直接除以旧 v5 数值。

CPU 访问路径的核对与下一阶段方案见 [CPU_RENDER_PLAN](CPU_RENDER_PLAN.md)。
