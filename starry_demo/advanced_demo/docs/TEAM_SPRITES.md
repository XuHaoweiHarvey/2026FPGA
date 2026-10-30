# 队伍素材版操作说明

本版在常驻调试游戏上接入红蓝玩家飞机、朝下的紫色敌机、绿色玩家子弹、红色敌弹，
以及六帧爆炸/烟雾。当前默认已扩展为全屏海岛背景，保留已有移动、射击、波次、计分、生命、
敌方弹幕、暂停、自动重开、参数调整、自测与测量流程。

飞机由硬件 Color Key 处理透明背景；子弹、光晕、爆炸由硬件 Alpha 混合。
爆炸每帧 70 ms，总计 420 ms，同时按剩余时间淡出；暂停会冻结动画进度。
小图内嵌到 ELF，启动时在受保护的 CPU DDR 会话中展开、读回校验并封存图集。
素材与生成方法见 [素材目录](../assets/team_sprites/README.md)。

**当前为带 Boss 的战役版，配套 bit、ELF 和步骤以 [全屏版说明](FULLSCREEN_GAME.md) 为准。**
本页原小图尺寸在全屏中放大两倍；小区域模式仍可通过构建参数保留。

## 第一次使用新素材

1. 停止串口发送，断开调试窗口，结束 IDE Debug 并释放 JTAG。
2. 在 Efinity Programmer 中通过 JTAG **配置本次新生成的全屏背景位流**：
   `advanced_demo/outflow/ti60f225_oob.bit`。旧 UART/Alpha/Color Key v6 bit 不支持全屏背景；
   本机新 bit 已编译完成，不需要再综合 FPGA。
   这是为了解除旧图集的硬件封存；只点“重开”或只下载新 ELF 无法替换旧图集。
3. 等硬件初始化完成并关闭 Programmer，重新打开 `advanced_demo/start_game_debug.cmd`。
   若窗口此前已连接，也应先关闭重开，让工具重新读取新的 ELF 文件。
4. 使用默认 `software/interactive_demo/build/game/survival_game.elf`，
   点击“连接 / 读取”，再点击“加载并运行 ELF”。等待初始化完成后读取状态。
   本次准备的默认 ELF 使用 `GAME_FLASH_ENABLE=0`，不依赖 SPI0 或 Flash 素材。
5. 确认画面后，先点击“一键自测”；预期 `self_test_result=0x0000000f`，
   再点击“进入游戏”。选择实际板卡 COM 口并开始发送，测试移动和射击。
6. 击毁敌机时观察爆炸；暂停时观察动画是否停止，继续后应接着播放。
   可以把“子弹 Alpha”依次设为 0、128、255 并点击“应用”，观察硬件透明度变化。
   想长期观察可应用无敌模式。

同一份图集正常初始化后，重开、调参和自测无需重新加载 bit 或 ELF。
断电/重新配置后要加载 ELF；以后再次更换图集内容时，需要再次配置 bit。
若看到 `0xea03`，先检查是否仍封存着旧素材；新窗口也会显示对应说明。
按上述步骤重新配置后仍失败，应导出日志定位。

旧默认构建文件已备份在本机忽略目录
`output/team_sprites_validation/before_team_sprites/`，包含旧 ELF、map、bin、hex 等。
回退到旧图集同样需要重新配置兼容 bit。这些构建输出不会随普通 Git 推送上传。

## 重新构建

在 `advanced_demo` 下运行：

```powershell
.\scripts\build_team_game.cmd
```

脚本依次寻找 D 盘/C 盘的 Efinity 2026.1 IDE，也可传入实际安装路径：

```powershell
.\scripts\build_team_game.cmd 'D:\Efinity\efinity-riscv-ide-2026.1'
```

它显式构建全屏海岛背景的常驻素材版，输出到调试窗口默认位置。编译完成不操作板卡。
其他 Python/工具安装布局可以直接调用：

```powershell
python -B scripts/build_apb_software.py --program game --opt O2 --ide-root 'D:/Efinity/efinity-riscv-ide-2026.1' --define GAME_FLASH_ENABLE=0 --define GAME_TEAM_SPRITES=1 --define GAME_FULLSCREEN=1
```

直接调用通用构建脚本时，省略 `GAME_FLASH_ENABLE=0` 仍会启用队友的 Flash 版本，
需要兼容 SPI0 的位流和预先准备的 Flash 数据。全屏启用 Flash 时，存档走 Flash，
背景和精灵均从 ELF 展开；小区域模式才读取原有三张 Flash 背景。
Flash 表格式保持四个条目，第四个旧图集条目不用于新素材。
需要完整旧素材路径时加 `--define GAME_FULLSCREEN=0 --define GAME_TEAM_SPRITES=0`。
Flash 操作见 [Flash 交付](FLASH_DELIVERY.md)。

## 验证记录（2026-10-24）

- 生成头文件与十张 PNG 一致；C 测试逐像素解码并核对独立参考哈希，检查 Color Key
  透明区、实体轮廓及分级 Alpha。
- 动画逐毫秒检查六帧边界、Alpha 单调淡出、到期隐藏、暂停恢复和 32 位计时回绕。
- `scripts/run_interactive_checks.cmd` 通过：游戏逻辑、UART 协议/适配器、19 项桌面调试
  检查及真实 OpenOCD Jim Tcl 配置解析；硬件操作已替换为空操作。
- 新素材/旧素材分别与 Flash 开/关组合，四种 RISC-V 构建通过；包含 8 KiB 栈的
  加载段均在 64 KiB OCRAM 范围内。构建保留现有裸机单段 RWX 链接告警。
- 上述结果为离线验证，本次没有操作板卡或写 Flash；实际像素、自测、输入和持续帧率
  需按上面的步骤上板确认。
