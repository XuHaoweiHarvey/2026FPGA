# Roadmap

## Starting Point

Phase 2基础框架已完成并由负责人实际验收A～E。**FILL_RECT、双缓冲、safe swap和显示保护已实现，不是TODO。** BLIT现已接入v4正式工程、软件API和演示流程，模块/共享DDR系统/软件行为仿真通过；Efinity综合时序和新v4实板验收仍待完成，见 [SYSTEM_BLIT](SYSTEM_BLIT.md)。

B 的 [FILL/BLIT 统一入口](GRAPHICS_ENGINE.md)、[C侧源窗口检查器](BLIT_SOURCE_GUARD.md) 和 [显示/BLIT读仲裁器](DDR_READ_ARBITER.md) 已接入正式Framebuffer/APB/top工程。独立模块、双缓冲闭环和带真实显示Reader/FIFO的共享DDR系统仿真通过；软件 `DEMO_MODE=2` 的实际RV32 ELF行为检查通过。全帧DDR/HDMI IP、综合时序和v4硬件尚未实测。

依据仓库 [2026 FPGA赛道选题指南（易灵思）](../docs_reference/全国大学生嵌入式芯片与系统设计竞赛'2026FPGA赛道选题指南-易灵思.pdf) 的“赛题二”，PDF第7～9页：基础要求含Block Copy/Solid Fill、总线burst/FIFO、双缓冲驱动与软硬渲染对比；高阶含Alpha、Color Keying和高负载互动Demo。Line属于团队可选扩展，不是该段列明的基础必做项。

## Scope and Priority

| 优先级 | 工作 | 当前状态 / 完成出口 |
|---|---|---|
| 基线 | Solid Fill / FILL_RECT、DDR显示、RISC-V/APB、Front/Back、safe swap、连续性保护 | **Done，A～E实板通过** |
| Phase 3首要 | Block Copy / BitBlt / BLIT | 正式v4工程、软件API/演示已接线；模块/共享DDR和CPU行为仿真通过；Efinity资源/时序及实板验收待完成 |
| Phase 3前置 | Accelerator DDR read与Display Reader仲裁 | 已接入正式Framebuffer；共享显示并发与故障保护仿真通过；需A/C在正式工具链与板卡验证 |
| Phase 3演示/测量 | 资源图像加载、纯软件/硬件渲染对照与板级性能统计 | Not implemented；测量条件/耗时/像素工作量可复现，不把仿真速度当实测 |
| 后续高阶 | Alpha Blend、Color Keying | Not implemented；透明/不透明端点、舍入/饱和/色键跳过与Back ownership均验证 |
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

### 后续分工和验收

A整理新命令API/驱动/资源与对照Demo；B实现复制执行和读写流水线；C负责DDR read服务仲裁、显示保护与诊断。三人先审接口再各自实现。

至少验证非对齐像素/byte lane、不同stride、4KiB切分、首末边缘、反压、错误、超时排空和源/目标保护；并发完整1080p显示与大量BLIT，稳态underflow/missed不增长、writer/reader均进展，swap后整帧一致。保留原FILL_RECT全部回归。

## Software Comparison and Hardware Performance

赛题要求软/硬渲染FPS对比，当前基础Demo尚无该对照。**TODO / Needs confirmation：CPU对照的内存访问路径和公平测量方案。** 当前Sapphire是控制专用OCRAM配置，不能未经设计就宣称可直接CPU写DDR；未来基准测试与正常“CPU只提交命令”的渲染模式需明确边界和所有权。

先定义可复现的计时点、字节/像素工作量、场景、CPU工作量、是否包含swap/hold、测量窗口与重复次数，再报告板级结果。显示最低平均读payload497.664MB/s，必须同时关注实时延迟、FIFO和missed，而不是只报Writer峰值。

目前约130～52MB/s是**Simulation Result**，没有现成的板级实际吞吐数据。资源、时序、带宽与延迟表待实际测量填入[VALIDATION](VALIDATION.md)。

## Alpha / Color Keying / Line

当前XRGB8888的X被忽略，不能直接称为Alpha。**TODO / Needs confirmation：未来Alpha来源、输入格式、混合范围、整数精度/舍入/饱和规则。** 先保持现有framebuffer契约，必要的新资源格式单独定义。Color Keying应有明确色键比较和跳写语义，矩形外/透明像素保持不变。

Line应作为独立图元规定端点包含、方向、裁剪或拒绝、颜色和错误语义；不是借规划顺手修改现有FILL。line buffer/cache只在真实瓶颈和资源预算明确后采用。

## Exit Policy

每项任务独立给出接口评审、RTL/软件测试、Compile时序/资源与实板验收记录。当前README只列已实现能力；未完成的新命令保持Planned，不以新增文档或单纯仿真宣布硬件完成。
