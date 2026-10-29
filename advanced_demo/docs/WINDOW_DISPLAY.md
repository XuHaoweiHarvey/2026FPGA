# 中央 640×480 独立硬件版本

HDMI 继续输出 1920×1080@60 Hz。中央窗口为 x=640..1279、y=300..779。
外围由硬件输出黑色，不作为正常显示的 DDR 读取区域。保留海岛、飞机、子弹和六帧爆炸图片，
以及 Alpha、Color Key、命令队列和双缓冲安全换帧。海岛保持原居中版取景，并非把整幅海岛重新缩放到窗口。

## 显示通路

1. `window_display_reader.v` 从 Front + 300×7680 + 640×4 开始读，
   每行读取 640×4 字节，再跳到下一行；每次 burst 不超过 128 拍且不跨 4 KiB。
2. 128 位异步 FIFO 把中央图像送到视频时钟域。
3. `window_axis_composer.v` 生成完整 1080p AXIS 时序的数据流。
   中央区域消费 FIFO，外围直接输出零；支持背压、帧首和行尾。
4. 原 CVO、64→24 位串行化和 HDMI 输出继续使用原 1080p 时序。

显存仍是两个 1080p 槽，地址 0 / 0x00800000、stride=7680。这样保留绘图器和素材源检查接口。
专用游戏只初始化两个槽的中央区域；上电 TPG 的一次全帧初始化、素材加载/封存与完整背景素材存储仍保留。
“外围不填充”指游戏帧和正常显示阶段，不代表彻底删除启动时所有整幅素材数据。

显示读流量由每帧 8,294,400 字节降为 1,228,800 字节；
60 Hz 时为 73.728 MB/s，降低约 85.2%。这不等于游戏 FPS 按同一比例提高，
游戏命令、Alpha 读改写、DDR 仲裁和帧边界仍有开销。

## 版本隔离及操作

| 用途 | bit | 启动命令 |
|---|---|---|
| 原全屏 v7 | `outflow/ti60f225_oob.bit` | `start_game_debug.cmd` |
| 原居中、整幅海岛 v7 | 同一原 v7 bit | `start_centered_game_debug.cmd` |
| 中央窗口、外围黑色 v8 | `output/campaign_game_window640/ti60f225_oob.bit` | 同目录 `start_window_game_debug.cmd` |

切换版本先关闭调试/串口占用，再经 JTAG 重新配置对应 bit，然后加载配套 ELF。
不需要写 Flash。加载工具会拒绝 v7/v8 误配，旧的全屏和居中 bit/ELF 未被覆盖。
交付包启动器依赖工程内的 `start_game_debug.cmd` 和 `tools/`。

## 重建与验证

在 `advanced_demo` 下运行，使用本机 Efinity Python；Icarus 的 bin 目录需在 PATH：

```powershell
$env:PYTHONHOME = 'D:/Efinity/python311'
cmd /c scripts/build_window_game.cmd
& 'D:/Efinity/python311/bin/python.exe' -B scripts/run_window_display_checks.py
& 'D:/Efinity/python311/bin/python.exe' -B scripts/run_rgb_checks.py --quick
& 'D:/Efinity/python311/bin/python.exe' -B scripts/prepare_window_hardware.py --compile
& 'D:/Efinity/python311/bin/python.exe' -B scripts/package_window_campaign_game.py
```

硬件脚本将工程复制到 `output/window640_hardware/`，只在副本中启用窗口参数。
默认顶层参数仍为 0。重新综合前若编辑了 RTL，应重新执行准备脚本，不能直接使用旧副本。
打包会检查 ELF 配置、素材符号、硬件快照、编译状态和最终 setup/hold 裕量，
保存 bit/ELF 的 SHA256 及完整时序报告。

仿真覆盖完整 1080p 中央/外围像素、跨行地址、4 KiB 边界、异步 FIFO、共享读、
持续有界写入、真实 CVO/串行化和安全换帧；同时回归原显示及 Alpha/Color Key/队列路径。
仿真内存模型不代表真实 DDR 控制器的最坏服务延迟。

2026-10-28 独立构建：map/interface/pnr/bitstream 全部通过；最终 core_clk setup
裕量 +2.150 ns，所有报告中的 setup/hold 关系裕量为正，最小 +0.026 ns。
XLR 55,496/60,800（91.28%），RAM 169/256（66.02%）。
新 bit SHA256 为 `0d81bc1ec99eb9a824d59d93f6e1e2cc3aacd8a1f07455dce48f5e6823269d79`；
完整 bit/ELF 哈希见交付包 SHA256SUMS.txt。原 v7 bit、全屏 ELF、旧居中 ELF 哈希已核对未变。

## 实板验收

选择“满负载场景”，保持 48 敌机、64 敌弹、Alpha 和 Color Key；应用无敌，
等待画面稳定后连续测量 60 秒，期间避免额外调试读取。
保存平均 FPS、最低秒窗、超预算帧、重复旧帧、underflow/missed/reader/硬件错误增量及完整报告。
本次编译通过不代表已经实测稳定 60 FPS，交付 manifest 默认标记尚未上板。
