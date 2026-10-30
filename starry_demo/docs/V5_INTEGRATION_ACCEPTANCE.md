# v5 集成验收清单与团队对接说明

本文用于验收当前 v5 色键透明复制版本。它把已经通过的仿真/软件检查与必须由 A、C 在 Efinity、DDR、显示器和开发板上完成的检查分开记录，避免把仿真结果误写成上板结果。

2026-10-19更新：B本机已完成BLIT长路径修复和Efinity完整编译，当前约束下core_clk裕量+1.449ns；最差建立/保持裕量分别+0.417/+0.026ns。静态时序已通过。硬件仍为v5，下载时需要记录包含本次修复的提交号，详见[时序修复记录](V5_TIMING_FIX.md)。

2026-10-20补充：已收到模式3对比照片及模式4第一轮总结果、三轮全屏性能截图和最终色键画面，见[实板记录](V5_BOARD_BENCHMARK.md)。这批证据覆盖基本画面、第一轮完整测速流程和全屏case重复性；不据此勾选所有边界/长期/故障验收项，保留接口告警核对、构建来源和缺失诊断的待办。

## 1. 当前版本合同

| 项目 | v5 约定 |
|---|---|
| 版本识别 | `ACCEL_VERSION = 0x00050000`，`CAPABILITIES = 0x000000FB` |
| 操作码 | `0` = FILL，`1` = 普通 BLIT，`2` = Color Key BLIT |
| 像素格式 | XRGB8888，软件颜色写作 `0x00RRGGBB`；最高 8 位不是 Alpha |
| 画面参数 | 1920×1080，4 bytes/pixel，stride = 7680 bytes |
| 源和目标 | 源是当前 Front 内的绝对 byte 地址；目标写入接收命令时锁存的 Back |
| 缓冲区 | Buffer0 = `0x00000000`，Buffer1 = `0x00800000`，Front 与 Back 必须不同 |
| 色键 | `RECT_COLOR[23:0]` 按 `0xRRGGBB` 精确比较，`[31:24]` 忽略 |
| 透明像素 | 对应 4 个 byte strobe 为 0，保留 Back 原有的完整 32 位像素 |
| 总线语义 | 128-bit AXI 写数据、16-bit WSTRB、byte 地址；透明拍仍必须完成 AW/W/WLAST/B 握手 |
| 完成语义 | 最后一个成功 B response 后才算完成；软件还要确认 BUSY=0、WRITER_OWNED=0、ERROR_CODE=0 |
| 换帧语义 | 软件显式请求；Swap 只交换 Front/Back 角色，不复制整帧 |

详细寄存器以 [REGISTER_MAP](REGISTER_MAP.md) 为准，三方共享规则以 [INTERFACES](INTERFACES.md) 为准。

## 2. 已经完成的证据

- v5 APB、Framebuffer、顶层和软件 API 已接通。
- `COMMAND_OP=2`、RGB24 色键比较、透明像素 WSTRB 屏蔽已经接入统一图形入口。
- 共享 DDR/显示系统仿真已覆盖普通 BLIT 与色键 BLIT 对比、全透明/部分透明 WSTRB、最后 B 返回前的 BUSY/Back ownership、源窗口保护、双缓冲、换帧和显示保护。
- APB 检查、RGB quick 回归、工程源清单检查和正式 BSP 软件构建已通过。
- `DEMO_MODE=3` 的预期场景是左边普通复制、右边色键透明复制；软件接口为 `accel_color_key_blit(...)`。
- Efinity2026.1.132完整编译及当前约束下静态时序通过；XLR=28001/60800、Memory=141/256、DSP=12/160，已生成当前bit。

以下结果仍属于“待验收”：CPU 指令行为仿真、保留接口/工具告警的基线核对、剩余板级边界/故障及长期连续性。已有真实 DDR/HDMI 全屏性能和色键画面证据见[实板记录](V5_BOARD_BENCHMARK.md)，其中的待补项仍需保留。

## 3. A 同学验收项目：工程、软件和板卡

### 3.1 Efinity 工程检查

- [x] 本机从当前 v5 工程打开 `ti60f225_oob.xml`，确认顶层为 `ti60f225_oob_top`。
- [x] 本机确认工程包含 `graphics_engine.v`、`blit_engine.v`、`blit_source_guard.v`、`ddr_read_arbiter.v`、`accel_regs.v` 和当前 `rgb_framebuffer.v`。
- [ ] 确认正式 BSP 与当前硬件配置配套，不使用旧 v3/v4 ELF。
- [x] 本机完整Compile至bit生成通过。
- [ ] 核对58个Missing Interface Pins、`pll_inst4_RSTN`、LVDS距离和组合环切断等保留告警，对照原板级基线确认用途。
- [x] 记录布局后的资源和最高频率/时序裕量，见时序修复记录。
- [x] 本机确认 `core_clk=100 MHz` 的当前约束下建立/保持检查通过；A重建后也应核对自己的最终报告。

### 3.2 软件和寄存器检查

- [ ] 下载当前bit后读到 ID=`0x4143434C`、VERSION=`0x00050000`、CAPABILITIES=`0x000000FB`。
- [ ] 读到 WIDTH=`1920`、HEIGHT=`1080`、STRIDE=`7680`。
- [ ] `SERVICE_READ_QUOTA=128`、`SERVICE_WATERMARKS=0x02000180`，`SERVICE_STATUS` 的bit5（保护策略使能）为1；不能把它当FIFO实时健康位。
- [ ] 使用当前正式 BSP 重新 Build `software/apb_reg_test`，设置 `DEMO_MODE=3`。
- [ ] 软件启动时没有版本错误、初始化超时或历史错误码残留。

### 3.3 板卡画面和命令检查

- [ ] 先保留旧 FILL 回归，确认纯色矩形仍能显示。
- [ ] 运行模式 3：左侧普通 BLIT 应复制紫色背景，右侧色键 BLIT 的紫色区域应保留蓝/绿色 Back 背景。
- [ ] 非紫色机器人像素在左右两侧都应复制；源图不能被修改。
- [ ] 透明区域跨过蓝/绿色分界时，两种背景都必须连续可见。
- [ ] 连续运行期间 HDMI 不黑屏、不重启 CVO；`underflow` 和 `missed boundary` 的增量应为 0。
- [ ] 记录 `color_key_commands_issued`、`color_key_commands_completed`、`command_count`、`swap_count`、`writer_bursts` 和显示错误计数。
- [ ] 设置 `g_frame_limit=2` 有限运行两轮：应用完成26条命令，硬件COMMAND_COUNT/SWAP_COUNT相对启动基线分别增加26/4，色键issued/completed均为2，`pass=1`、`errors=0`。CPU重跑不清平台累计计数。
- [ ] 保存调试器结果变量、版本/关键诊断寄存器和左右对比照片；有串口日志时可附上，当前演示不依赖串口。

## 4. C 同学验收项目：DDR、Framebuffer 和显示连续性

- [ ] 确认 Display Reader 与BLIT共享读取Front，Back由Accelerator写入；一条命令的Back base在接收时锁存。
- [ ] 确认 B 的相对 AW 地址只在 C wrapper 中加一次物理 Back base。
- [ ] 确认 128-bit AXI、16-bit WSTRB、AW/W/B 的握手和 4 KiB 分段规则没有被改变。
- [ ] 用真实 DDR 检查全零 WSTRB 和部分 WSTRB：事务仍完成，透明像素保持原 Back 内容。
- [ ] 确认显示读仲裁、FIFO 水位和写准入保护仍然生效；不能通过截断已有 W/B 或 AR/R 事务来解决 underflow。
- [ ] 检查一次完整换帧：旧 Front 的 R 事务结束、writer 释放、FIFO 排空后才提交新 Front。
- [ ] 保留旧 FILL/普通 BLIT 回归，并记录 underflow、missed boundary、reader error、AR/R stall 和 FIFO 水位。
- [ ] 如果真实 DDR 不接受全零 WSTRB，先报告控制器行为和错误日志，再讨论协议修改；不要单方面改变 B 的透明语义。

## 5. B 同学当前配合事项

2026-10-19新增软件模式4固定工作量测速，见[BENCHMARK](BENCHMARK.md)。它使用当前v5 bit，只需Build/下载新ELF；默认12组、252条完成命令和24次swap，绘制与swap分别计时。本机软件行为检查和BSP构建通过，已收到的实板结果见[V5_BOARD_BENCHMARK](V5_BOARD_BENCHMARK.md)，其余画面/诊断和运行留证继续按清单补齐。

- [ ] 提供本清单中的命令和 WSTRB 语义说明。
- [ ] 根据 A/C 的综合或上板日志定位 graphics engine、色键掩码和 AXI 协议问题。
- [ ] 若需要修改共享接口，先在群里说明寄存器、信号或所有权语义的变化，再同时修改 RTL、软件、仿真和文档。
- [ ] 暂不把 Alpha Blend、Line 或图片加载加入 v5 验收；这些功能需要新的接口协议和性能目标。

## 6. 失败时的记录方式

发现以下任一情况时先停止继续增加功能，并记录复现条件：版本不匹配、ERROR_CODE 非零、色键透明区域被覆盖、源图被改写、BUSY/WRITER_OWNED 不释放、Swap 超时、HDMI 黑屏、underflow/missed 增长、综合时序不满足。

每次记录包含：硬件提交号、软件 ELF 提交号、模式、命令参数、寄存器读数、调试器变量/可用日志、波形或照片，以及失败发生在综合、启动、绘制、换帧还是持续显示阶段。

## 7. 可直接发给队友的说明

### 发给 A

```text
我这边的 B v5 已接入色键透明复制，当前合同如下：VERSION=0x00050000，CAPABILITIES=0x000000FB，COMMAND_OP=2；RECT_COLOR[23:0] 是 0xRRGGBB 色键，匹配像素用 WSTRB=0 保留 Back，透明拍仍完成完整 AW/W/WLAST/B。源是当前 Front 的绝对 byte 地址，目标写接收时锁存的 Back，普通 BLIT/FILL 语义保持不变。

本机已修复BLIT检查长路径，并用Efinity2026.1.132完成完整编译：core_clk裕量+1.449ns，全局最差建立裕量+0.417ns，bit已生成。硬件仍为v5，请以包含修复的提交号确认来源。麻烦你用当前工程和正式BSP做三项检查：
1. 核对保留接口/工具告警；如自行重建，记录本机最终时序和资源；
2. 重新 Build 与 VERSION/CAPABILITIES 匹配的软件，设置 DEMO_MODE=3；
3. 上板观察左侧普通复制、右侧色键复制、underflow/missed、Swap 和连续运行结果。

预期：右侧紫色背景透明，蓝/绿色 Back 背景保留；g_frame_limit=2时应用完成26条命令，硬件命令/Swap计数相对启动基线增加26/4，色键issued/completed均为2，errors/underflow/missed增量为0。请把报告、调试器结果变量、版本寄存器、诊断计数和照片发回；如果失败请注明发生在综合、启动、绘制、换帧还是显示阶段。
```
### 发给 C

```text
我这边的 B v5 已接入色键透明复制，想请你按接口合同帮忙确认 DDR/Framebuffer 部分：Front 只读、Back 写入，Back base 在命令接收时锁存且只由 wrapper 加一次；128-bit AXI、16-bit WSTRB、AW/W/B 握手和显示写准入保护保持原规则。

请重点验证真实 DDR 对全零/部分 WSTRB 的处理：色键匹配像素应保留 Back 原值，但整拍仍要完成 AW/W/WLAST/B，不能过滤 WVALID 或提前释放 ownership。同时保留旧 FILL/普通 BLIT 回归，观察 reader FIFO、AR/R stall、underflow、missed boundary 和换帧安全条件。

如果 DDR 控制器对 WSTRB=0 有限制，请先给出控制器响应和日志，不要单方面改动 B 的色键语义，我们再一起决定兼容方案。
```

### 发到三人群里的简短版本

```text
v5已完成色键RTL/APB/API、功能仿真、软件构建，以及BLIT长路径修复后的Efinity完整编译/静态时序：core_clk裕量+1.449ns。A核对保留告警、准备匹配BSP软件并上板运行模式3；C验证真实DDR的全零/部分WSTRB、读仲裁、显示连续性和安全换帧。目前还没有v5实板结果。请以包含时序修复的提交为准，共享接口修改先同步，验收记录版本、日志、寄存器、计数和照片。
```
