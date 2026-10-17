# C 与 A/B 的接口合同草案

状态：C 侧实现依据；结合用户给定端口名及 A 最新截图整理。需要三方确认的部分见 QUESTIONS_AB.md。

## 命令接口

| 名称 | 位宽/单位 | 语义 |
|---|---|---|
| op | 32 | 0=FILL_RECT，1=BLIT，其他交 B 报 0x26 |
| x、y | 各 32，像素 | 目标左上角 |
| width、height | 各 32，像素 | 矩形宽高，不能为零 |
| color | 32 | XRGB8888；BLIT 不使用 |
| src_addr | 32，字节 | 源首像素绝对地址 |
| src_stride | 32，字节 | 首轮必须等于 7680 |
| start | 1 | APB 状态检查通过后的单周期提交请求 |
| accept | 1 | manager 最终接受事件，不能用 APB 写完成替代 |

执行时序：A 先在 APB START 时快照八个字段；C 的 accept 当拍，B 锁存这八个字段并开始命令生命周期，C 锁存 Back、Front 校验结果及辅助快照。`src_range_valid` 和 `command_base` 在 accept 的时钟边沿后有效。B 在下一周期的 CHECK 状态使用新结果。源非法仍产生 accept 和一次公共 COMMAND_COUNT；C 不通过源范围检查来屏蔽 accept。

`c_command_service.accepted_*` 是 C 内部保留的该命令快照/辅助输出，不是重新命名团队命令端口。正式 B 不得在 accept 同拍用这些寄存输出替代原始字段，否则采到前一条命令。若 B 选择延迟一级启动，必须把该级纳入公共 busy/ownership，不能吞掉或重复计数。

manager 的接收条件沿用原规则：Front 有效、无 busy/owned、无 swap_pending/同拍 swap_request；本包新增平台 fault/0x25 禁止条件。没有 pending swap 的正常显示 flush 可以接受命令，Front/Back 不变；真实换帧由 pending 阻止新接收。START 在不满足条件时不排队，A 必须保留既有提交前检查和计数确认流程。

## A 最新补充的 CSR 提议

| 偏移 | 名称 | 属性/复位 |
|---|---|---|
| 0xBC | COMMAND_OP | 32 位 RW，CPU/APB reset=0 |
| 0xC0 | SRC_ADDR | 32 位 RW，CPU/APB reset=0 |
| 0xC4 | SRC_STRIDE | 32 位 RW，CPU/APB reset=0 |

原 0x00..0xB8 不重排。三个新寄存器在成功 START 时与矩形参数一起快照。正式启用 BLIT 后提议 VERSION=0x00040000、CAPABILITIES=0x0000007B，新增 bit6；现有值仍为 0x00030000/0x3B。A 需同时更新 accel_api.h 精确匹配值。C 源码包不改变这些寄存器或宣称整机已经具备该能力。

## 地址与范围

画面为 1920×1080，XRGB8888，stride=7680；有效帧大小 0x7E9000。Buffer0=0、Buffer1=0x00800000，各占 8 MiB 槽，有效帧尾部以外不允许读取。

源地址必须不小于 accept 时的 Front base、16 字节对齐；src_stride 必须为 7680。以 64 位 offset=src_addr-front_base 推导 source_row=offset/7680、source_column_bytes=offset%7680；要求 width、height 非零、source_column_bytes+width×4≤7680、source_row+height≤1080，并检查帧尾不超过 32 位地址空间。所有加法/乘法先扩位。

C 的范围模块仅对 op=1 应用源策略，FILL 与非法 opcode 都返回 range=true，由 B 分别执行 FILL 或报告 0x26。B 仍检查目标范围、BLIT 的 x/width 四像素对齐、burst 不跨 4 KiB 等。Front 与 Back 槽分离，因此首轮源目标不重叠；未来资源区/任意 stride 不在本轮能力内。

B 的 AR 是绝对地址，C 不加 base。B 的 AW 是相对 Back 的字节偏移，C 输出 command_base+relative_awaddr，只加一次。Back 基址锁存在 accept，同一条命令不再跟随当前 back_base。

## 读仲裁与显示保护

核心时钟同域，128 位数据，ARADDR32/ARLEN8/RID4/RRESP2。固定侧带由顶层补齐：ID0、SIZE4、INCR、CACHE3、PROT2、LOCK0、QOS0。B 最多 32 beats，显示可达 128 beats。仲裁器假定两侧生成合法地址/burst，不替代各自参数和协议检查。

空闲时选择请求方并寄存 ARADDR/ARLEN；下一周期才对 DDR 提出 AR。选择一经提出保持到 AR 握手。DATA 阶段最多一笔 outstanding，只有正常拍数匹配的 RVALID&&RREADY&&RLAST 才释放 owner。ARLEN=255 的计数宽度也可表示 256，但当前两侧不应发超出各自上限的 burst。

健康水位下两侧同时请求按 round-robin；显示 urgent 时优先显示。priority 模块使用 384/512 滞回；reader 不活跃时不输出 urgent，重新开始低水位补水。仲裁决定一旦形成，不因后续 urgent 改变而抢占已提出请求。此策略只在水位能恢复、DDR/master 能继续握手的条件下保证 BLIT 获得机会，无无条件周期上界。

只给选中侧 ARREADY，RVALID/RDATA/RID/RRESP/RLAST 及反向 RREADY 严格按 owner 路由。RRESP/RID 错误透传给原消费者，由 B/显示 guard 检测并排空；不能按 RID 改选 owner。BLIT 数据不进入显示 FIFO、显示帧计数或写准入的显示读额度。

## 错误与复位

| 错误 | 公共执行层 B 的责任 | C 行为 |
|---|---|---|
| 0x21 | 参数或源窗口非法；计数一次，DONE=1/BUSY=0，无 AR/AW | 正常释放 Back，失败帧不发布 |
| 0x22 | RRESP/RID 错误，排空已接收 burst | 返回原 owner，正常末拍后可释放读 owner |
| 0x23 | BRESP/BID 错误 | 保留已准入写事务完整生命周期 |
| 0x24 | 超时，不能撤回已经提出的 VALID | 不强制清 owner，等待安全排空 |
| 0x25 | RLAST/内部协议故障，进入 FAULT，BUSY 保持 | sticky fault，保留已有 owner，禁止新命令与 swap |
| 0x26 | 未定义 op；计数一次，DONE=1/BUSY=0，无 AR/AW/W | 正常释放 Back，不进入平台 FAULT |

非法 opcode 的 0x26 保持到下一条被接受命令或平台复位；修改参数、CPU/debug reset、CONTROL.bit1 均不能自动清除。该 sticky 错误由 B 公共执行层实现，C 不实现错误寄存器。

协议错误优先于末拍正常释放。arbiter 还检测空闲时无归属 R、AR 尚未接受时异常 R。若 R 与 AR 握手同周期出现，RREADY 仍为零，响应应保持到下一周期。

FAULT 期间已经对 DDR 暴露的 AR 仍保持并允许完成握手，之后 owner 不再释放。已经存在的 R 路由不突然撤销，仍指向旧 owner；原消费者必须按 FAULT 协议停止或保守处理，不能把数据路由给别人。B 应接收 arbiter fault 并进入公共 0x25 状态。FAULT 并非取消 AXI 事务，显示连续供数也不再保证。

所有 C 模块只有平台 rst_n。不连接 CPU/APB reset 或显示 FIFO flush。平台恢复必须同时处理 master、arbiter 和 DDR/互联的在途状态，具体板级复位链须在集成时核实。
