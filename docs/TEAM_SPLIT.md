# Team Split

A～E实板验收通过，Phase 2基础框架是三人后续开发的冻结基线。职责归属用于避免同时改共享边界，不代表可绕过生成IP/物理配置的变更审查。

## Person A — RISC-V / Control / Software

| 项目 | 责任 |
|---|---|
| 拥有目录 | software/apb_reg_test/、rtl/control/；对应软件构建/IDE准备/软件测试脚本 |
| 模块/任务 | Sapphire控制岛集成、BSP使用、APB driver、accel API、command submission、polling、Demo与软件验证 |
| 对外接口 | 对B：参数/START/status/error；对C：buffer查询、swap ticket、诊断baseline/delta |
| 不应单方修改 | engine/AXI核心、FrameBuffer/显示时序、writer admission；生成Sapphire/BSP和成功OpenOCD/launch默认只读 |
| 联调出口 | ID/版本/SCRATCH正确，合法命令与ERROR语义一致，超时快照可解释，无CPU逐像素写DDR |

维护入口是software/apb_reg_test/main.c、accel_api.h、accel_regs.h、demo_config.h和rtl/control/sapphire_control.v/accel_regs.v。embedded_sw/soc_control中的soc.h/default.ld/start.S属于生成来源，不手改地址来适配软件。需要SoC功能变化时先共同定义配置影响，再由指定人员Generate。

## Person B — 2D Accelerator

| 项目 | 责任 |
|---|---|
| 拥有目录 | rtl/accelerator/；对应sim/tb_fill_rect_writer.v及未来执行单元测试 |
| 模块/任务 | 命令执行、FILL_RECT、地址生成、WSTRB/4KiB/burst、AXI AW/W/B；后续获准开发的BLIT/Line/Alpha |
| 对外接口 | A的命令快照/完成/错误；C的相对byte地址AXI、锁存Back、读写准入与排空 |
| 不应单方修改 | CSR offset/颜色格式、buffer地址与角色、swap/reader、DDR/PHY/PLL/HDMI；不能绕过准入直连DDR |
| 联调出口 | 独立像素记分板、几何/非对齐边缘、反压与错误、最后B前不成功DONE、超时VALID保持 |

当前fill_rect_writer仅生成相对frame地址；物理Back偏移由C wrapper加一次。新的DDR读master需要与C共同设计，不能由B直接复用Reader响应或OR总线。

## Person C — DDR / Framebuffer / Display

| 项目 | 责任 |
|---|---|
| 拥有目录 | rtl/framebuffer/、rtl/frame_buffer_V4/、rtl/display/、rtl/user_cvo_axi_v2/及相关显示/交换测试 |
| 模块/任务 | DDR集成、reader/unpack/CVO、Front/Back、buffer_manager、VBlank-safe swap、CDC、连续性保护与诊断 |
| 对外接口 | A的buffer/swap/诊断；B的Back锁存、AXI连接、显示优先准入及未来读服务仲裁 |
| 不应单方修改 | APB/软件契约、engine算法；DDR/PHY、PLL、HDMI encoder、physical/pins等已验证继承/生成实现默认只读 |
| 联调出口 | 旧R排空与safe boundary，Front读/Back写，writer/reader均进展，最终HDMI完整帧、无稳态underflow/missed |

`rtl/ddr3_controller/`和`rtl/dvi_tx/`由C负责集成核对，**责任归属不等于允许手改厂商实现**。Camera/DSI物理块仍保留；时钟名不能作为删除依据。

## Shared Files and Read-only Areas

| 区域 | 管理规则 |
|---|---|
| rtl/ti60f225_oob_top.v、ti60f225_oob.xml/.sdc/.peri.xml、package_settings.xml、constraints/ | 指定集成人统一接线/更新源清单与约束，三人先同步，避免同时编辑 |
| docs/INTERFACES.md、REGISTER_MAP.md | 共享合同；与代码变更同时更新 |
| docs/BUILD.md、VALIDATION.md | 集成/验证负责人汇总，A/B/C各提供自己范围的证据 |
| ip/、embedded_sw/生成部分、DDR/PHY/PLL/encoder | 默认只读；确需Generate/物理改动时单独安排，重新核对端口/地址/时序/硬件 |
| software/apb_reg_test/openocd/及apb_reg_test_ti.launch | A保管成功配置，正常模块开发不改；换工作路径时按BUILD核对 |
| demo/、docs_reference/ | 保留原始参考，不随功能开发覆盖 |

## Shared Interface Change Policy

以下接口冻结，任何提出变化的人须先通知另外两人，说明旧值、新值、影响两侧、兼容策略和回归/硬件验收方法；达成一致后同步实施。

| 接口 | 当前契约 |
|---|---|
| Pixel / color | XRGB8888，X非Alpha，低地址B/G/R/X，beat低32bit P0 |
| Geometry / address | 1920×1080、stride7680bytes、frame0x7E9000；所有DDR地址byte单位 |
| APB Register Map | 00..B8，32bit整字；ID4143434C、VERSION00030000，现有offset不重排 |
| Command | 五参数和Back base接收时快照，busy/owned/pending拒绝新START |
| AXI | address32/data128/WSTRB16、ID0、SIZE4/INCR，原写最多32beats/一个outstanding |
| Ownership | Front≠Back，Buffer0/1=0/00800000；只读Front、只写锁存Back |
| Swap | 显式REQUEST，旧帧全R/idle、safe boundary、FIFO empty后提交；sticky DONE+ticket，无隐式copy |
| DONE / error | 最后成功B后完成，ERROR不能当成功；超时不撤回VALID |
| Display protection / CDC / reset | 128真实R、384/512滞回、准入至B；CPU reset不复位平台DMA，base不裸跨域 |

不能只改端口一侧、只改文档、偷偷更换单位或把未实现能力标为完成。新的opcode、source address、Alpha格式、读仲裁都属于共享接口变更；先定义后编码。

## Integration Workflow

1. 约定任务边界与验收出口，复用当前FILL_RECT和显示保护基线。
2. A/B/C在主责模块内独立开发和测试；共享顶层/工程清单由指定集成人更新。
3. 联调先核对软件参数/计数与命令快照，再核对AXI和buffer ownership，最后做完整视频并发与视觉验收。
4. 每个功能在VALIDATION补充Simulation和Hardware各自证据；吞吐必须注明理论/仿真/实测及计量范围。
5. 通过后更新README当前能力和ROADMAP状态，不把计划功能提前写成支持。

本次只整理文档，没有发送团队消息、修改共享代码或执行提交/push/merge/reset；后续任务由团队独立安排。
