# 2026-10-29：中央窗口 v10 上传说明

当前可作为队内展示与后续对照的阶段版本。用户提供的截图中，v10 在 48 架敌机 / 470 发敌弹目标、Alpha 225 下测量 60,012 ms，平均 59.99 FPS；最慢绘制 10.637 ms、超 16.667 ms 的绘制帧为 0，underflow / missed 增量为 0 / 0。最低秒窗 59.28 FPS、重复旧帧计数 1，尚不应宣称严格零重复或已测出 Sprite 极限。

HDMI 为 1920×1080@60 Hz，实际游戏绘制区域为中央 640×480；不能把此结果写成全屏 1080p 游戏达到 60 FPS。实测截图与人工摘录见 [证据目录](evidence/game_perf_20261028_v10/README.md)，截图内日志时间为 2026-10-28，归档日期为 2026-10-29。

## GitHub Desktop 可复制内容

Summary：

```text
perf(advanced_demo): 优化窗口显示与 Alpha 通路，记录 v10 近 60 FPS 实测
```

Description：

```text
增加中央 640×480 窗口显示，外围由硬件输出黑色，HDMI 保持 1920×1080@60 Hz。
支持运行时调整压力敌机 1–48、敌弹 1–512，保留原素材及原全屏/窗口构建。
减少背景恢复区域，缓存 HUD，并统一双缓冲 FPS/SPR/MAX 的 250 ms 统计采样。
增加 v9 Alpha 连续供数和 v10 的 1 KiB 敌弹源图缓存；仍逐次读取新 Back 背景。
将 Alpha 中间缓存改为可推断的片上 RAM，v10 XLR 从 v8 的 91.28% 降至 67.68%。
保留显示优先、写准入、素材封存及最终写响应完成后的安全换帧保护。
补充兼容检查、独立构建/打包入口、仿真及版本配对说明。

用户提供的 v10 实板截图：48 敌机/470 敌弹目标、Alpha 225，连续测量 60,012 ms；
平均 59.99 FPS，最低秒窗 59.28 FPS，Sprite 500–525，实际敌弹 456–470。
最慢绘制 10.637 ms，最大换帧间隔 16.667 ms，绘制超预算 0 帧，重复旧帧计数 1。
underflow/missed 增量均为 0，截图当前游戏错误为 0。
与此前同目标数量截图的最慢绘制 14.918 ms 相比，缩短约 28.7%；场景运动序列未固定。
六种软件配置、31 项调试桥/GUI 检查及 Alpha/缓存/显示保护仿真通过，两份新硬件时序通过。

本次为接近稳定 60 FPS 的阶段结果；不宣称严格零重复、512 敌弹达标或全屏 1080p 达标。
证据为用户截图和人工摘录，完整原始日志及板端文件哈希匹配仍待补齐。
```

## 源码提交范围

在仓库根目录 `C:/Users/Xuhaowei/Desktop/2026FPGA/2026FPGA` 打开 GitHub Desktop。当前相关改动都在 `advanced_demo/` 下；勾选相关修改与新增文件，尤其包括以下新增文件，不能只上传已跟踪文件的修改：

- `rtl/framebuffer/window_display_reader.v`、`window_axis_composer.v` 及相关 RTL / 工程 XML。
- `software/interactive_demo/game_stress_tuning.h` 及游戏、API、寄存器头文件改动。
- `scripts/` 的窗口构建、独立硬件构建、打包和回归入口，`tools/` 调试桥与 GUI。
- `sim/` 中窗口显示 / 准入 / 保护和 Alpha 缓存的新检查及既有检查改动。
- 根目录窗口、动态压力、HUD 优化与 v9 / v10 启动 CMD。
- `docs/` 本轮架构、动态压力、窗口、优化、上传说明，以及本次截图与人工摘录。

已跟踪的素材图片、生成头文件、IP / BSP 保留。素材头文件虽由脚本生成，软件直接依赖它们，不要按 PNG / JSON / H / XML 扩展名统一排除。

当前以下四项 `basic_demo` 修改与本次高级工程优化无关，在 Changes 中不勾选；保留本机文件：

```text
basic_demo/software/apb_reg_test/.cproject
basic_demo/software/apb_reg_test/.project
basic_demo/software/apb_reg_test/apb_reg_test_ti.launch
basic_demo/ti60f225_oob.xml
```

不纳入源码提交：`output/`、`outflow/`、`work_syn/`、`work_pnr/`、`work_pt/`、`work_dbg/`、`ooc/`、`software/*/build/`、`.metadata/`、`__pycache__/` 及临时仿真产物。现有 `.gitignore` 已覆盖主要目录；不要强制添加整个构建目录。此次归档在 `docs/evidence/` 的截图、JSON 和 README 是需上传的正式证据。

填写标题与正文后，检查勾选范围，再 Commit 与 Push。此说明整理没有暂存、提交或推送代码。

## 队友直接上板所需附件

源码提交不会携带 bit / ELF。另将 `advanced_demo/output/window640_alpha_v10/` 作为 Release 附件或队内文件包提供，包含 bit、ELF、SHA256SUMS、manifest、资源 / 时序报告和 `start_debug.cmd`。

队友先拉取同一版本源码，再将该目录放回原相对位置，通过 JTAG 配置包内 bit，使用 `start_window_stress_alpha_v10_debug.cmd` 或包内 `start_debug.cmd` 加载 ELF。启动器依赖工程根目录工具，包本身不是脱离源码即可运行的独立软件。旧窗口 ELF 不支持 v9 / v10。

v9 对照包为 `output/window640_alpha_v9/`。原 v8 基线继续保留，详见 [配对说明](ALPHA_HARDWARE_OPTIMIZATION.md)。打包脚本还依赖本机保存的旧版本保护清单和基线产物；新克隆仓库不能仅凭源码直接执行完整打包校验，免编译展示优先使用已共享的配套包。
