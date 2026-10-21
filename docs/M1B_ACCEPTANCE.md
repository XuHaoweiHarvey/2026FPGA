# M1b — CPU/FPGA 性能对比验收报告

2026-10-21，工作目录 `D:/Github_repositories/2026FPGA`，分支 `codex/phase3-m1b`。本报告记录**源码、软件构建和本机仿真**，不代表 M1b Efinity 编译或实板通过。

## 1. 基线、范围及修改文件

- M1a 合并基线为 `73880cd`（父分支 `main`）；M1a 原始实现提交 `c1d2bb0`。已有未提交的 IDE metadata、`docs/BUILD.md`、launch 和根工程 XML 修改被保留。没有创建 Worktree、重新克隆、Generate Sapphire、修改 DDR Controller/PHY、AXI 仲裁、Buffer Ownership 或 RTL。
- M1a 文档记录的验收 bit/ELF 来源与哈希限制见 [M1A_CPU_DDR](M1A_CPU_DDR.md)。本次未生成或下载 bit。构建回归曾写入 M1a 输出路径，已从现有 M1a 归档恢复 `m1a_ddr_smoke.elf` 到文档 SHA256 `E587FCB00855D7BE848F3F2CA8B3778ED59413D89C068C47C184AE39F3E16846`；后续回归应使用独立输出目录。
- 新增 `software/m1b_compare/main.c`、`software/m1b_compare/software_render.h`、`software/m1b_compare/hud.h`、`sim/test_m1b_software.c` 和本文。修改 `software/apb_reg_test/main.c` 的编译选择、`scripts/build_apb_software.py` 的 M1b 构建入口，并在 README/ARCHITECTURE/BENCHMARK/BUILD/VALIDATION 中增加入口说明。旧模式 0～4 的代码路径仍保留。
- 赛题二原文位于 `docs_reference/` 指南的第 7～9 页：基础要求包括 Solid Fill、Block Copy、双缓冲、HDMI 和实时软硬 FPS 对照；Color Key 属于高阶挑战。本阶段只做已存在的 Color Key 对照，不提前开发 Alpha 或游戏。

## 2. M1a 实际访问合同

Sapphire 运行于 `0xF9000000` 的 64 KiB OCRAM。M1a 的 CPU 地址 `SYSTEM_DDR_BMB=0x00001000` 对应 DDR 物理 0；程序把当前 `FRONT_BASE/BACK_BASE` 加 `0x1000` 得到 CPU 指针。桥的 32-bit 像素访问经过 128-bit lane 转换；Front/Back 有效区可读，仅锁定 Back 可写，DDR 帧槽 padding 不可访问。

每段 CPU 绘图或读回先写 `CPU_DDR_CONTROL.bit0` 取得会话；最后执行 `fence iorw,iorw`，等 `CPU_DDR_STATUS.bit1` 清零，检查 `CPU_DDR_ERROR` 和会话错误，再写 `bit1` 释放并确认 `bit0` 清零。会话期间加速器 START 和 Swap 被拒绝；显示仍读 Front。CPU reset 不撤销平台会话。Mode 5 启动时沿用 M1a 的排空、释放、清错误恢复顺序。任何运行时 DDR/会话错误使程序停在 `m1b_test_done`，不强行交换帧。

## 3. 真实 CPU 绘制与 FPGA 对照

`software_render.h` 的 Fill 按像素计算 `dst[(y+row)*1920+x+col]` 并执行 32-bit DDR store。普通 BLIT 对当前 Front 逐像素 load，再对 Back store。Color Key 对源 `pixel & 0x00ffffff` 与 key RGB24 比较；命中时完全保留 Back 的 32-bit 原像素，未命中时复制完整 XRGB8888 源像素。该规则与 `graphics_engine.v`/`color_key_blit_engine.v` 的低 24 位比较和 WSTRB 遮罩一致；X 字节不作为 alpha。

FPGA 对照使用现有 `accel_submit` + `accel_wait_done`，包括 FILL、BLIT 和 Color Key，没有新增寄存器/RTL。每次执行前以相同硬件 FILL 准备源 Front：整帧 `0x80ff00ff`，测试区域右半 `0x40e8e8f0`；安全 Swap 后再将 Back 整帧置为 `0x00182838`。准备结束才开始渲染计时。CPU、FPGA 每种图元各执行一次，构成一个成对样本。每次图元输出独立发布，再重建下一次源，避免 Swap 后读取上一幅输出。

默认 64×64，其他可选 320×240、640×480、1920×1080。前三种目标左上角 `(256,256)`，全屏目标 `(0,0)`；BLIT 的目标 X 和宽均满足四像素对齐。Front 源始终从 `(0,0)` 起，stride=7680，格式 XRGB8888。CPU/FPGA 同一图元使用完全相同的输入、目标、颜色、背景和像素数。尺寸沿用 Mode 4，局部目标坐标与 Mode 4 不同，因此**不能把旧 Mode 4 的时间直接除以本次 CPU 时间**。每个完整 cycle 的图元/模式执行顺序固定为 FILL CPU/FPGA、BLIT CPU/FPGA、Color Key CPU/FPGA；连续循环，或设置 `g_m1b_cycle_limit=1` 做有限验收。

## 4. 计时、FPS 和正确性

CLINT 由正式 BSP 指定为 100 MHz，使用高/低/高重读获取 64-bit tick。无断点、单步或调试暂停时，`render_ticks` 口径如下：

| 模式 | Render 起止 | 分解 |
|---|---|---|
| CPU | 申请 CPU DDR 会话之前，到最后 `fence`、桥排空、错误检查及释放会话之后 | `session_ticks`、`pixel_ticks`、`drain_ticks`；逐行预算检查包含于像素时间 |
| FPGA | `accel_submit` 前，到最后一次 B 后 `accel_wait_done` 成功返回 | `submit_ticks`（含命令接受确认）、`wait_ticks`（等待真正 DONE） |

`Render FPS = 100 MHz / render_ticks`；结果结构和 HUD 用百分之一 FPS 整数表示。`speedup_x100 = CPU render_ticks × 100 / FPGA render_ticks`，只在本轮两个模式均验证后更新；这是软件可见、端到端**单图元完成时间**的主加速比。`pixel_ticks` 不是单纯 CPU 算术时钟，包含实际 DDR load/store 及其阻塞。`Presented FPS = 100 MHz / present_ticks`，其中 `present_ticks` 从源准备前到安全 Swap 完成，包含准备、渲染、逐像素验证和 HUD。它是该程序可发布完整结果帧的速率，不是固定 HDMI 刷新率，也不用于主加速比。HUD 显示上一次已完成的同模式 Presented FPS，第一次显示 WAIT。`prepare_ticks`、`verify_ticks`、`hud_ticks`、`swap_ticks` 单独保留。

每次 CPU/FPGA 绘制后，在新的合法 CPU 会话中逐像素读 Back 目标区域，与同一参考值比较，并对前后水平邻接背景各检查一像素。记录首次错误的 `(error_x,error_y,expected,actual)`、验证像素数和 FNV-1a hash；同一图元的 CPU/FPGA hash 必须相等。64×64 覆盖左上/右下/行边界/16-byte beat、色键命中/未命中、全透明左半和非透明右半。验证发生在 HUD 叠加之前，不写 Front。`underflow_delta`、`missed_delta` 从启动后的稳定显示基线累计，非零即停止。CPU 单次绘制和逐像素验证分别按行检查默认 120 秒预算；进度可由 `verified_pixels` 和 `phase` 观察，超时只记录失败，不换算 FPS。更大尺寸需先通过 64×64 板测再逐级启用。

## 5. HDMI 实时展示

HDMI 画面左侧是本次 64×64 等目标结果，右侧深色面板由安全硬件 FILL 创建，文字由 CPU 在独立会话写 Back。面板显示 `CPU SOFTWARE RENDERING`、`FPGA HARDWARE ACCELERATION`、图元/尺寸/像素数、双方 Render FPS、成对 Speedup、最近完成的 Presented FPS、underflow/missed、错误值及当前画面模式。准备源、验证、面板 FILL/文字、Swap 均不混入 Render 计时。面板使用 FPGA FILL 是**展示开销**，CPU 被测图元仍完全由 CPU 逐像素完成。程序顺序执行两种模式，屏幕轮换当前结果并保留同一图元的最近成对性能值。

## 6. 已完成验证与未完成项目

| 类别 | 结果 | 证据/限制 |
|---|---|---|
| 静态检查 | 通过 | 赛题原文、M1a 真实桥/状态机、BSP、Color Key RTL、Mode 4 API 和源地址合同已核对；无 RTL 或寄存器修改 |
| 软件构建 | 通过 | `python scripts/build_apb_software.py --program m1b --opt O2 --output software/m1b_compare/build`；ELF LOAD、结果符号及 stack 均在 OCRAM；旧 Mode 0/4 和 M1a 也构建通过 |
| 本机 C 行为 | 通过 | `sim/test_m1b_software.c` 使用 MSVC 执行 Fill、BLIT、RGB 色键、X 字节、源保持与目标边界检查；旧 Mode 4 行为测试 12 cases 通过 |
| RTL 仿真 | 通过既有回归 | M1a upsizer/bridge、CPU session 共享 DDR/Swap、FILL/BLIT/Color Key、独立图形/读仲裁/色键单元、APB WAIT0/1/3、RGB/HDMI 顶层展开通过；M1b 没有修改 RTL。本机未执行完整 Sapphire CPU 指令仿真 |
| Efinity 综合/时序 | **未执行 M1b** | 本次无 RTL 变化，但当前工作区根 XML 有先存修改，仍须在目标目录确认 56 design entries 后正式 Compile |
| FPGA 实板 | **未验证 M1b** | 未下载新 bit/ELF、未取得真实 FPS、像素读回、画面或连续性原始数据；需负责人操作并反馈 |

当前限制：默认运行尺寸为 64×64；大尺寸 CPU 单笔 DDR 访问可能非常慢，120 秒预算会将其标记为超时而非产生虚构 FPS。逐像素校验在全屏时也可能耗时很长，但不纳入 Render。HUD 的 Presented FPS 滞后一轮同模式发布，因为当前帧的安全 Swap 必须在 HUD 绘制之后。`present_ticks` 包括测试准备与验证，绝不解释为 HDMI 实际 60 Hz。全屏和长时间连续运行、调试器中断恢复、真实 DDR 下的错误/欠载仍待板级验证。

## 7. Efinity、Programmer、RISC-V IDE 板级验收步骤

1. 在当前目录打开 `ti60f225_oob.xml`，确认 top `ti60f225_oob_top`、`soc_control` 配置、56 个 design entries 和 `rtl/framebuffer/cpu_ddr_bridge.v`。不 Generate Sapphire、不修改 DDR/PHY。执行完整 Efinity Compile，保存资源、100 MHz 时序和告警报告，记录新 bit SHA256。当前现存 bit 的版本/哈希不能替代本轮 Compile 证据。
2. Programmer 仅下载本次 Compile 的 `outflow/ti60f225_oob.bit`，保存下载日志、bit 路径/时间/SHA256；确认未运行软件时的初始化 HDMI 图像稳定。不要复用旧 v5 或 M1a bit 冒充本轮结果。
3. 在仓库根目录执行 `python scripts/build_apb_software.py --program m1b --opt O2 --output software/m1b_compare/build`。固定同一 bit、同一软件构建配置、同一 `M1B_SIZE_INDEX` 和优化级别。复制既有 Hard JTAG launch 为本地 M1b 配置；将 `bsp_loc`、两个 OpenOCD `-f`、寄存器描述、SVD、image、symbols 全部指向**当前目录**。image/symbols 指向 `software/m1b_compare/build/m1b_compare.elf`，Startup PC=`f9000000`，禁用自动重建旧 `apb_reg_test`。关闭 Programmer 和旧 GDB/OpenOCD，再 Debug；停在 `main` 后取消计时过程断点并 Resume。
4. 64×64 首次验收可在 `main` 暂停时把 `g_m1b_cycle_limit` 设为 1；只在终点 `m1b_test_done` 设断点。不要在计时中单步或暂停。检查 `g_m1b_result.pass=1`、`phase=8`、`cycle=1`、`error=0`、`sample[0..2][0..1].valid=1`、每样本 `verified_pixels=4096`、同图元两个 hash 相同、`render_ticks/present_ticks>0`、`underflow_delta=missed_delta=reader_error=0`、`cpu_error=0`、会话 bit0/bit1 均清零。保存完整 `g_m1b_result` 原始变量、照片和 ELF SHA256，不只抄 HUD 四舍五入值。
5. HDMI 应先短暂显示品红/白源图，再在深蓝背景下轮换青色 FILL、普通复制（左品红/右白）、色键复制（左背景/右白）；右侧深色面板持续更新最近有效 CPU/FPGA Render FPS 与 Speedup。每张图显示 `DISPLAY CPU` 或 `DISPLAY FPGA`。最终 Color Key FPGA 画面保持到断点；连续运行时循环更新。
6. 首轮通过后，分别在构建命令加入 `--define M1B_SIZE_INDEX=1`、`=2`、`=3`，每次重新 Build 并记录 ELF、尺寸、真实 tick、FPS、hash 与错误计数。全屏若超过预算，记录 `M1B_ERR_TIMEOUT (0xE303)`，不能填写 FPS。若需调整预算，使用 `--define M1B_CPU_BUDGET_SECONDS=...` 并记录配置。重复至少三轮无断点计时的 64×64 数据，再做长时间运行和 CPU Debug/Reset 复验。

**实板通过条件：** 六个 CPU/FPGA 图元样本均完成逐像素读回、源/目标角色正确；每组 CPU/FPGA hash 一致；非零真实渲染/呈现 tick 和可追溯 FPS；画面文字可读、轮换正确；无 AXI/CPU/reader 错误，underflow 与 missed boundary 相对基线增量为 0；连续运行无锁死或撕裂。Efinity 完整 Compile、真实 bit 下载、RISC-V IDE 实测与截图必须由负责人确认后才能把本节状态改为“硬件通过”。
