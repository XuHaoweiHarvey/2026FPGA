# Roadmap

Phase 3 进度：M0 基线已独立归档；M1a CPU→DDR 桥、会话锁和 OCRAM 烟测已实现，RTL/软件检查及 Efinity 完整编译通过，项目负责人于 2026-10-21 确认实板验收通过。M1a 尚未提交为 Git commit，合并后目标目录的重建复验仍待完成。M1b 的公平 CPU/FPGA 渲染对比尚未开始；独立 Sprite atlas、Alpha 和游戏均未实施。具体证据与限制见 [M1A_CPU_DDR](M1A_CPU_DDR.md)。

## Starting Point

Phase 2基础框架已完成并由负责人实际验收A～E。**FILL_RECT、双缓冲、safe swap和显示保护已实现，不是TODO。** BLIT及Color Keying已接入当前v5正式工程、软件API和演示流程。色键共享DDR系统RTL和软件构建通过，CPU指令仿真受权限限制未执行；2026-10-19修复BLIT长路径后已通过当前约束下Efinity综合/静态时序，见[V5_TIMING_FIX](V5_TIMING_FIX.md)。已归档三轮全屏实测和最终色键画面，范围与剩余验收见[V5_BOARD_BENCHMARK](V5_BOARD_BENCHMARK.md)。v4历史软件行为检查见[SYSTEM_BLIT](SYSTEM_BLIT.md)。

[FILL/BLIT 统一入口](GRAPHICS_ENGINE.md)、[源窗口检查器](BLIT_SOURCE_GUARD.md) 和 [显示/BLIT读仲裁器](DDR_READ_ARBITER.md) 已接入正式Framebuffer/APB/top工程。独立模块、双缓冲闭环和带真实显示Reader/FIFO的共享DDR系统仿真通过；历史v4软件 `DEMO_MODE=2` 的实际RV32 ELF行为检查通过，当前v5的静态时序及部分实板证据见上文。

依据仓库 [2026 FPGA赛道选题指南（易灵思）](../docs_reference/全国大学生嵌入式芯片与系统设计竞赛'2026FPGA赛道选题指南-易灵思.pdf) 的“赛题二”，PDF第7～9页：基础要求含Block Copy/Solid Fill、总线burst/FIFO、双缓冲驱动与软硬渲染对比；高阶含Alpha、Color Keying和高负载互动Demo。Line属于团队可选扩展，不是该段列明的基础必做项。

## Scope and Priority

| 优先级 | 工作 | 当前状态 / 完成出口 |
|---|---|---|
| 基线 | Solid Fill / FILL_RECT、DDR显示、RISC-V/APB、Front/Back、safe swap、连续性保护 | **Done，A～E实板通过** |
| Phase 3首要 | Block Copy / BitBlt / BLIT | v5共享RTL/软件构建/静态时序通过，已有三轮全屏实测；接口告警、板级边界与长期验收待完成 |
| Phase 3前置 | Accelerator DDR read与Display Reader仲裁 | 已接正式Framebuffer，共享显示并发/故障仿真通过；全屏实测错误增量0，板级最坏服务等待与长期诊断待采集 |
| Phase 3演示/测量 | 资源图像加载、纯软件/硬件渲染对照与板级性能统计 | 已归档模式4第一轮总结果及三轮全屏数值；CPU软件对照仍未实现，优先评估原生内存端口，见[CPU_RENDER_PLAN](CPU_RENDER_PLAN.md) |
| 高阶系统实现 | Color Keying | v5系统RTL/软件构建/静态时序通过，模式3照片和模式4终态符合预期，已有三轮全屏实测；其他验收见[实板记录](V5_BOARD_BENCHMARK.md) |
| 后续高阶 | Alpha Blend | Not implemented；透明/不透明端点、舍入/饱和与Back ownership均验证 |
| 后续可选 | Line与进一步命令扩展 | Not implemented；独立确定几何/边界、接口与测试 |
| 依测量决定 | FIFO/burst调优、line buffer/cache、DDR带宽优化 | Planned；有性能瓶颈证据后再做，保留显示保护 |
| 综合演示 | 高负载互动图形/游戏，比较CPU负载、FPS和活动元素规模 | Planned；基础Block Copy/驱动/资源通路完成后推进 |

## Phase 3: Block Copy / BLIT

### 已冻结的首轮接口与后续待办

1. 已采用 `op=1`、Front绝对byte地址、`width/height`和`src_stride=7680`；目的地为锁存Back，FILL/BLIT共用既有寄存器/执行入口，契约见 [REGISTER_MAP](REGISTER_MAP.md)。
2. 当前源图由软件通过FILL在Back构造后swap到Front；CPU没有DDR端口。通用图片资源加载路径仍未实现。
3. 当前BLIT约束为16-byte源地址对齐、有效Front窗口内不跨源行；目的x/width四像素对齐；目的矩形越界拒绝。任意源/目的stride与重叠复制未作为正式平台能力开放。
4. 显示Reader和BLIT读master已由共享读仲裁器接线，限定burst、固定响应owner、FIFO低水位显示优先和健康状态轮转；系统并发已仿真，板级最坏等待/实时性仍待测。
5. DONE覆盖读/写事务与最后成功B，超时不撤回VALID；Back base在接收时锁存，pending阻止新命令。新v4软件会检查版本并等待完成后显式swap。

### 后续协作和验收

团队当前按完整任务推进，不再限定A/B/C目录归属。开工时说明目标和涉及文件，避免并行修改同一模块；寄存器、地址、ownership及总线合同的变化随实现一起更新，功能、仿真和实板证据分别记录。

至少验证非对齐像素/byte lane、不同stride、4KiB切分、首末边缘、反压、错误、超时排空和源/目标保护；并发完整1080p显示与大量BLIT，稳态underflow/missed不增长、writer/reader均进展，swap后整帧一致。保留原FILL_RECT全部回归。

## Software Comparison and Hardware Performance

赛题要求软/硬渲染FPS对比，当前基础Demo尚无该对照。当前Sapphire是控制专用OCRAM配置，生成公开端口只有APB，没有DDR master。下一阶段优先核实IP Manager导出原生CPU内存端口的能力，再实现访问适配、绘图会话ownership与相同场景对照；APB像素窗口作为注明传输限制的备选。具体依赖、接口边界与分阶段出口见[CPU_RENDER_PLAN](CPU_RENDER_PLAN.md)。

软件`DEMO_MODE=4`已实现固定工作量的硬件端入口：四种尺寸、三种操作，CLINT 64位计时，分离准备/预热、绘制和swap；保持原DDR显示保护并检查错误/计数。本机原生C行为检查和BSP构建通过，三轮全屏真实数据已归档。它提供轮询API耗时与矩形像素吞吐，不代表屏幕FPS、CPU占用率或完整软硬件对照，见[BENCHMARK](BENCHMARK.md)和[实板记录](V5_BOARD_BENCHMARK.md)。

先定义可复现的计时点、字节/像素工作量、场景、CPU工作量、是否包含swap/hold、测量窗口与重复次数，再报告板级结果。显示最低平均读payload497.664MB/s，必须同时关注实时延迟、FIFO和missed，而不是只报Writer峰值。

历史约130～52MB/s属于**Simulation Result**。目前已有持续显示条件下的实板API矩形吞吐：全屏FILL约33.10MPixel/s，普通/色键BLIT约31.58MPixel/s；它们不是DDR带宽。Efinity资源/静态时序见[V5_TIMING_FIX](V5_TIMING_FIX.md)，完整证据与待补项见[VALIDATION](VALIDATION.md)。

## Alpha / Color Keying / Line

当前XRGB8888的X被忽略，不能直接称为Alpha。**TODO / Needs confirmation：未来Alpha来源、输入格式、混合范围、整数精度/舍入/饱和规则。** 先保持现有framebuffer契约，必要的新资源格式单独定义。Color Keying应有明确色键比较和跳写语义，矩形外/透明像素保持不变。

Color Keying已完成独立执行层、统一入口和正式v5系统接线：精确比较RGB24、忽略X，透明像素关闭四个byte strobe，保留Back内容；全透明拍仍完成总线握手。复用原BLIT且不增加目的读通道，独立53场景、统一入口76/74场景记录保留，新增正式共享显示/换帧RTL与API/模式3构建通过。v5发布op2和能力bit7；模块默认关闭保留v4。当前CPU指令行为检查受权限限制跳过，静态时序通过；模式3对比照片、模式4终态及全屏性能证据已收到，其余验收范围见[COLOR_KEY](COLOR_KEY.md)和[实板记录](V5_BOARD_BENCHMARK.md)。

Line应作为独立图元规定端点包含、方向、裁剪或拒绝、颜色和错误语义；不是借规划顺手修改现有FILL。line buffer/cache只在真实瓶颈和资源预算明确后采用。

## Exit Policy

每项任务独立给出接口评审、RTL/软件测试、Compile时序/资源与实板验收记录。当前README只列已实现能力；未完成的新命令保持Planned，不以新增文档或单纯仿真宣布硬件完成。
