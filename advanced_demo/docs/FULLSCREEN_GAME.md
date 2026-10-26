# 全屏海岛战役版

本版把原来的中央 640×480 测试区域扩展为 1920×1080，顶部保留 88 像素状态栏，
玩家可在状态栏下方移动到左右和底部边缘。队伍提供的海岛图作为固定背景，
不会按分数切换，也不参与障碍碰撞。飞机为 64×64，子弹为 32×32，爆炸为 64×64，
光晕截取中心 64×64 绘制；速度与中心命中区随素材放大，敌弹命中区为飞机中心 12×12。
受击后闪烁并有 900 ms 保护，机体中心标出白色命中点。

这仍使用实际硬件 Color Key 绘制飞机、Alpha 绘制子弹/光晕/爆炸；背景通过普通硬件
BLIT 恢复。玩法为标题页、三波敌机、90 HP 双阶段 Boss 和通关/失败结果页。
HUD 字形改由 Color Key 硬件绘制，并按物理缓冲槽缓存；常规渲染不再逐像素写 CPU 显存。

## 本轮怎么运行

旧 v6 bit 没有全屏背景和绘图命令队列能力。本轮新增 8 项命令队列，硬件版本升为 v7，
能力位用于区分配套固件。由于改动涉及 RTL，必须重新综合并配置 v7 bit，再加载配套 ELF。

1. 停止串口发送、断开调试窗口，退出 IDE Debug，释放 JTAG。
2. 在 Efinity Programmer 中通过 JTAG 配置重新综合生成的
   `advanced_demo/outflow/ti60f225_oob.bit`。
3. 等板卡硬件初始化完成后关闭 Programmer，重新打开
   `advanced_demo/start_game_debug.cmd`，让窗口重新读取新的 ELF。
4. 保持默认程序 `software/interactive_demo/build/game/survival_game.elf`，
   点击“连接 / 读取”，再点击“加载并运行 ELF”。连接旧程序时提示 ELF 不一致，
   可以继续加载；若提示缺少全屏背景或命令队列能力，先核对第二步是否用了 v7 文件。
5. 首次需要展开并读回校验整幅背景，初始化会比上一版慢。
   状态为“检查素材”时等待，进入“游戏中”后再测试移动。
6. 点击“一键自测”，读取 `self_test_result=0x0000000f` 后点击“进入游戏”，
   或在标题页用射击键开始战役。
   选实际板卡 COM 并开始发送：WASD/方向键移动，空格/Ctrl 射击，P 暂停。

日常重开和调参不用重复配置 bit 或加载 ELF。断电/重新配置 FPGA 后需重新加载 ELF。
修改图片或图集布局后仍需重新配置 bit，解除旧素材封存；单纯重开游戏不会解除封存。

配套版本位于 `output/campaign_game/`，含 bit、ELF、说明和 SHA256；
这两个文件也可以代替默认位置，不能混入旧包中的 bit 或 ELF。
本次默认程序显式使用 `GAME_FLASH_ENABLE=0`，无需先准备 Flash 素材。
上一版全屏 bit/ELF 另保存在 `output/campaign_validation/before_campaign/`，需要回退时配套使用。

## 画面与性能

源海岛图经过裁切、压暗至 55% 亮度、128 色量化，保存为 160×90，启动时按 12 倍
最近邻展开为 1920×1080。内嵌像素/调色板共 14,912 字节，以便程序、游戏状态与
8 KiB 栈一起放入现有 64 KiB OCRAM。它是像素风背景，未保留原图的全部细节。
处理后图片与复现方法见 [背景素材](../assets/team_background/README.md)。

两个物理显示槽分别记录自己上次绘制过的 16×16 区域。每次重用 Back 时，从封存背景
恢复对应区域，再绘制当前精灵和状态栏；首次使用、重开/离开自测后重新恢复整幅背景。
覆盖超过一半画面时改用整幅复制。恢复来源始终是独立背景，不从带有旧精灵的 Front 复制。
无 Flash 的默认游戏版会把相邻稀疏恢复块只在合并后能减少 32-beat 写 burst 时才连成一个矩形，
适度多复制一小块背景来省掉单独的短 DDR 写事务。Flash/Og 低资源构建保留简洁恢复路径。
默认游戏版还把健康寄存器检查合并到交换前/后，并保持每帧一次键盘轮询，避免每个精灵命令后
重复执行 APB 检查和 UART 轮询。

板上首次满载测量约 15 FPS，说明上一版的轻载优化没有解决繁忙绘制路径。当前无 Flash 软件版增加
了 60 秒区间内的命令提交/完成等待时间、绘图命令数、DDR 写节流和显示读停顿计数，用来区分
软件逐条提交开销与共享 DDR 服务等待。此次优化后的 ELF 尚未上板复测，因此稳定 60 FPS 仍未达标验证。请按
[常驻调试说明](RESIDENT_GAME_DEBUG.md)点击“满负载场景”和“连续测量 60 秒”，
检查最低秒窗、最慢绘制、命令累计提交/等待耗时、写节流/读停顿、最大换帧间隔、超预算帧和硬件错误计数。

## 硬件接口

- 新能力：`CAPABILITIES[9]` 全屏背景、`CAPABILITIES[10]` 命令队列；v7 读回 `0x000007fb`。
- 全屏背景物理地址：`0x02000000..0x027e8fff`，stride 7680，大小 `0x007e9000`。
  CPU 访问须加已有 `0x1000` 别名偏移。
- 沿用 `ASSET_CONTROL/STATUS` 的加载/封存流程。CPU 仅在有效 DDR 会话及素材加载期间
  可写，封存后只读；普通 BLIT 仅可读取封存背景中的合法、对齐矩形。
- Front/Back 写入权限、三张旧背景和精灵图集的边界保持原有规则。
  Color Key/Alpha 不允许将全屏背景当作精灵源。
- 全屏 ELF 含 `g_game_required_caps` 符号。桌面加载器检查 bit 能力后才写 RAM，
  固件启动时也检查能力，避免旧 v6 bit 被误认为兼容。

## 构建与回退

在 `advanced_demo` 下执行 `scripts/build_team_game.cmd`，用 `-O2` 构建并输出调试窗口默认的全屏常驻 ELF。
脚本显式设置 `GAME_FULLSCREEN=1`、`GAME_TEAM_SPRITES=1`、`GAME_FLASH_ENABLE=0`。
修改硬件后通过 Efinity 编译 `ti60f225_oob.xml`。

通用 Python 构建脚本默认启用 Flash。全屏 + Flash 模式仍从 ELF 展开海岛背景和精灵，
Flash 用于最高分/难度存档，启动仍检查原四条目素材包。只有 `GAME_FULLSCREEN=0`
才沿用三张 Flash 背景的绘制流程；Flash 包格式没有在本次扩展。

需要重建旧小区域版时，加 `--define GAME_FULLSCREEN=0`；需要原程序素材再加
`--define GAME_TEAM_SPRITES=0`，Flash 开关独立设置。旧版 bit 和用户已测试的旧 ELF
配套备份在 `output/fullscreen_validation/before_fullscreen/`。回退时配套使用其中的
`ti60f225_oob.bit` 与 `game/survival_game.elf`。

## 本机验证（2026-10-24）

Efinity 2026.1.132 完成 map/interface/pnr/pgm，生成新 bit；最终报告中最小 setup slack
为 +0.361 ns，最小 hold slack 为 +0.026 ns，core_clk setup 为 +0.830 ns。
这些是静态时序结果，不是实际游戏帧率。

游戏 C 检查覆盖全屏/小区域、三波与双阶段 Boss、结果重开、100 秒满负载模拟、
硬件字形缓存和 HUD 裁切、十张精灵解码、背景像素参考哈希、边缘裁切、恢复区域合并、
两物理槽交替恢复及整幅回退；UART 协议和适配器、22 项桌面检查、OpenOCD Jim Tcl
离线解析通过。硬件回归覆盖背景源边界、加载/封存/会话权限及旧模式拒绝新窗口，
并验证普通复制、Alpha 和显示/CPU 共享通路。各脚本结果以本机验证输出为准。

全屏常驻默认使用 O2，Flash 组合沿用 Og（O2 会超出 OCRAM）；小区域/原素材路径保留。
所有构建检查加载段和 8 KiB 栈均在 64 KiB OCRAM 内，并为调试器保留顶部 1 KiB。
保留原有裸机单段 RWX 链接告警；不要给 Flash 组合直接套用默认常驻版的 O2 参数。
本次编译和离线检查不替代板上自测、输入、像素和性能验收。

本轮日志在 `output/campaign_validation/`：`interactive_checks.log`（含 22 项桌面检查）、
`alpha_checks.log`（含 16×8 边缘区域的真实 DMA）、`build_matrix.txt`（六种构建）。
确认这些检查通过后，可运行 `python -B scripts/package_campaign_game.py` 重新整理本机交付包。
