# 接入现有工程

本包未自动改写 `rgb_framebuffer.v`、`ti60f225_oob_top.v` 或 Efinity 清单。原因是正式 B 公共执行层及 A 新命令输出尚未存在于核对的工作树中；完整接线不能用虚构模块名补齐。本包的 C 模块及仿真可以先独立使用。

## 1. 命令与 manager

在 `rgb_framebuffer.v` 的 D_MODE 分支中，用 `c_command_service` 替换原 `buffer_manager` 实例。不要同时保留两个 manager。

原有信号对应：clk=axi_clk、rst_n=axi_rst_n、writer_busy/ done/error=未来 B 公共执行层结果，start=团队 start 请求；swap_request/clear_done/boundary_tick/blank_active/reader_safe/reader_fifo_empty 沿用原线。将封装的 front/back/owned/status/reader_flush/reader_launch/count 输出接回原 manager 的输出位置。C 的辅助 accepted_* 不必接 APB。

团队 op/x/y/width/height/color/src_addr/src_stride 接入 C 和 B；accept 接 B 启动许可。`src_range_valid` 接 B 新增的源范围检查输入。B 必须在 accept 后的 CHECK 阶段检查，不得当拍使用上条命令的结果。

将 B `error_code==0x25` 接 arbiter.external_fault；将 arbiter.fault 接 command_service.read_fault，同时送 B 公共执行层故障输入。command_service.platform_fault 是 sticky 全局故障，应纳入公共状态报告。没有活动命令时如何向 A 呈现显示侧读故障，见待确认清单。

## 2. Back 写地址与准入

原 `awaddr=owner_accel ? a_awaddr+d_command_base : t_awaddr` 改为：初始化写仍用 t_awaddr；加速器写使用 C 的 absolute_awaddr。relative_awaddr 接 B 的 a_awaddr，不再在其他地方叠加 base。

继续保留原 `ddr_write_admission`。不要把绝对地址封装误认为 AW 准入器。原 owner_accel 初始化交接、AW 门控、W/B 回传均保留。B 的读服务不依赖 writer_admit。已经暴露的 AW/W 不应被新的 fault 直接截断；停止新事务由 B 执行层及既有准入状态机完成。

## 3. 共享读通路

将原 reader 直接连接物理 DDR 的 AR/R 拆成 reader 侧 `d_*` 和物理侧 `m_*`，增加 BLIT 的 `b_*`。

| 现有连接点 | 新连接 |
|---|---|
| u_ddr_rd_buffer 的 araddr/arlen/arvalid/arready | arbiter.d_araddr/d_arlen/d_arvalid/d_arready |
| u_ddr_rd_buffer 的 rdata/rid/rresp/rlast/rvalid/rready | arbiter.d_* 对应响应信号，RID 仍按原实例零扩展到 6 位 |
| B 公共执行层的读端 | arbiter.b_* |
| 对外 DDR araddr/arlen/arvalid/arready | arbiter.m_* |
| 对外 DDR rdata/rid/rresp/rlast/rvalid/rready | arbiter.m_* |
| ARID/ARSIZE/ARBURST/ARCACHE/ARPROT/ARLOCK/QOS | 统一固定侧带，避免 reader 输出与常量重复驱动 |

读仲裁器与两个 master 都在 axi_clk/core 域；不新增 CDC。显示 FIFO reset 仍由原有逻辑产生，仅重置显示 FIFO，不接入 arbiter.rst_n。

## 4. 显示 guard 与统计隔离

`read_frame_guard` 的 AR/R 全部改成观察 `d_*`，地址/长度也是 reader 侧；其固定 size=4、burst=1 保持。不能继续观察物理 `m_*`，否则 BLIT 会被累计进 518400 beats/frame。

`ddr_write_admission` 的 arvalid/arready/rvalid/rready 同样改接 `d_*`，reader_outstanding 仍来自显示 guard。这样 BLIT 读不产生显示读额度。display frame completion、AR/R stall 诊断都维持显示语义。

新增 arbiter.display_bursts、blit_bursts、blit_wait_cycles 是辅助输出，当前没有分配 APB offset；不能覆盖旧诊断寄存器。blit_wait_cycles 是累计等待周期且饱和，不是最大单次等待时间。

`c_display_read_priority` 接现有同步到 axi_clk 的 reader_fifo_level 与 d_active，输出 display_urgent 给 arbiter。默认阈值与现有保护一致；实际板级流量验证前不宣称该策略满足完整 1080p 带宽。

## 5. 编译清单与工程变更

新增五个 `rtl/c_*.v`；正式工程使用时可放入 `rtl/framebuffer/`，同步调整源清单。`reference/` 与 `sim/` 不加入综合清单，原正式 DDR/PHY/PLL/HDMI 和生成 IP 不动。`rtl/files.f` 是本包根目录下的仿真/检查源列表，不是可以直接替代 Efinity 工程 XML 的文件。

`c_front_range_guard` 使用常数除法/取余实现严格行列检查；可综合性不等于满足 100 MHz 时序。综合后必须检查该路径的资源与延迟，若需要流水化，应增加明确的检查阶段并继续保证发 AR/AW 前检查完成。

## 6. 系统验收顺序

1. A 提供正式命令输出，B 提供公共执行层及故障/范围输入，按上表连接。
2. 运行本包测试与原工程完整 C/D/RGB/APB 回归；本包不替代原整机回归。
3. 验证 FILL→BLIT→FILL、非法 op、源范围失败、CPU reset 不取消 DMA。
4. 构造 Front 四色图，复制到 Back，等待 ERROR=0、DONE=1、BUSY=0、WRITER_OWNED=0，再显式 swap。
5. 并发运行时记录 underflow/missed 的 baseline/value/delta，并验证显示低水位恢复与 BLIT 等待上限。
6. Efinity 综合、布局布线、时序、DDR/HDMI 实板检查，最后才由 A 更新正式版本/能力标志并联合签收。

本包 `tb_c_blit_integration` 中的延迟一级/非法范围转 width=0 是测试适配器，仅用于连接未带 src_range_valid 的原型。它没有实现正式 op 分发、统一错误/计数或 APB，不能复制成生产公共执行层。
