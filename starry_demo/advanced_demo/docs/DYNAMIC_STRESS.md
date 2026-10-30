# 动态调整中央 640×480 游戏压力负载

这是独立的软件压力测试版本，继续使用现有中央窗口 v8 bit，保留已验收版本的 bit、ELF 和原有图片。HDMI 仍为 1920×1080@60 Hz，中央游戏区为 640×480。

另有保留 HUD、减少背景恢复量的对照版本，使用 `start_window_stress_optimized_debug.cmd`，详见 [背景与 HUD 优化版](WINDOW_STRESS_OPTIMIZATION.md)。本页原启动入口继续使用原压力 ELF。

## 启动一次，以后直接改数量

1. 板上已运行中央窗口 v8 bit 时，无需重烧 bit。若板上还是全屏 v7，先使用 `output/campaign_game_window640/ti60f225_oob.bit` 配置 FPGA。
2. 结束 IDE 的 Debug、关闭旧调试窗口，双击工程根目录的 `start_window_stress_debug.cmd`。
3. 窗口已自动选择 `software/interactive_demo/build/game-window640-stress/survival_game.elf`。点击“连接 / 读取”，再点击“加载并运行 ELF”。刚连接时提示板上程序与新 ELF 不一致，是尚未加载新程序的提示。
4. 等待素材初始化完成、画面出现。只需加载这份 ELF 一次；本次运行内调整数量无需重新编译、加载 ELF 或烧录 bit。
5. 在“压力敌机”填 1–48，在“压力敌弹”填 1–512，点击“应用压力负载”。例如 `48 / 128`。界面确认命令后，状态栏会显示当前负载。

数字按钮 64、128、256、384、512 只填写敌弹输入框，需要再点“应用压力负载”才会改变板上场景。也可以自行输入 96、160、192、224 等整数。

每次应用会重新开始压力场景，启用无敌、自动射击，持续补充指定数量的敌机和敌弹。图片、尺寸、Color Key、Alpha 绘制路径保持原配置；上方普通“应用”按钮用于更改子弹 Alpha 等选项。压力敌弹数量由新输入框控制，“敌弹间隔 ms”不是敌弹数量。

“满负载场景”按钮始终恢复原来的 48 敌机 / 64 敌弹。“重开”或“进入游戏”返回关卡。旧 `start_window_game_debug.cmd` 继续加载原来的稳定窗口 ELF，全屏启动入口也保留。

## 找到稳定 60 FPS 的数量上限

固定 48 架敌机，依次试 64、128、256、384、512 发敌弹。每次应用后等 3 秒，点击“连续测量 60 秒”，结束后导出日志。测量期间不能切换数量、读取状态或重开。

首次掉帧后，在上一档与失败档之间继续缩小范围。例如 128 达标、256 不达标，接着测 192，再测 160 或 224。临界配置建议重复测量，记录可重复通过的最高档。

每档保持相同的素材、尺寸、Alpha 值和操作方式。建议停止键盘发送、让压力场景自行运行，使不同档位更容易比较。

日志包含：

- 本轮设定的敌机数、敌弹数。
- 60 秒内实际提交绘制的敌机、敌弹数量范围，经过窗口裁剪的对象才计数；这不是非透明像素覆盖或肉眼可见对象的统计。
- 总 Sprite 范围，还包含玩家、玩家子弹、光晕和爆炸，不能直接等于“敌机 + 敌弹”。
- 平均 FPS、最低秒窗 FPS、超预算帧、重复旧帧、underflow、missed 及硬件通路计数。

以平均和最低秒窗接近 60 FPS、重复旧帧及超预算帧为 0、新增 underflow / missed / reader / 硬件错误为 0 作为通过标准。512 只是这份测试软件的敌弹容量，实际能稳定 60 FPS 的上限需要实板测出。

## 文件与验证

- bit：`output/campaign_game_window640/ti60f225_oob.bit`，沿用已验收的 v8。
- 新 ELF：`software/interactive_demo/build/game-window640-stress/survival_game.elf`。
- 新启动入口：`start_window_stress_debug.cmd`。
- 重编译入口：`scripts/build_window_stress_game.cmd`。
- 本机软件回归：`scripts/run_interactive_checks.cmd`。
- 构建及软件回归日志：`output/window640_stress_build.log`、`output/window640_stress_software_checks.log`。

已完成独立 ELF 构建、OCRAM / OpenOCD 保留区边界检查，以及动态增减、非法数量拒绝、测量期间锁定、裁剪计数、原版兼容和 GUI 输入的离线测试。新增负载档位尚未实板验收。本次没有配置 FPGA 或写入 Flash；没有重新综合 Verilog，也不会增加 FPGA 的 XLR 占用。
