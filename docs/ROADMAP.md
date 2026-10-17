# Roadmap

## Starting Point

Phase 2基础框架已完成并由负责人实际验收A～E。**FILL_RECT、双缓冲、safe swap和显示保护已实现，不是TODO。** 后续 BLIT 已新增独立 RTL 原型和单元仿真，运行及限制见 [BLIT](BLIT.md)；正式系统和实板集成仍待完成。

B 的 [FILL/BLIT 统一入口](GRAPHICS_ENGINE.md) 已按A/C反馈支持最终accept、src_range_valid和0x26，通过85个混合命令用例与7个真实manager合同用例；另通过两组各11场景的双缓冲绘制/复制/换帧闭环，每组20条命令与8次换帧。正式寄存器/顶层、C源窗口检查器与读仲裁尚未接入，闭环中的边界/reader-safe/内存为模型。

依据仓库 [2026 FPGA赛道选题指南（易灵思）](../docs_reference/全国大学生嵌入式芯片与系统设计竞赛'2026FPGA赛道选题指南-易灵思.pdf) 的“赛题二”，PDF第7～9页：基础要求含Block Copy/Solid Fill、总线burst/FIFO、双缓冲驱动与软硬渲染对比；高阶含Alpha、Color Keying和高负载互动Demo。Line属于团队可选扩展，不是该段列明的基础必做项。

## Scope and Priority

| 优先级 | 工作 | 当前状态 / 完成出口 |
|---|---|---|
| 基线 | Solid Fill / FILL_RECT、DDR显示、RISC-V/APB、Front/Back、safe swap、连续性保护 | **Done，A～E实板通过** |
| Phase 3首要 | Block Copy / BitBlt / BLIT | 独立 RTL 原型已通过单元仿真；仍需完成 DDR 源图、软件配置、显示仲裁和实板验收 |
| Phase 3前置 | Accelerator DDR read与Display Reader仲裁 | Not implemented；显示服务优先且两方最终进展，不能影响已提交AXI响应归属 |
| Phase 3演示/测量 | 资源图像加载、纯软件/硬件渲染对照与板级性能统计 | Not implemented；测量条件/耗时/像素工作量可复现，不把仿真速度当实测 |
| 后续高阶 | Alpha Blend、Color Keying | Not implemented；透明/不透明端点、舍入/饱和/色键跳过与Back ownership均验证 |
| 后续可选 | Line与进一步命令扩展 | Not implemented；独立确定几何/边界、接口与测试 |
| 依测量决定 | FIFO/burst调优、line buffer/cache、DDR带宽优化 | Planned；有性能瓶颈证据后再做，保留显示保护 |
| 综合演示 | 高负载互动图形/游戏，比较CPU负载、FPS和活动元素规模 | Planned；基础Block Copy/驱动/资源通路完成后推进 |

## Phase 3: Block Copy / BLIT

### 开码前必须约定

1. 命令类型、source/destination地址或slot含义、width/height、src/dst stride，所有DDR地址继续用byte单位；既有CSR不重排，新接口走团队变更流程。
2. source图像存放范围与加载方式。当前CPU没有DDR端口，不能假定已有图片资源上传路径。
3. source/destination对齐、每行padding、越界检查、重叠区域语义（拒绝还是memmove式处理）。**TODO / Needs confirmation：未定义，不假设已支持。**
4. 新AR/R master与Display Reader的仲裁、ID/响应归属、outstanding上界、FIFO容量、低水位urgent及公平性；不能直接OR两个master。
5. DONE需涵盖所有读/写事务与最后成功B；超时不撤回VALID。Back base在命令开始时锁存，pending阻止新命令。

### 分工和验收

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
