# Alpha 连续供数与敌弹缓存：v9 / v10

已完成 SPR 数字显示修正，以及第 3、4 项硬件优化。两份新 bit 均已完成综合、布局布线与 bit 生成，最终时序通过。2026-10-29 收到用户提供的 v10 实板截图：48 / 470、Alpha 225，60,012 ms 内平均 59.99 FPS、最低秒窗 59.28 FPS、最慢绘制 10.637 ms、绘制超预算 0 帧、重复旧帧计数 1、underflow / missed 增量 0 / 0。详见 [截图证据及限制](evidence/game_perf_20261028_v10/README.md)。v9 尚无本轮实板结果；v10 尚未满足严格零重复验收，也未验证 512 敌弹极限。构建阶段由代理生成文件，板卡配置与运行由用户完成。

HDMI 继续输出 1920×1080@60 Hz，中央游戏区 640×480、外围硬件输出黑色。用户素材、精灵尺寸、Alpha / Color Key 运算顺序及动态数量规则保留。原 v7 / v8 bit、全屏与原窗口 ELF 的保护哈希均核对一致。

## 完成的改动

1. **SPR 显示修正**：两个物理缓冲区使用同一份全局 FPS / SPR / MAX 快照，每 250 ms 更新一次，状态切换立即刷新。每个缓冲区在下次使用时更新到该快照，避免独立采样造成数字来回跳动。实际逐帧测量继续使用原始计数；统计行有正常的短暂采样延迟。
2. **v9：Alpha 连续供数**：在 `rtl/accelerator/alpha_blit_engine.v` 中独立维护送入与返回索引，连续向原有四像素运算流水线送数，按顺序收回结果。完成全部混合后才发写事务，并等待最终 B 响应完成；不增加 Alpha 算术单元。
3. **v10：增加 1 KiB 敌弹源图缓存**：缓存图集中 x=144、y=0 的 16×16 ARGB 敌弹，源物理地址 `0x01384240`、stride=2560。每行完整且成功读取 4 拍后才置有效；命中后省去该行源图 DDR 读取。裁剪、错误响应、非目标素材或 stride 不匹配按有效标记和原 DDR 路径处理。每次绘制仍读取当前 Back 的新背景，保证 Alpha 重叠效果。
4. **中间缓存使用片上 RAM**：源图、背景分段缓存采用不带数据复位的同步读口，并统一源数据与混合结果的写口，使工具能推断块 RAM，明显减少 XLR 占用。缓存内容无须清零，只复位有效标记。

源图缓存依赖既有素材封存和地址保护：图集封存后不能由 CPU 改写，平台复位才清除缓存有效标记。若以后支持运行时替换素材，必须同时实现缓存失效；当前版本保留封存生命周期。

## 构建结果

以下为各版本最终报告，core 仍为 100 MHz。资源变化不等同于游戏帧率提升。

| 版本 | XLR（总计 60,800） | RAM 块（总计 256） | DSP | core setup 裕量 |
|---|---:|---:|---:|---:|
| v8 原窗口版 | 55,496 / 91.28% | 169 / 66.02% | 46 | +2.150 ns |
| v9 连续供数 | 40,685 / 66.92% | 183 / 71.48% | 46 | +2.321 ns |
| v10 连续供数 + 源图缓存 | 41,148 / 67.68% | 190 / 74.22% | 46 | +2.463 ns |

v9 / v10 报告中最小 setup 或 hold 裕量均为 +0.026 ns。只读版本分别为 `0x00090000` / `0x000A0000`；能力值分别为 `0x1FFB` / `0x3FFB`。寄存器地址与既有显示保护不变。

## bit、ELF 与启动器配对

以下路径均相对于 `advanced_demo`；保留整个工程目录，启动器仍依赖根目录工具。

| 用途 | bit | ELF | 根目录启动器 |
|---|---|---|---|
| v8 软件基线 / 仅修 HUD | `output/campaign_game_window640/ti60f225_oob.bit` | `software/interactive_demo/build/game-window640-stress-opt/survival_game.elf` | `start_window_stress_optimized_debug.cmd` |
| v9 分离连续供数收益 | `output/window640_alpha_v9/ti60f225_oob.bit` | `output/window640_alpha_v9/survival_game.elf` | `start_window_stress_alpha_v9_debug.cmd` |
| v10 完整优化，建议先测 | `output/window640_alpha_v10/ti60f225_oob.bit` | `output/window640_alpha_v10/survival_game.elf` | `start_window_stress_alpha_v10_debug.cmd` |

三行使用同一份修正后的优化 ELF，可用于控制软件变量。**旧窗口 ELF 不支持 v9 / v10**；调试桥在写 RAM 前检查兼容标记并拒绝错误配对。每个新包内另有 `start_debug.cmd`、`manifest.json`、`SHA256SUMS.txt`、最终时序 / 资源报告和源码快照清单。

实板对照步骤：

1. 关闭 IDE Debug 和旧调试窗口，释放 JTAG。用 Efinity Programmer 经 JTAG 配置所选版本的 bit，再双击对应启动器，连接、加载并运行该包 ELF。只生成 bit 不会自动改变板上硬件。
2. 确认工具识别 v9 / v10，并观察 SPR 数字是否清晰。保持原素材和 Alpha 225，先应用 **48 架敌机 / 470 发敌弹**。
3. 等待 3–5 秒，连续测量 60 秒；测量期间不使用其他调试器读取板卡。导出完整报告，并记录版本、bit / ELF 哈希和实际 SPR 范围。
4. 同条件比较 v8、v9、v10 的最慢绘制、平均 / 最低秒窗 FPS、超 16.667 ms 帧、最大换帧间隔、重复旧帧及错误增量。不要把启动或切换负载的过渡窗口混入稳定区间。
5. 再测 48 / 480、48 / 512；若仍有余量，再按测量结果决定是否提高软件数量上限。敌弹目标数量与实际 SPR 不同，SPR 还包括敌机、玩家、己方弹和爆炸等实际绘制元素。

验收仍检查新增 underflow、missed、reader / 硬件错误为 0，连续稳定区间平均与最低秒窗接近 60 FPS、重复旧帧与超预算帧为 0。48 / 470 的既有实测作为参考，最终可承受负载由新的 60 秒报告确定。

## 已通过的验证及边界

- 六种 C 软件配置、HUD 像素对照与交错缓冲区统计采样检查；31 项调试桥 / GUI 测试、UART 与 Jim Tcl 离线检查。
- Alpha 算术：537 组 beat 向量、65,153 组 div255 输入；原串行与连续供数控制器的 AXI 反压、地址切段、读写错误、RLAST 与超时排空检查。
- 连续供数与缓存的四种开关组合：逐像素结果、缓存冷热行为、裁剪、stride 回退、无效读取不置有效、平台复位与目标背景更新。
- 共享显示集成：冷缓存填充、暖缓存源图 AR 为零、每次读取新 Back 背景、最终 B 前禁止换帧；60 个完整模拟显示帧、1,997,600 个像素、9 次换帧，underflow / missed 增量为 0。
- 队列顺序 / 满队列反压、窗口读写保护，以及默认全屏、原窗口、新优化窗口的顶层连接检查。

在带模拟 DDR 停顿的单个 16×16 精灵场景中，暖态耗时为：原路径 904 周期、连续供数 671 周期、连续供数加缓存 566 周期。这只说明该仿真场景的收益，不能换算为全游戏 FPS 或保证 512 发敌弹达标。

相关日志位于 `output/alpha_stream_cache_checks.log`、`output/alpha_cache_display_integration_checks.log`、`output/alpha_stream_queue_checks.log`、`output/alpha_window_protection_checks.log`、`output/alpha_optimized_top_checks.log` 与 `output/window640_stress_opt_software_checks.log`。最终构建日志为 `output/alpha_stream_compile.log` / `output/alpha_cache_compile.log`；`*_first_attempt.*` 是已停止的早期构建记录，不代表当前包状态。

复现入口：`scripts/build_window_stress_optimized_game.cmd`、`scripts/prepare_alpha_optimized_hardware.py --variant stream --flow compile` / `--variant cache --flow compile`、`scripts/package_alpha_optimized_game.py`。打包脚本核对最终编译状态、时序、源码快照、ELF 兼容与旧文件保护哈希。
