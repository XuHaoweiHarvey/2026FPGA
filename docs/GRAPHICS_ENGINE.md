# 绘图与 DDR 协议

本页合并基础版的 FILL、BLIT、Color Key、源图保护和读写服务说明。寄存器和错误码的完整定义见 [REGISTER_MAP](REGISTER_MAP.md)，内存及所有权见 [ARCHITECTURE](ARCHITECTURE.md)。高级版 Alpha 和队列另见 [高级版寄存器](../starry_demo/advanced_demo/docs/REGISTER_MAP.md)。

## 命令入口与完成

[graphics_engine.v](../basic_demo/rtl/accelerator/graphics_engine.v) 在 START 时取得 op、x/y、width/height、color、src_addr、src_stride 的快照。

| op | 操作 | 行为 |
|---|---|---|
| 0 | FILL_RECT | 完整 XRGB 填充；忽略源地址 |
| 1 | BLIT | 读取合法源，复制到锁定的 Back |
| 2 | Color Key BLIT | 源 RGB24 命中 color 低 24 位时保留目标 |
| 其他 | 不支持 | 接受计数后报 0x26，无 AXI |

尺寸必须非零，目标完全在 1920×1080 内；33-bit 坐标加法检查越界，不裁剪。FILL 的 x/width 无四像素对齐要求；BLIT 的目标 x/width 为四像素倍数。FILL 边缘用每像素四个 byte strobe，保持矩形外像素。

一次命令只锁定一个 Back，不能中途覆盖参数或换帧。COMMAND_COUNT 表示实际接受命令，非法命令也可能计数；它不是成功完成数。DONE sticky，下一条接受时清除，错误退出也可能置 DONE；软件必须同时检查 ERROR_CODE、BUSY=0 和 WRITER_OWNED 已释放。正常 DONE 以最后成功 B 为准，不等待 HDMI 扫描。

## 源范围保护

[blit_source_guard.v](../basic_demo/rtl/framebuffer/blit_source_guard.v) 在接受命令的 T 拍锁存源检查，engine 在 T+1 读取，不能使用尚未更新的组合结果。

普通 Front 源要求：

- 源为当前 Front 的绝对物理地址，16-byte 对齐，stride=7680。
- 每行像素全部在该行内，不能横跨源行，也不能进入 8 MiB 槽尾 padding。
- 整个矩形在 Front 的活动图像区内，所有跨度/结束地址计算检查溢出。
- M2 素材是单独的普通 BLIT 例外，须 READY，且严格匹配三张整图的基址、尺寸和 stride，见 [素材合同](ARCHITECTURE.md#m2-素材装载与封存)。

源保护窗口本身按像素边界验证；DMA 还会执行上述 16-byte 和四像素限制。非法源报 0x21，不发 AR/AW，仍按接受命令记数并释放 Back。

## BLIT DMA 与色键

[blit_engine.v](../basic_demo/rtl/accelerator/blit_engine.v) 先读取一个源段再写目标段，读写 burst 最多 32 个 128-bit beats、各单笔在途，不跨 4 KiB。写地址为相对 Back 地址加 command_base 一次，源地址保持绝对地址，避免重复加 base。

源跨度检查分 CHECK、CHECK_SPAN、CHECK_END、CHECK_RANGE 四拍，保存完整 64-bit 乘积及结束地址。半开结束地址恰为 4 GiB 可合法，超过则拒绝；零高度单独拒绝。参数检查期间 BUSY=1，无 AR/AW。

色键只比较低 24-bit RGB，X 不参与比较且不是 Alpha。命中时对应像素四个 WSTRB 全零；不命中时完整复制 XRGB。全透明 beat 仍完成 AW/W/B，不减少总线 beat，也不读取目标。Back 背景应先由软件构建，Swap 不自动复制背景。

RRESP/RID 或 BRESP/BID 错误会排空当前事务，停止后续段；坏读段不写出。无进展超时不会撤回已暴露的 VALID，完全失应答时可能继续 BUSY。RLAST/拍数协议 FAULT 保留 BUSY 和 Back ownership，防止发布不完整帧，只能平台复位恢复。

## 共享读仲裁

[ddr_read_arbiter.v](../basic_demo/rtl/framebuffer/ddr_read_arbiter.v) 负责显示与 BLIT 的读请求。加入 CPU 后，平台还对 CPU 读进行外层所有权选择；完整连接以 [rgb_framebuffer.v](../basic_demo/rtl/framebuffer/rgb_framebuffer.v) 为准，不能把两客户端原型当作完整 CPU 系统。

- 全局最多一笔读 burst 在途，AR 接受时锁定 owner，整个 R burst 只返回该 owner。
- AR 背压期间地址/长度/sideband 保持，R 背压期间不切换 owner；支持 AR 同拍首个 R。
- 显示默认 128 beats，BLIT 最多 32；仲裁计数支持 1～256 beats。
- FIFO≤384 进入显示紧急优先，≥512 恢复；健康状态轮转，持续紧急时不保证 BLIT 公平等待上界。
- RLAST 必须与预期拍数一致。无 owner 的 R 报本地 fault 1，拍数/RLAST 异常报 fault 2，锁存首个 fault 和原在途 owner，不强行取消。
- RID/RRESP 原样交给 owner 检查，合法拍数的响应错误可排空；共享协议故障映射 READER_ERROR=0x2004，并阻止新命令与换帧。

显示帧/读额度的计数只统计显示客户端 AR/R，不能把 BLIT 或 CPU 的 R 当成显示进度。

## 显示写保护

[ddr_write_admission.v](../basic_demo/rtl/framebuffer/ddr_write_admission.v) 只控制下一笔新 AW 的准入：

| 参数 | 正式值 |
|---|---:|
| WRITE_SERVICE_ENABLE | 1 |
| 上一笔写 B 后的真实显示 R 握手额度 | 128 beats |
| FIFO LOW / HIGH | 384 / 512 个 128-bit words |
| 每笔加速器写 burst | 最多 32 beats |

Reader active 时，额度及水位同时满足才准入。AW 一旦暴露，grant 保持到 B，即使水位下降也不撤回 VALID；W/B、AR/R 不被该策略中断。写进行中的 R 不预付下一笔额度，reader launch/flush 清新额度；reader 完整结束且 safe 时可用 slack 继续写。

FIFO_LEVEL 是真实 core 写侧存量；RESERVED_BEATS−DATA_BEATS 是尚欠的 R，不是存量。LOW 对应 6144 bytes、约 10.34 µs 的 active 视频名义余量，不构成未知 DDR 最坏延迟保证。持续显示稳定性须结合 underflow/missed 的增量验证。

## 调试与复现

基础版的软件 API 在 [accel_api.h](../basic_demo/software/basic_demo/accel_api.h)。运行现役软件与测试的方法见 [BUILD](BUILD.md) 和 [VALIDATION](VALIDATION.md)。发生故障先保存错误码、owner、pending、读帧和 FIFO 状态；不要强制解锁、取消事务或清历史计数后继续发布画面。
