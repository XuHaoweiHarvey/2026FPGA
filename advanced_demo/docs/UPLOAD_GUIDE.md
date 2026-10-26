# 2026-10-26 阶段版本上传说明

本页替代此前的 20 文件上传清单。Flash 合并已在 `8221b43` 完成；本轮是该提交之后的
v7 绘图命令队列、队伍素材、全屏/居中配置和 30 FPS 性能交接，不再沿用旧提交标题与清单。
仓库：`C:\Users\Xuhaowei\Desktop\2026FPGA\2026FPGA`，当前分支 `main`。
本次整理只更新说明，没有执行暂存、提交或推送。

## 可直接复制到 GitHub Desktop

Summary：

```text
advanced_demo：加入v7绘图队列与居中素材版，记录满载30FPS基线
```

Description：

```text
加入 v7 的 8 项硬件绘图命令队列及配套软件接口，帧末统一排空，保留显示优先和双缓冲保护。
接入队伍飞机、子弹、六帧爆炸和海岛背景，保留三波敌机、Boss 与固定压力场景。
新增独立中央 640×480 构建；HDMI 仍输出 1920×1080@60 Hz，原全屏 ELF 独立保留。
修复居中模式丢失海岛背景的问题，补充专用启动、构建和打包脚本及素材核对。
增加构建配置快照、冻结的60秒测量结果及通路诊断，更新回归与使用文档。

用户提供的60秒实板报告：48敌机/64敌弹压力场景，平均和最低秒窗均为30.00 FPS，
精灵111–120，最慢绘制27.134 ms，重复旧帧1800次，区间新增underflow/missed为0/0。
截图与人工摘录已归档；原始导出JSON和板上文件哈希匹配仍待补齐。
主机游戏/UART/调试检查及交叉编译通过；满载60 FPS尚未达标，本次为可复现的阶段基线。

后续优先评估居中版HUD缓存、损伤区域恢复及短写事务准入，保持素材与48/64压力基线。
```

## 本次应上传的文件

按当前工作区，相关范围是 `advanced_demo/` 下未被忽略的改动及新增文件，以及
`docs/evidence/game_perf_20261026/`。检查时共82个文件；后续数量可因实际修改变化，
应以路径与内容判断，不为凑数勾选。

| 类别 | 本轮需纳入 |
|---|---|
| RTL与工程 | `advanced_demo/rtl/` 中的相关改动、新增 `graphics_command_queue.v`；`advanced_demo/ti60f225_oob.xml` |
| 游戏与API源码 | `software/interactive_demo/` 的 C/H、`software/apb_reg_test/` 的相关 API/寄存器/benchmark 头文件 |
| 素材 | `assets/team_background/`、`assets/team_sprites/` 的 PNG/GIF、JSON、README |
| 运行所需头文件 | `game_background_asset.h`、`game_sprite_assets.h`、`game_background_dirty.h`、`game_display_config.h`、`game_hud_atlas.h`、`game_runtime.h` |
| 工具与检查 | `scripts/`、`tools/`、`sim/` 中本轮改动和新增文件；两个调试启动脚本 |
| 文档 | README、CENTERED_GAME、FULLSCREEN_GAME、TEAM_SPRITES、GAME_BUILD_REPORT、性能交接、寄存器/调试/验收/上传说明 |
| 实测证据 | `docs/evidence/game_perf_20261026/README.md`、`results.json`、`centered_full_load_30fps.png` |

重要：

- `advanced_demo/ti60f225_oob.xml` 新增了命令队列 RTL 引用，属于必需工程变更，要上传。
- 素材头文件虽然由工具生成，但游戏编译直接依赖它们，必须和素材源图、生成脚本一起上传。
- 不要按扩展名一刀切排除 PNG、JSON、H 或 XML；图片和上述证据都是本轮有效内容。
- 已跟踪的 IP/BSP/Flash 源码继续保留，不删除、不因为它们由工具生成而取消已有版本管理。
- HUD缓存/居中损伤恢复及新写准入是后续方案，不能在本次提交说明里宣称已完成。

## 本次不上传

以下四项在 GitHub Desktop 的 Changes 中保持不勾选；只排除本次提交，不删除或撤销本机修改：

```text
basic_demo/software/apb_reg_test/.cproject
basic_demo/software/apb_reg_test/.project
basic_demo/software/apb_reg_test/apb_reg_test_ti.launch
basic_demo/ti60f225_oob.xml
```

其余不纳入源码提交的本机产物：

| 路径或类型 | 处理 |
|---|---|
| `advanced_demo/outflow/` | bitstream与编译报告，不强制加入Git |
| `advanced_demo/work_syn/`、`work_pnr/`、`work_pt/`、`work_dbg/`、`ooc/` | 综合/布局布线缓存，不上传 |
| `advanced_demo/software/*/build/` | 包括 `game`、`game-centered` 的ELF/BIN/HEX/MAP/反汇编及目标文件，不上传到源码提交 |
| `advanced_demo/output/` | 本机交付包、30 FPS基线备份、临时日志，不整个加入Git |
| `.metadata/`、`__pycache__/`、临时仿真文件 | 本地缓存，不上传 |
| 工具安装包、凭据、个人配置及无关截图 | 不属于本轮内容 |

现有 `.gitignore` 已忽略主要构建目录；这些文件通常不会显示在 Changes 中。
不要 `git add -f`，不要修改忽略规则把整个 output/outflow 纳入；也不要用 `git add .`
混入四个基础工程文件。已有跟踪的历史证据继续保留，本次整理后的性能截图是特意纳入的例外。

## GitHub Desktop 操作

1. 选择实际仓库 `2026FPGA/2026FPGA` 和 `main`。
2. 勾选上述本轮 `advanced_demo/` 改动及 `docs/evidence/game_perf_20261026/`。
3. 确认四个 `basic_demo` 文件不勾选，新增素材/头文件/RTL/脚本/性能报告都已勾选。
4. 填入 Summary 与 Description，点击 Commit to main，再 Push origin。
5. 若远端有新提交，先查看差异并正常合并；不要强制推送或覆盖队友工作。

## 可选：PowerShell精确暂存

先预览，暂存区应没有其他独立工作；若有，先判断其归属。

```powershell
Set-Location 'C:\Users\Xuhaowei\Desktop\2026FPGA\2026FPGA'
git status --short
git diff --cached --name-only
git add --dry-run -- advanced_demo docs/evidence/game_perf_20261026
```

确认后，仅选择指定范围。Git会遵守已有忽略规则：

```powershell
git add -- advanced_demo docs/evidence/game_perf_20261026
git diff --cached --name-only
git diff --cached --stat
git diff --cached --check
```

若四个基础工程文件之前已被暂存，可只取消这些文件的暂存，保留工作区改动：

```powershell
git restore --staged -- basic_demo/software/apb_reg_test/.cproject basic_demo/software/apb_reg_test/.project basic_demo/software/apb_reg_test/apb_reg_test_ti.launch basic_demo/ti60f225_oob.xml
```

最终核对清单后再提交推送；可用 GitHub Desktop 填入完整正文，或用命令提交标题：

```powershell
git commit -m 'advanced_demo：加入v7绘图队列与居中素材版，记录满载30FPS基线'
git push origin main
```

## 给队友免编译上板的文件

源码推送不会包含 bit/ELF，队友要直接上板时需另外共享配套产物：

- `advanced_demo/output/campaign_game_centered/ti60f225_oob.bit`
- 同目录 `survival_game.elf`、`SHA256SUMS.txt`、`manifest.json` 和 `使用说明.txt`
- 已拉取本轮源码后，可使用同目录 `start_centered_game_debug.cmd`；它依赖源码目录中的
  `start_game_debug.cmd` 与 `tools/`，不是仅复制六个文件即可跨电脑独立运行的工具包。

也可共享 `advanced_demo/output/performance_baseline_20261026_30fps/` 的配套备份，
通过队内文件传输或Release附件提供，保持目录与版本说明。不要把两个版本的ELF/bit混用。
素材已封存的板卡，从旧居中/全屏ELF切换时需重配同一个v7 bit后再加载目标ELF。

本机候选产物哈希及截图身份限制见
[性能交接报告](PERFORMANCE_HANDOFF_20261026.md)。本次上传不代表满载60 FPS验收完成。