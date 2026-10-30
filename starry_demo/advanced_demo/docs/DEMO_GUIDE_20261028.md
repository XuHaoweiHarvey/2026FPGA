# 2026-10-28 队内演示：bit、ELF 与 CMD 配对

核对日期：2026-10-27。工程根目录：C:/Users/Xuhaowei/Desktop/2026FPGA/2026FPGA。
本说明整理现有产物；没有重新编译、改动固件、烧录板卡或验证现场效果。

## 推荐配对

表中路径相对工程根目录。先用 Efinity Programmer 通过 JTAG 配置 bit，再从对应入口加载 ELF。CMD 本身不会配置 FPGA。

| 用途 | bit | CMD / 启动入口 | 实际 ELF |
|---|---|---|---|
| 主展示：居中海岛素材版 | advanced_demo/output/campaign_game_centered/ti60f225_oob.bit | 双击同目录 start_centered_game_debug.cmd | 同目录 survival_game.elf |
| 保存的 30 FPS 基线候选产物 | advanced_demo/output/performance_baseline_20261026_30fps/ti60f225_oob.bit | 双击同目录 start_centered_game_debug.cmd | 同目录 survival_game.elf |
| 全屏海岛战役版 | advanced_demo/output/campaign_game/ti60f225_oob.bit | advanced_demo/start_game_debug.cmd，加 --elf 选择该包 ELF，见下面命令 | advanced_demo/output/campaign_game/survival_game.elf |

以上三个目录的 bit 经 SHA-256 核对完全相同，均为 v7；前两项 ELF 也相同，是同一版本的两份保存。居中版 HDMI 仍输出 1920×1080@60 Hz，游戏区为中央 640×480，外围保留海岛图片。全屏版使用不同尺寸的图集与全屏游戏区。

PowerShell 启动全屏版：

    Set-Location 'C:\Users\Xuhaowei\Desktop\2026FPGA\2026FPGA\advanced_demo'
    & .\start_game_debug.cmd --elf 'C:\Users\Xuhaowei\Desktop\2026FPGA\2026FPGA\advanced_demo\output\campaign_game\survival_game.elf'

源码目录的 advanced_demo/start_centered_game_debug.cmd 选择 software/interactive_demo/build/game-centered/survival_game.elf，当前与居中交付 ELF 一致。现场优先从 output 包内脚本启动，明确选择保存好的演示产物。

## 建议现场顺序

1. 连接板卡电源、HDMI、JTAG 与 UART；停止其他串口发送和 IDE Debug，断开已有游戏调试连接。
2. 在 Efinity Programmer 中通过 JTAG 临时配置居中包内的 v7 bit；完成后退出 Programmer，释放 JTAG。
3. 双击居中包内 start_centered_game_debug.cmd，核对窗口 ELF 是同目录文件，点击“连接 / 读取”，再点击“加载并运行 ELF”。仅连接不会加载程序。等待背景与图集初始化完成。
4. 点击“一键自测”，检查 self_test_result=0x0000000f，代表 FILL、Color Key、Alpha、Swap 四项通过。若结果不同，保存日志，不宣称通过。
5. 点击“进入游戏”，刷新串口并选择本板实际 COM 口，点击“开始发送”。WASD/方向键移动，空格/Ctrl 射击，P 暂停。展示队伍飞机、子弹、爆炸、海岛背景及战役；正常战役与固定压力场景分开介绍。
6. 点击“满负载场景”，等画面稳定约 3 秒，再点击“连续测量 60 秒”。窗口约 62 秒后读取结果，期间不做额外 JTAG 读取、调参或 IDE 暂停。记录平均、最低秒窗、绘制时间、重复帧及错误增量，导出完整日志。
7. 展示全屏效果时：停止发送、断开并关闭调试窗口，重新配置同一个 v7 bit，退出 Programmer，然后运行上面的全屏命令并加载对应 ELF。全屏与居中图集布局不同，切换前重配 bit 以清除素材封存。

同一版本日常“重开”不需要重新配置 bit。断电或重新配置 FPGA 后需要重新加载 ELF。演示前建议完整走一遍操作，现场测量值以实际导出为准。

## 旧版本与可选演示

| 用途 | bit | 配套程序 / 操作 | 限制 |
|---|---|---|---|
| 基础 M2：CPU/FPGA 矩形和图片对照 | basic_demo/outflow/ti60f225_oob.bit | IDE 加载 basic_demo/software/apb_reg_test/build/m2_demo.elf；当前 basic Launch 指向它 | 没有游戏启动 CMD。历史 M2 有实板验收，但当前这对文件缺完整板端哈希溯源；先单独试跑再加入演示。文档中的另外两个 M2 输出路径当前不存在。 |
| 旧独立 v6 Alpha 图形演示 | advanced_demo/output/share/alpha_v6_board_package/ti60f225_oob.bit | IDE 加载同目录 advanced_demo.elf | 没有游戏窗口启动 CMD；包内 README 标记未实板验证。当前游戏自测已能展示 Alpha，现场可不切旧包。 |
| 旧 UART 键盘游戏封存包 | advanced_demo/output/board_ready/advanced_uart_20261023_e99e4e6/bit/ti60f225_oob.bit | refresh_debug.cmd 刷新本地 IDE 路径，再用包内 IDE 工程加载 ide_project/firmware/survival_game.elf | 是旧游戏，不能用来展示当前完整队伍素材与战役。 |
| 旧 v6 全屏版 | advanced_demo/output/fullscreen_game/ti60f225_oob.bit | 同目录 survival_game.elf | 不是当前 v7 战役包，不要搭配当前需要 v7 队列的 ELF。 |

根目录 outflow/ti60f225_oob.bit 是另一份历史产物，本轮未确认其演示配套，不用于主展示。advanced_demo/output/toolchain/m2/m2_demo.elf 也不能仅因名字相同就搭配 basic bit。

## CMD 的用途

- start_game_debug.cmd：打开调试窗口，默认全屏 ELF，可用 --elf 显式选程序；不会配置 bit。
- start_centered_game_debug.cmd：打开调试窗口并预选居中 ELF；不会配置 bit。
- scripts/build_team_game.cmd：重新编译全屏游戏软件，会更新构建输出；不是演示启动命令。
- scripts/build_centered_game.cmd：重新编译居中游戏软件；不是演示启动命令。
- scripts/run_interactive_checks.cmd：本机回归检查；不是运行板卡游戏。
- refresh_debug.cmd：刷新旧包的 IDE 路径；不是一键烧录/运行。
- open_efinity_with_java.cmd：打开 Efinity 工具；不是选择某个演示固件。

## 版本身份与展示口径

| 文件 | SHA-256 |
|---|---|
| 当前 v7 bit（三份推荐包相同） | d7ef3315036f4c52816b2486d4ace5b0b707ba2bb0e2c525cb0f5ddf79e12257 |
| 居中素材 ELF / 30 FPS 基线候选 ELF | 12d1c7a92bbe88f492df827d3f55817b4b5f745fd5781c5ebd40f24193bfce88 |
| 全屏战役 ELF | 229c0e6f7e792bff45622e24a4daaec101a10c1e1b14eeae18349d6d8a1a5f9d |
| 本机 basic bit | c6731cadc745adb0a72b0d9d512ae02c84727c6cfbffe726af953df5c006fa86 |
| 本机 basic M2 ELF | ee8f2cb5748e1b1abde6caedd81eabfba268dab062fc5c4aa6a3b5a87efaa3a1 |

2026-10-26 截图报告：居中满载区间平均/最低秒窗为 30.00/30.00 FPS，精灵范围 111–120，新增 underflow/missed 为 0。截图没有记录加载产物哈希，当前本机候选文件与截图板端身份尚未完全核实，manifest 的未验收标记保持原样。HDMI 的 60 Hz 与游戏更新帧率分开介绍；48 敌机/64 敌弹满载稳定 60 FPS 仍未达成。

建议介绍：已经实现 CPU 控制、FPGA 绘图、海岛与队伍素材、Color Key、Alpha、双缓冲安全换帧及互动战役；居中满载已有稳定 30 FPS 的 60 秒截图记录，下一步优化背景/HUD 重复工作及 DDR 写事务服务，冲刺满载 60 FPS。

包内 CMD 依赖完整 advanced_demo/start_game_debug.cmd、tools/ 与本机 Efinity Python/IDE。单独复制 bit、ELF 和 CMD 到另一台电脑，不能视为独立便携包。
