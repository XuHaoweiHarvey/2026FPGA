# M2 独立 DDR 素材与连续动态 Demo：开发记录及实板验收

> 目录整理后，本页所述 M2 工程位于 `basic_demo/`。在该目录运行软件与检查脚本，并在 Efinity 打开 `basic_demo/ti60f225_oob.xml`；不要使用 `advanced_demo/` 的 M1a bit/ELF。本次迁移复验的独立软件构建位于 `basic_demo/output/board_revalidation/m2/m2_demo.elf`，本地 Launch 已指向它，搬来的旧 ELF 保留原样。

状态：**RTL/C 开发与本机检查完成；Efinity 完整 Compile、Programmer 下载和真实 FPGA 验收待负责人执行。** 不把仿真 FPS 当作实板 FPS，也不沿用旧 bit/ELF 证明 M2。

实际修改文件：`.gitignore`；`rtl/control/{accel_regs,sapphire_control}.v`、`rtl/framebuffer/{blit_source_guard,cpu_ddr_bridge,rgb_framebuffer}.v`、`rtl/ti60f225_oob_top.v`；`software/apb_reg_test/{accel_regs.h,main.c}`、新增 `software/m2_demo/{main.c,scene.h,assets.h,metrics.h,render.h}`；`scripts/build_apb_software.py`、新增 `scripts/run_m2_software_checks.py`；`sim/{tb_blit_source_guard,tb_checkpoint_d,tb_cpu_ddr_bridge,tb_graphics_contract,tb_graphics_double_buffer}.v`、新增 `sim/{tb_m2_asset_regs,tb_m2_full_asset_blit,m2_software_checks.c}`；`docs/{BUILD,REGISTER_MAP,M2_ACCEPTANCE}.md`。`software/m2_demo/build/` 是新 ELF 输出，已加入 ignore；历史 bit/ELF 未覆盖。

## 1. 实现范围和内存合同

Mode 6 独立于历史 Mode 0～5。显示仍为 1920×1080@60Hz XRGB8888；绘图区域 `(640,300)` 起 640×480；左上 HUD 同时显示 CPU Render FPS、FPGA Render FPS、Hardware Speedup 和场景名。当前模式/负载为简短附加标签。Color Key 硬件与旧软件保留，但 Mode 6 不调用。

| 用途 | DDR 物理起点 | 长度 / 尾地址（开区间） | 权限 |
|---|---:|---:|---|
| Front/Back 物理槽 0 | `0x00000000` | `0x007E9000` / `0x007E9000` | 显示读 Front；CPU/FPGA 只写 Back |
| Front/Back 物理槽 1 | `0x00800000` | `0x007E9000` / `0x00FE9000` | 同上；Swap 只互换角色 |
| 图片 0 | `0x01000000` | `0x0012C000` / `0x0112C000` | 装载期 CPU 读写；封存后只读 |
| 图片 1 | `0x0112C000` | `0x0012C000` / `0x01258000` | 同上 |
| 图片 2 | `0x01258000` | `0x0012C000` / `0x01384000` | 同上 |

CPU 使用经已验证 M1a upsizer 的 uncached DDR alias，即物理地址加 `0x1000`。每张图片完整 640×480×4 字节，三张由 CPU 逐像素直接生成至 DDR，再经合法 CPU 会话逐像素读回、对比和计算 hash；OCRAM 中无整图缓存。`ASSET_CONTROL(0xD8)` 的 bit0 请求装载，bit1 在会话已排空/释放且无故障时请求封存；`ASSET_STATUS(0xDC)` 的 bit31 为能力、bit2 为 CPU 会话/桥故障、bit1 为 READY、bit0 为 LOADING。平台复位清 READY；CPU Debug reset 保留平台素材与所有权。封存后 CPU Bridge 不接受素材写，普通 BLIT 只允许三个整图首地址、stride 2560、宽 640、高 480 且 READY；Color Key 和任意中间地址均不能以素材为源。Front→Back 旧 BLIT 保持原合同。DDR 控制器/PHY、显示读优先级、写端节流算法与 VBlank Swap 均未修改。

## 2. 动态帧与计时

固定循环：矩形 CPU → 矩形 FPGA → 图片 CPU → 图片 FPGA → 返回矩形 CPU。每个阶段重新用种子 `0x6D325E71` 初始化同一任务序列。默认 `RECT_COUNT=24`，可编译指定 1～64；**CPU/FPGA 始终使用同一值**。两物理槽分别记录上次方块；每段的首两帧分别清理各槽的 640×480 区域，此后对当前 Back 槽恢复旧矩形再绘制全部新矩形。清理/恢复也在 Render 计时内。图片顺序始终 0→1→2，CPU 真正从素材 DDR 读 307,200 像素并写 Back；FPGA 通过普通 BLIT 完整复制同图。

一帧 Render 从任务生成前开始，到 CPU 会话完成 B/R 排空并释放或 FPGA 真正 DONE 后结束。HUD 绘制及安全 Swap 单独计时。`metric[scene][mode][class]` 统计完成的渲染帧耗时并约每 1 秒窗口公布 FPS；未完成帧不产生样本。`class=1` 是各矩形阶段必需的首两帧全区清理，`class=0` 是之后的持续运动/整图复制。HUD 只比较当前同场景、同负载、同 class 的最近一次有效 CPU/FPGA 样本；缺值显示 WAIT。`presented_fps_x100` 记录实际安全 Swap 的墙钟呈现速率，和 Render FPS 分开。阶段 5 秒计时点是该阶段**首帧安全 Swap 完成**；5 秒到后仍完成当前全帧与安全 Swap，立即进入下一阶段。300 秒无完整渲染帧或底层等待失败会停在错误函数并保留 Debug 状态；不会强行取消在途 AXI。

## 3. 本机开发检查

在本目录构建 `--program m2 --opt O2`：64 KiB OCRAM 链接通过，`_start=0xF9000000`，`g_m2_result`/栈均在 OCRAM。当前默认 24 方块 ELF SHA256=`D0082CC3A9F3AC092FD60D5B28300BAA6CE5C145AC350B02065FA628E2978D5A`；50 方块配置也链接通过。GNU linker 对现有 RAM 链接脚本报告 RWX LOAD warning；不是本次新增内存布局。以下检查已在当前源码通过：

- `python scripts/check_project.py`：56 个设计源条目、寄存器表检查。
- `python scripts/run_m1a_checks.py`：原 upsizer 和 CPU Bridge，包括素材边界、READY 前后读写与 Front 保护。
- `python scripts/run_apb_checks.py`：原 APB WAIT0/1/3 与 v4/v5/Color Key 合同。
- 历史 Mode 0、Mode 4、M1a、M1b 的 ELF 均构建到系统临时目录并通过 OCRAM 链接；原 `run_e_software_checks.py` 以新构建的 Mode 0 ELF 通过连续动画、普通 BLIT、Color Key 及故障回归。未覆盖、未重命名原历史 bit/ELF。
- `python scripts/run_d_checks.py --apb-waits 1 --cpu-ddr`：CPU 会话/仲裁/节流/显示集成，装载封存时会话排斥、平台复位清 READY。
- `python scripts/run_d_checks.py --apb-waits 1 --graphics --color-key`：旧 FILL/BLIT/Color Key 与安全 Swap；显示模型 underflow/missed 增量 0。
- `python scripts/run_rgb_checks.py --quick`：顶层端口展开与 RGB 回归。
- `sim/tb_m2_asset_regs.v`：0xD8/0xDC 在 APB WAIT0/1/3、忙/故障拒绝、控制复位保留素材状态、旧版本号/能力不变。
- `sim/tb_blit_source_guard.v`：封存前拒绝、三个首地址接受、偏移/stride/尺寸/Color Key 拒绝。
- `sim/tb_m2_full_asset_blit.v`：READY 前无 AXI，封存后三张 **完整 640×480** 图片经正式 Source Guard、Graphics Engine、BLIT Engine 与五通道背压 AXI 模型复制；总计 230,400 个读/写 128-bit beat，最终 B 已排空、目标视口逐像素一致、外部样点不变。
- `python scripts/run_m2_software_checks.py --unicorn-path <Unicorn 2.1.4 目录>`：实际编译的 RV32 场景/性能逻辑，检查两槽历史、CPU/FPGA 即使从相反 Back 物理槽起步也产生相同逐帧任务、运动边界、0/1/2 图片顺序、三张完整图片的 CPU 逐像素复制、完整帧 FPS 窗口、首帧后五秒切换与 speedup；另以 `--rect-count 50` 通过。FPGA 整图测试的像素生成公式与 CPU 程序相同，二者独立执行并逐像素验证。

仿真使用现有 Icarus/Icarus vvp；其中完整素材测试可复现：

```powershell
iverilog -g2005-sv -s tb_m2_full_asset_blit -o output/m2_full_asset_blit.vvp sim/tb_m2_full_asset_blit.v sim/tb_blit_engine.v rtl/framebuffer/blit_source_guard.v rtl/accelerator/graphics_engine.v rtl/accelerator/blit_engine.v rtl/accelerator/fill_rect_writer.v
vvp output/m2_full_asset_blit.vvp
```

`-g2005-sv` 用于共享测试文件中历史变量名 `checker`；M2 设计 RTL 无此限制。本机软件行为检查不能证明 Efinity 时序、真实 DDR 带宽、HDMI 连续性或板上 FPS。

## 4. 负责人实板验收步骤

1. 保持当前工作目录 `D:\Github_repositories\2026FPGA`。在 Efinity 2026.1 打开当前 `ti60f225_oob.xml`，确认 top=`ti60f225_oob_top`、`soc_control` 是现有 Sapphire IP、56 个 design entries 包含 CPU Bridge。不要 Generate IP。执行**完整 Compile（含布局布线与时序）**，检查 100 MHz 时钟是否满足约束、资源和新告警；保存 `outflow/ti60f225_oob.info.log`、timing report、bit 文件时间及 SHA256。现存历史 bit 不代表 M2。
2. 关闭旧 OpenOCD/GDB。Programmer 只下载本次 Compile 输出的 `outflow/ti60f225_oob.bit`，记录下载日志与同一 SHA256；初始 HDMI 应稳定。不要烧录/覆盖历史镜像。
3. 在当前目录执行 `python scripts/build_apb_software.py --program m2 --opt O2 --output software/m2_demo/build`，记录 `software/m2_demo/build/m2_demo.elf` 的 SHA256；**此 ELF 对应本次 M2 bit**。想尝试 50 方块时先用相同命令加 `--define RECT_COUNT=50` 重建并记录新哈希，两端负载自动保持一致。
4. RISC-V IDE 复制已有 Titanium Hard JTAG Debug 配置，把 `bsp_loc`、OpenOCD `-f`、SVD/寄存器描述、image、symbols 均指向当前目录。image 和 symbols 指向 `software/m2_demo/build/m2_demo.elf`，Startup PC=`f9000000`，禁用 IDE 自动重建旧 `apb_reg_test`。在 `main` 可设一次启动断点；计时期间不得单步或暂停。推荐另设 `m2_error_stop` 故障断点及 `m2_cycle_boundary` 完整四阶段后断点（采完一轮再停）。继续观察无限循环时移除周期断点。
5. 首次启动应看到 `g_m2_result.phase` 按 1→2→3→4→5/6/7/8 运行，`asset_rows_written=asset_rows_verified=1440`，`asset_hash[i]=asset_verify_hash[i]`，`asset_status.bit1=1` 且 bit0=0，`asset_write_ticks`、`asset_verify_ticks`、`asset_total_ticks` 非零。装载秒数分别为这些 tick 除以 BSP 的 `SYSTEM_CLINT_HZ`；当前只有本机构建/仿真，无实板装载耗时数值。装载时间单独记录，绝不并入 Render FPS。若 CPU Debug 重启而平台未复位，READY 可保留；软件会完整重新校验已封存的三张图片。平台复位后 READY 应重新清零并重新装载。
6. HDMI 左上四行应持续显示 CPU Render FPS、FPGA Render FPS、Hardware Speedup 与 `MOVING RECTANGLES` / `IMAGE SWITCHING`；模式标签显示 CPU/FPGA。未取得对照样本时显示 WAIT。640×480 绘图区域在中下方，矩形持续运动且无残影；图片 0/1/2 色彩图案明显不同并循环切换。四阶段每段从**首帧实际出现**起至少 5 秒，完整一轮至少 20 秒加各阶段首帧等待；阶段之间无额外固定停顿，也不会 PASS 停止。
7. 在 `m2_cycle_boundary` 暂停检查 `g_m2_result.cycle>=1`、`error=0`、`metric[0][0][0]` / `[0][1][0]` / `[1][0][0]` / `[1][1][0]` 的 `valid=1`、`fps_x100>0`、`last_frames>0`、`last_render_ticks>0`。首两帧的 `metric[0][mode][1]` 另记过渡成本；不与稳态 class0 混算。`presented_fps_x100[scene][mode]` 应为实际 Swap 的速率，通常低于或等于 Render FPS；不能把固定 HDMI 60 Hz 当成渲染值。记录同场景 CPU/FPGA 的原始 ticks 和 HUD 数值，速度比应与两 FPS 比值相符。
8. 继续运行至少数轮、记录照片/视频和各场景耗时。检查 `stage_first_present_log[scene][mode]`、`stage_last_present_log[scene][mode]`：四项差值各至少 `5×SYSTEM_CLINT_HZ`；对应 `stage_presents_log>=1`。对 24 方块先测可观察运动与 CPU/FPGA 区别；若方块过少或 CPU 阶段不易形成连续动画，再以相同配置构建 **两种模式共同使用** 的 32/40/50/64 方块版本，保存每版 Render/Presented FPS、HDMI 视频和错误计数，由实板结果决定最终 `RECT_COUNT`。
9. 错误诊断看 `g_m2_result.phase=255`、`error`（E400配置、E401会话、E402素材、E404时钟、E405系统健康、E406角色、E407超时；图形/API 错误直接记录其返回码），同时保存 `cpu_status`、`cpu_error`、`asset_status`、`reader_error`、`underflow_delta`、`missed_delta`、`front/back`、`command_delta`、`swap_delta`、`asset_image`、`asset_error_x/y`、`asset_expected/actual`、`row_progress`。从 APB 再读 `ERROR_CODE`、`CPU_DDR_STATUS/ERROR`、`READER_ERROR`、UNDERFLOW/MISSED 累计值；计数与启动稳定 baseline 比较应 **增量 0**。发生在途 AXI 故障时保留状态和板上日志，不通过 CPU 超时强制释放或切换 Front。
10. 用相同板与本次 M2 bit 可分别加载保留的 Mode 0～5 ELF 做回归；至少复查 Mode 4、M1a CPU DDR Smoke、M1b Mode 5、原 FILL/普通 BLIT/Color Key 与 Front/Back Swap。ELF 不得错配；先记录并保存原有历史 bit/ELF，回退时按各阶段已验证的 bit+ELF 成对恢复。M2 新 bit 对旧功能的板级兼容性仍须由负责人确认。

判定条件：三张资源写入并完整读回，READY 后只读；四阶段持续循环、每段首个有效画面后至少 5 秒且安全切换；CPU 与 FPGA 图元/图片任务一致，完整动态帧 FPS 与 Speedup 可追溯；显示无新增 underflow/missed，所有 DDR/reader/引擎错误为零，旧功能无退化。**收到负责人实板反馈前，本文件状态保持“待验收”。**
