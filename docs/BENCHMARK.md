# 性能口径与历史实测

当前演示的性能必须按各自的软件、硬件和工作量记录；以下历史证据保留采集范围，不能直接当成当前交付包的实测结果。原始图片与人工摘录 JSON 集中保存在 [evidence](evidence/)。

## 当前基础版计时

当前 [基础软件](../basic_demo/software/basic_demo/README.md) 顺序循环：矩形 CPU → 矩形 FPGA → 图片 CPU → 图片 FPGA。两种实现使用相同种子、矩形数、图片和双缓冲历史；默认 24 个矩形，允许 1～64。

一帧 Render 从任务生成前计时，到 CPU 事务排空并释放会话，或 FPGA 真正 DONE 后结束。清理旧矩形/重建 Back 包含在 Render 中；HUD 和安全 Swap 单独计时。图片 CPU 路径真实读取 DDR 素材并逐像素写 Back，FPGA 用普通 BLIT，不以仿真运行速度代替板上 CPU 时间。

`metric[scene][mode][class]` 中 class 1 记录矩形阶段首两帧全区清理，class 0 记录稳态；只比较同场景、同负载、同 class 的有效样本。缺样本显示 WAIT。每阶段从首帧实际安全呈现起运行至少 5 秒，完成当前帧后切换。

| 指标 | 定义与限制 |
|---|---|
| Render FPS | 已完成绘制帧数 / 对应 Render 时间 |
| Presented FPS | 实际安全 Swap 数 / 墙钟时间 |
| HDMI 刷新率 | 固定 60 Hz，不等于生成新帧的速度 |
| Hardware Speedup | 同条件 FPGA Render FPS / CPU Render FPS |
| CLINT tick | BSP 当前为 100 MHz；64-bit 一致读取，保留原始 ticks |
| underflow/missed | 对稳定 baseline 的 uint32 差值；underflow 统计周期，不是黑屏次数 |

采集时记录 bit/ELF SHA256、源码版本、矩形数、样本 class、预热/测量时长、原始 ticks、实际换帧和错误增量。计时中不暂停或单步 CPU；软件 pass 与截图不能替代这些溯源信息。

## M2 历史实板样本（2026-10-22）

负责人反馈 M2 功能验收通过，五张视频截图见 [m2_board_20261022](evidence/m2_board_20261022/)。截图可直接读取：

| 场景 | CPU Render FPS | FPGA Render FPS | HUD Speedup | 证据 |
|---|---:|---:|---:|---|
| 50 矩形样本 A | 0.76 | 65.83 | 86.61× | [截图 A](evidence/m2_board_20261022/01_rectangles_run_a.png) |
| 50 矩形样本 B | 3.79 | 90.53 | 23.88× | [截图 B](evidence/m2_board_20261022/02_rectangles_run_b.png) |
| 640×480 图片切换 | 0.81 | 99.39 | 122.70× | [阶段 1](evidence/m2_board_20261022/03_image_stage_a.png)、[阶段 2](evidence/m2_board_20261022/04_image_stage_b.png)、[阶段 3](evidence/m2_board_20261022/05_image_stage_c.png) |

矩形两组的测量窗口/class 未标明且差异较大，分别保留，不直接平均为稳态值。图片数值是 HUD 读数，不是重新计算的多轮均值。截图未提供加载 bit/ELF 哈希、装载耗时、完整四阶段时长及错误计数，不能据此补写“错误为零”或把历史值套用于当前默认 24 矩形。

## v5 固定工作量实板记录（2026-10-20 归档）

原测试按 64×64、320×240、640×480、1920×1080 四种尺寸分别测 FILL/BLIT/色键，共 12 cases；每组预热 1 次、采样 8 次。每组源图左半为紫色色键、右半白，Back 为深蓝；恢复背景不计入 draw。默认含准备/恢复共 252 条命令、24 次 Swap。测试程序属于已移除的历史 Mode 4，下面保留实际数据供比较。

运行软件模式 4，持续输出 1920×1080 HDMI，像素为 XRGB8888。计时频率为 100 MHz，每组预热 1 次、采样 8 次。计时从绘制 API 提交前至完成轮询返回后；准备源图、恢复背景、预热、诊断、换帧排除在绘制样本外。这是历史 Mode 4 的测量，不是当前基础版或 PixelForge 的重测。

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

### 三轮全屏结果

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

### 画面与结果解释

[最终画面](evidence/v5_benchmark_20261020/final_color_key.png) 为左半深蓝、右半白，符合最后一组全屏色键操作：源图左半紫色 `RGB=0xFF00FF` 命中色键后保留目标背景 `0x00182838`，右半不透明像素正常复制。用户此前提供的模式 3 机器人照片也与左右普通/色键复制预期一致；该照片未在这批性能截图中重复归档。

中间源图和绘制结果会快速切换，模式 4 没有固定停留。用户描述切换期间看起来会黑一下；仅凭终态截图和计数，不能认定瞬时黑屏的原因已经解决或整段 HDMI 输出绝无异常。如重复出现可辨认的黑屏，应单独记录持续时间、显示器是否重新同步及同期诊断；保留现有显示保护。

色键图案包含 50% 透明像素，非透明像素吞吐约为矩形吞吐一半。透明拍仍完成 AXI 事务，故普通和色键复制耗时相近符合当前实现。`writer_bursts_delta=332640`、节流周期和 reader 帧数覆盖整组准备/预热/恢复/绘制，不能除以仅含计时绘制的时间来推算总线带宽或节流占比。

这些数值属于持续显示条件下轮询 API 的端到端耗时和矩形像素吞吐，不是屏幕刷新率、DDR 带宽或 CPU 占用率。该历史测试仅有硬件组，不提供 CPU 加速比；当前基础版已具备 CPU 对照，必须在同一软硬件与工作量下重新测量。

## 旧居中飞机游戏（2026-10-26）

[截图与说明](evidence/game_perf_20261026/README.md)、[人工摘录 JSON](evidence/game_perf_20261026/results.json) 对应旧 640×480 居中游戏：48 敌机、64 子弹、队列开启、team sprites，非 Flash 装载。60 秒平均/最低秒窗为 30 FPS，sprite 数为 111～120，最慢绘制 27.134 ms，最大换帧间隔 33.333 ms；显示 3600 次、重复 1800 次，underflow/missed 增量 0/0。

报告中 1800 帧均超出其绘制预算；稳定 30 FPS 不表示达到 60 FPS。截图缺少完整错误导出和板上加载文件哈希，本地候选产物哈希不能证明板上版本。该证据是优化历史基线，不能代表现役 PixelForge 或压力版。

## 当前两款游戏

PixelForge 的 1024、压力版的 2048 是容量上限，不是实测稳定 60 FPS 上限。两者分别使用 16×16 与 8×8 敌弹，场景、Alpha 和提交开销不同，不能按弹数直接换算性能。当前构建的实测状态与验证限制见 [PixelForge](../starry_demo/advanced_demo/docs/PIXELFORGE.md) 和 [压力测试](../starry_demo/advanced_demo/docs/LUNARIA_STRESS.md)。

建议每档预热 5 秒、测量 60 秒，同时记录平均/最低 FPS、最慢绘制、超预算帧、重复帧、实际敌弹数与错误增量，分别覆盖不射击和持续射击。软件指令数减少、RTL 绘制周期减少属于相应局部验证，不能写成整帧 FPS 提升比例。
