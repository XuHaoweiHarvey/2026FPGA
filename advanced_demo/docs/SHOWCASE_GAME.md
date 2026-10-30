# 紧凑战役与 v11 两倍显示交付（2026-10-29）

新展示版已经实现三波各 7 秒、移动 Boss、命中爆炸、击毁演出和 VICTORY。
新 v11 bit 已完整编译并通过最终 setup / hold 检查；仿真和主机测试已通过。
**板端验证仍待用户完成**，不能把主机逻辑测试、画面预览或静态时序当作板上帧率和稳定性结果。

## 先运行

1. 关闭占用 JTAG 的 IDE Debug、旧调试窗口和 Programmer。
2. 使用 Efinity Programmer 配置 `output/showcase_v11/ti60f225_oob.bit`，完成后退出 Programmer。
3. 双击 `output/showcase_v11/start_debug.cmd`，连接，再点击“加载并运行 ELF”。
4. 等待素材检查完成。在调试窗口选实际板卡 COM 口并开始发送键盘输入。
   标题页按空格或 Ctrl 开始；WASD / 方向键移动，P 暂停。
5. 也可点击“演示战役”直接从第一波开始。三条生命、得分和失败重开均保留。

展示版改变了运行时图集和背景映射。**首次换用展示 ELF，或从展示版切回压力 ELF，都须先重新配置匹配 bit**，清除素材封存与敌弹源缓存；仅重置 CPU 不会清除。
没有连接或配置任何板卡，也没有写 Flash。

若 v11 板端未通过验证，使用 `output/showcase_v10_fallback/` 内的旧 v10 bit 和同一展示 ELF。
该版本呈现中央 640×480，游戏流程完全相同。原 `output/window640_alpha_v10/` 及原 512 敌弹压力 ELF 均保留。

## 流程和操作约定

| 环节 | 实现 |
|---|---|
| 三波战机 | 每波 7000 ms，提示包含在内；依次为直线、横移、三路扇形射击；默认同时最多 6 / 8 / 10 架 |
| Boss 入场 | 约 1000 ms 的 WARNING；清除前一波敌机与子弹；入场保护期间不能扣血或刷命中分 |
| Boss 动作 | 5000 ms 周期，前 3000 ms 左右移动、后 2000 ms 停留；移动时发射间隔加倍 |
| Boss 阶段 | 60 HP；40 / 20 HP 时切为 CROSSING FANS / RING BURST，首阶段 ROTATING ARMS；命中当帧清弹，预警 500 ms |
| 命中 | 在碰撞点放置 16×16、120 ms 的六帧爆炸；从原 32×32 图集抽样，绘制顺序在 Boss 上方 |
| 击毁 | 最后一击立即停战、清战斗对象；8 槽固定效果池优先容纳击毁效果；约 0 / 125 / 250 / 375 ms 连续引爆，800 ms 后结算（16 ms 步进取整） |
| 结算 | 中央 VICTORY、分数、FIRE TO RESTART 每帧重绘；至少 3000 ms 后松开并再按射击才重开；失败页等待至少 500 ms 后松开再按 |
| 暂停 | 冻结波次、Boss 动作、预警、发射、无敌期、命中特效和击毁计时；保留剩余时间 |
| 无敌 | 默认关闭；只能通过显式调试选项开启，HUD 显示 INV；切换战役保留已接受的该选项 |

实际击败 Boss 才能通关，没有按时间自动获胜。主机测试用跟随 Boss 的控制器持续开火、显式开启调试无敌，三轮均为 **46.144 秒**；这验证流程目标，不代表真人无敌关闭时的通关时间或板端表现。

完整海岛在上传时适配到展示版的 640×480 窗口；保留原素材文件、显存地址和步长。
压力对照 ELF 不使用该适配或新的命中特效图集，保持原压力场景素材与补充规则。

## 配套文件

| 文件或入口 | 用途 |
|---|---|
| `output/showcase_v11/` | 新 v11 bit + 展示 ELF + 相同对照 ELF + 证据、哈希和启动器 |
| `output/showcase_v10_fallback/` | 保留的 v10 bit + 同一展示 ELF，回退交付 |
| `start_showcase_debug.cmd` | 从源码构建目录启动展示版 |
| `start_showcase_benchmark_debug.cmd` | 从源码构建目录启动 512 敌弹对照版 |
| `software/interactive_demo/build/game-showcase/` | 展示构建，敌弹容量 256 |
| `software/interactive_demo/build/game-showcase-benchmark/` | v10 / v11 共用的独立压力构建，敌弹容量 512 |
| `output/showcase_v11/SHA256SUMS.txt` | 包内全部文件的 SHA256 |
| `output/showcase_delivery_20261029.zip` | 包含两版、原 v10 压力包、调试工具和源码快照的交付 ZIP |

交付 ZIP 解压后保留目录结构。调试器需本机 Efinity Python / Tkinter、RISC-V IDE / OpenOCD 和驱动；启动器默认使用本机 `D:\Efinity`，其他电脑按实际安装路径调整。
包内 manifest 的 `board_tested=false`、`stable_60_fps_measured=false` 在本次交付中保持不变。

## 硬件和兼容接口

核心保持 100 MHz，HDMI 保持 1920×1080@60 Hz。
绘制与 DDR 源窗口保持 `(640,300,640,480)`、stride 7680。
v11 使用两条源扫描行缓存，把每个像素和扫描行各复制一次，呈现为 `(320,60,1280,960)`；外围为黑色。
每输出帧仍读取源图一次，即 76,800 个 128-bit beat / 1,228,800 字节；60 Hz 下约 73.728 MB/s。
不是把帧缓冲改成 1280×960，也不是更改 CPU 主频。

v11 VERSION=`0x000B0000`，CAPABILITIES=`0x00007FFB`，新增 bit14；新展示及对照 ELF 均支持 v10 / v11。
旧优化 ELF 不支持 v11，加载器在任何 RAM 写入前拒绝不匹配；v10 / v11 的版本与能力标记必须一致。
默认工程参数仍是 v7；新 bit 从独立快照 `output/showcase_v11_hardware/` 编译，原 v10 不被覆盖。

原调试控制、状态邮箱结构、编号 1–9 和 APB 偏移均保留；新增命令 **10：演示战役**。
可选符号 `g_game_presentation`（magic `0x47505231`）扩展显示几何、战役状态和测量信息。
其字段依次为 17 个 uint32：`magic publication scale display_x display_y display_width display_height showcase state boss_phase boss_moving first_boundary last_boundary presentation_intervals missing_boundaries max_boundary_gap`。
publication 奇数表示发布过程中；旧 ELF 没有该符号仍可读取原状态。
战役 state：1 波次，2 入场，3 Boss，4 击毁，5 胜利，6 失败；标题和压力场景为 0。

原始重复帧计数保留。同时记录相邻完成呈现时读到的显示边界差：首样本只作基准，之后统计间隔、超过 1 的边界差与最大差，支持 uint32 回绕。
若原始计数为 1，而相邻边界差始终为 1，应结合两个测量端点解释；若存在边界差大于 1，则确有相邻呈现跨边界的证据。
这是完成交换后由 CPU 采样的边界，不是逐像素 HDMI 探针；不要仅凭端点差断言丢帧。

## 已完成的本机验证

| 检查 | 结果 |
|---|---|
| 缩放小尺寸 scoreboard | 每像素、黑边、随机 FIFO 停顿 / 输出背压、连续三帧、在途读取时复位 / 帧消隐、精确读取量通过 |
| 完整 1080p | 原窗口与两倍窗口各两帧，随机 AXIS ready 和真实 CVO / HDMI 两种路径均通过；每帧 76,800 beat，DDR 争用和安全换帧通过 |
| 原硬件保护 | 读帧 guard、窗口 guard、读写准入、异步换帧、Alpha 流水 / 缓存与错误路径回归通过 |
| 新逻辑 | 波次、32-bit 时间回绕、移动边界、停留、阶段切换、命中位置 / 扣血 / 到期、暂停、池满、同帧多发最后一击、800 ms 退场、胜负重开通过 |
| 真实绘制命令 | 主机栅格化验证六帧小爆炸、图层顺序、HP 条、两缓冲连续 VICTORY 像素、测量端点及回绕；PNG 为此方式生成，非板端截图 |
| 主机持续运行 | 实际碰撞三轮通关；另以不射击且显式无敌的方式运行 600 秒，Boss 不会按时间自动消失；不是板端十分钟验收 |
| 调试工具 | 35 项测试通过，含 v10 / v11 正反配套、命令 10、可选扩展及旧邮箱；真实 OpenOCD Jim Tcl 离线语法通过 |
| 交叉构建 | 两个独立 RV32 ELF 编译通过；程序、BSS 与 8 KiB 栈均在 OCRAM 且避开末尾 1 KiB OpenOCD 保留区，精确地址见 manifest |
| v11 完整编译 | map / interface / pnr / bitstream PASS；core setup +2.283 ns，最小 setup +0.247 ns，最小 hold +0.026 ns |
| v11 资源 | XLR 41,003 / 60,800（67.44%），RAM 198 / 256，DSP 46 / 160；缩放模块推断 8 个 RAM block |

完整日志、源码摘要、时序与资源报告随包保存；旧 bit、ELF 和两份原素材头文件通过 SHA256 确认未改变。
既有 Icarus constant-select 提示、旧 testbench 端口 / timescale 提示、Efinity IV 提示和链接器 RWX 段警告保留在原始日志内，未影响通过结果。

## 用户板端验收

- [ ] v11 显示窗口恰为 1280×960 @ (320,60)，边缘无错行、花屏、残影；调试窗口显示“渲染 640×480 / 显示 1280×960”。
- [ ] 默认无敌关闭，三条生命；三波提示计入七秒，Boss 移动 / 停留 / 三阶段、命中和血条一致。
- [ ] 暂停后恢复，预警和特效不被跳过；Boss 最后一击后无敌机、敌弹、伤害或再次生成。
- [ ] 连续三轮通关，击毁爆炸完整，VICTORY 至少三秒，持续按射击不重开，松开再按才重开。
- [ ] 板端连续运行十分钟，记录输入、显示、硬件错误和异常现象。
- [ ] v10 / v11 各运行同一 `benchmark.elf`，48 架 / 470 发、Alpha 225，各三轮 60 秒。切换展示 / 对照时先重新配置 bit。
- [ ] 每轮平均 ≥59.9 FPS，完整秒窗 ≥59，最慢绘制 ≤14 ms，绘制超预算为 0，underflow / missed / 硬件错误无新增。
- [ ] 每轮分别导出窗口 JSON 原始日志，保留 repeated_frames、相邻边界间隔、最大换帧间隔；核对端点差与真实呈现间断，保存相同 ELF SHA256。
- [ ] 保存一段完整三波 → Boss → VICTORY 的演示录像，记录 bit / ELF 哈希、板卡版本、显示器、COM 与测量日期。

建议文件名：`v10_48_470_alpha225_run1.json` 至 run3、`v11_48_470_alpha225_run1.json` 至 run3。
测量时只开一个调试窗口，应用负载后等待 3–5 秒，点“连续测量 60 秒”；窗口等约 62 秒再读结果，期间不要用其他调试器读取板卡。
若第二天结束前 v11 未完成时序和板端检查，第三天直接交付 v10 回退版；v11 单独保留并注明未验收。

## 本机重建

在 `advanced_demo` 中运行：

```powershell
$env:PYTHONHOME='D:\Efinity\python311'
$showcasePython='D:\Efinity\python311\bin\python.exe'
& $showcasePython -B scripts/build_showcase_game.py
& $showcasePython -B scripts/prepare_showcase_hardware.py --compile
.\scripts\run_showcase_checks.cmd
.\scripts\run_interactive_checks.cmd
& $showcasePython -B scripts/run_window_display_checks.py --scale2
& $showcasePython -B scripts/run_alpha_checks.py
& $showcasePython -B scripts/package_showcase_game.py
```

硬件全分辨率仿真耗时较长。仅重跑快速缩放 / guard / 换帧单元时可加 `--units-only --scale2`。
打包脚本在源码与编译快照、RAM、时序、旧包保护摘要或验证日志不匹配时拒绝封装；不会修改旧包或启动板卡。
