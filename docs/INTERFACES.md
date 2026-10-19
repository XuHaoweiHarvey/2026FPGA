# Interfaces — 冻结接口合同

Phase 2旧FILL/v3已实板验收通过。当前源码在BLIT合同上扩展为v5色键复制，需重新综合和上板。此文是Person A/B/C协作合同；寄存器唯一详细定义见[REGISTER_MAP](REGISTER_MAP.md)，色键接线见[COLOR_KEY](COLOR_KEY.md)。

## Frozen Contract

| 契约 | 当前值 / 必须保留的语义 |
|---|---|
| Pixel/color | XRGB8888，0xXXRRGGBB；X忽略，低地址B/G/R/X；不是ARGB |
| Geometry | 1920×1080、4bytes/pixel、stride7680bytes、frame0x7E9000bytes |
| Buffers | 0与00800000，8MiB槽；Front≠Back；读Front、写锁存Back |
| APB | 32-bit、byte offset、4byte对齐、无PSTRB/中断；00..B8不重排 |
| Identity | ID4143434C、VERSION00050000、CAPABILITIESFB；关闭COLOR_KEY_ENABLE保留v4/7B，关闭BLIT为旧v3 |
| Command | START快照五参数及op/src_addr/src_stride，accept锁存Back/source结果；busy/owned/pending/读故障不接受新START |
| AXI | address32为byte单位，data128、WSTRB16、ID4且0、AXSIZE4、INCR；写最大32beats，一个outstanding |
| DONE | 最后成功B后、错误为0、BUSY/owned释放；不是已显示完成 |
| Swap | 显式请求、sticky DONE+count ticket；safe boundary且旧R/流水线结束、FIFO清空确认后提交 |
| Display protection | 128真实R quota、FIFO384/512滞回、新AW准入锁存至B；不门控W/B/AR/R |
| Reset/CDC | CPU reset不复位平台DMA；toggle/Gray/原FIFO CDC；base不裸跨域 |

任何一项变化必须在实现前同步另外两人，并同时更新对应两侧RTL/软件/文档/验证。不能只改信号一端、换单位或绕开保护。

## A ↔ B: APB / Command / Accelerator Status

### APB Register Contract

`io_apbSlave_0_PADDR[15:0]`由sapphire_control零扩展32位；PSEL/PENABLE/PWRITE/PWDATA[31:0]请求，PRDATA[31:0]/PREADY/PSLVERROR响应。与CPU、engine同为core_clk100MHz，无额外APB CDC。

写副作用只发生于`PSEL && PENABLE && PREADY`；默认一个wait，setup/wait不重复写。错地址/写RO/非法START仅在完成access时报告PSLVERROR并记录APB错误，不产生目标命令。整字MMIO，软件fence；不要测试非法APB来假定CPU trap恢复已支持。

Base使用正式BSP宏IO_APB_SLAVE_0_INPUT/IO_APB_SLAVE_0_INPUT_SIZE，当前F8100000/10000；不硬编码Demo08 fallback。CPU只访问寄存器，当前无DDR framebuffer访问端口。

### Command Interface

accel_regs快照`cmd_x/cmd_y/cmd_width/cmd_height/cmd_color/cmd_op/cmd_src_addr/cmd_src_stride[31:0]`，输出一周期`start_pulse`；sapphire_control对外命名`start_test_pulse`。manager产生最终command_accept，graphics_engine只在accept时启动，manager同拍锁存command_base，源检查器同拍锁存范围结果，engine下一拍读取。op=0 FILL，1 BLIT，2色键复制，其他值接受后报0x26。色键沿用全部BLIT源/目标约束，cmd_color低24位为精确RGB key，匹配时保留Back原像素；高8位忽略。顶层同一COLOR_KEY_ENABLE同时控制APB能力和Framebuffer执行路径。

接收要求INIT_DONE、有效Front、非BUSY、非writer_owned、无swap_pending/同拍swap_request。x/y/width/height单位pixel；宽高非零且完全在画面内，不裁剪；color按XRGB字定义。API先等COMMAND_COUNT增加确认接收，再单独wait_done，避免旧sticky DONE。短命令可能在CPU读BUSY前结束，软件不要求一定采样到BUSY=1。

### Status and Error

engine输出busy、done、error_code、command_count。命令完成需成功B，错误也可能done；软件每次轮询检查ERROR_CODE，再检查DONE/BUSY与WRITER_OWNED。COMMAND_COUNT实际计engine接收次数，非法几何也计数，不等于成功完成数。

当前单CPU、单命令串行，没有队列或interrupt。软件返回0、实际硬件错误或E0xx/E1xx软件错误；失败保存结果后停止提交，不通过CPU reset撤销AXI。完整清除优先级和错误码见寄存器表。

## B ↔ C: AXI / Address / Ownership / Service

fill_rect_writer生成**相对frame**的byte地址。C的wrapper只加一次锁存command_base；不能在B里再次加物理Back地址。AW受背压时参数和base稳定。

| 通道 | 信号 / 规则 |
|---|---|
| AW | AWADDR32、AWLEN8；VALID保持到READY，最多32beats，不跨4KiB |
| W | WDATA128={P3,P2,P1,P0}、WSTRB16、WLAST、VALID/READY；每pixel占连续4个byte strobe，保护矩形外像素 |
| B | BID4/BRESP2/BVALID/BREADY；每burst等待B后才下一笔；BID必须0、BRESP必须OKAY |
| 固定sideband | AW/AR ID0、SIZE4、INCR、CACHE3、PROT2、LOCK0；QOS保持原值0 |
| AR/R（当前） | Display/BLIT共享读仲裁，128bit R、ID0、全局一笔outstanding；显示最多128beats、BLIT最多32beats |

B负责合法AXI状态机、几何、地址、strobe及错误/超时安全排空。C负责地址偏移、初始化owner mux、reader、buffer manager、显示服务准入和CDC。上电TPG与engine AW/W/B统一二选一，不能OR；原TPG最后B/流水线完整结束后才永久交接。

色键命令允许部分或全零WSTRB，仍必须完成原AW长度对应的全部W和最后B；不可过滤WVALID或提前释放Back。此版本不减少透明拍的DDR事务数，不新增目的背景读通道，真实DDR控制器的零strobe行为待板级确认。

Reader active时每笔写B后，128个真实R握手及FIFO健康水位满足才准入新AW。已准入AW保持至B，不因低水位/新launch撤回；W/B和AR/R直通。整帧reader safe的slack允许有限事务继续前进；错误停止新准入。B不得绕过门控直连DDR，C不得通过截断已有事务保证显示。

BLIT源为Front绝对字节地址，写仍为相对Back地址。读仲裁按burst锁owner，R只返回原方；低水位显示优先，健康时轮流。显示guard、quota和等待统计只观察显示端口。FAULT保留在途事务并映射0x2004；只平台复位恢复。持续显示紧急时未承诺BLIT固定等待上界，27位watchdog不能替代板级带宽验证。

## A ↔ C: Buffer / Swap / Diagnostics

FRONT_BUFFER_BASE/BACK_BUFFER_BASE为角色地址，不是恒定槽号；软件只查询，不写base。Front在整个Back构建期间不变；一条命令只写接收时锁存Back。多条FILL后显式REQUEST，Swap不复制内容，每轮应完整清屏/重建。

REQUEST可在BUSY期间提出，pending锁存并阻止新START；当前软件先完成绘图再提出。pending只能安全提交或平台复位清除，没有取消指令。SWAP_DONE是独立sticky状态，CLEAR_DONE只清DONE；新REQUEST本身不清旧DONE，推荐写REQUEST|CLEAR_DONE并等待目标SWAP_COUNT ticket。

交换要求安全frame boundary/blank、writer无busy/owned且无错误、旧帧全部R完成、outstanding=0和FIFO写流水线idle，再flush/empty确认。最后AR不足以判断完成。新reader_base同拍锁存新Front，一帧不变；DONE表示已提交下一帧角色，不表示当前扫描已到矩形。

诊断00..B8由A读取、C提供，默认100MHz周期/128bit word/beat/burst等单位各自明确。data_beats/reserved_beats是本帧累计，差值是在途义务，不是FIFO水位；CPU reset不清平台累计计数。读取不是原子多字段快照。

稳定运行以underflow/missed的baseline/value/delta判断，不要求启动历史绝对0；不把AR/R等待增长或节流增长直接当错误。没有硬件completed/rejected/AXI-error-total寄存器，应用统计是软件观测值。

## Clock / Reset / CDC Responsibility

A保证SoC/APB reset不回接平台DMA/video/DDR；CPU重跑先等待旧busy/owned/pending结束。B在core域执行锁存命令，超时不撤回VALID。C维护TPG/reader双时钟FIFO、frame boundary toggle、blank level同步、欠载Gray计数及相关74.25→148.5路径。

地址/ownership都留core100MHz；新接口若跨域，由发送/接收方共同明确稳定窗口、同步/握手和reset行为，不以多位裸同步或窄pulse同步代替事件协议。DDR/PLL/HDMI生成部分及当前Hard JTAG配置默认只读。

## Software API Contract

| API | 成功返回0时表示 |
|---|---|
| accel_init() | ID/版本/几何/服务配置正确，初始化完成且旧操作已排空 |
| accel_fill_rect(x,y,w,h,color) | 新COMMAND_COUNT确认接收；尚需wait_done |
| accel_blit(src_addr,src_stride,x,y,w,h) | 同上；源在Front、stride7680、源16byte对齐、x/w为4像素倍数 |
| accel_wait_done() | 错误为0、DONE且非BUSY、owned释放 |
| display_swap_request(&ticket) | 已写REQUEST|CLEAR_DONE并取得下一计数ticket；尚需等待 |
| display_wait_swap_done(ticket) | pending清、sticky DONE且SWAP_COUNT匹配ticket |
| display_get_front_buffer()/display_get_back_buffer() | 返回实际角色地址（不是错误码接口） |
| diagnostics_read(&snapshot) | 保存当前RO读值（void，不原子） |

D的frame_*命名仍保留为兼容接口。软件结果结构不是APB寄存器布局，重新Build后用符号查看，不复用旧地址/偏移。polling默认20,000,000次每wait，非精确时间承诺；MMIO总线完全卡死不能由同一CPU的poll循环超时恢复。
