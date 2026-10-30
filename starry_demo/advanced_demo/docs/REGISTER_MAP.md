# Register Map — advanced_demo v7 / 窗口构建 v8–v11

本表逐项对照当前 [accel_regs.v](../rtl/control/accel_regs.v)、[sapphire_control.v](../rtl/control/sapphire_control.v)、平台输入模块和[软件宏](../software/apb_reg_test/accel_regs.h)。高级工程启用ENGINE、双缓冲、BLIT、Color Key、CPU DDR、M2素材、Alpha 与 8 项绘图命令队列；硬件版本为v7。`basic_demo` 保持M2验收基线，高级工程仍需独立综合和上板验收。

默认工程仍为 v7。独立 `DISPLAY_WINDOW_ENABLE=1` 构建为 v8：VERSION=`0x00080000`，
CAPABILITIES=`0x00000FFB`，新增 bit11 显示窗口；SERVICE_STATUS 新增 bit6 窗口准入策略。
窗口游戏 ELF 要求能力 `0xE00`；原窗口 ELF 配套 v8，当前修正 HUD 的优化 ELF 支持 v8 / v9 / v10。详见 [WINDOW_DISPLAY.md](WINDOW_DISPLAY.md) 与 [ALPHA_HARDWARE_OPTIMIZATION.md](ALPHA_HARDWARE_OPTIMIZATION.md)。
WIDTH/HEIGHT/STRIDE 仍为 1920/1080/7680；70/74 每帧终值为 76,800，不是全屏的 518,400。
v8 的显示 AR 必须逐行覆盖中央区域，跳过行间外围像素，原协议错误与换帧保护继续生效。

独立优化构建 v9 / v10 继续使用同一套寄存器偏移、队列和安全换帧协议：

| 构建 | VERSION（04） | CAPABILITIES（40） | 新能力 |
|---|---|---|---|
| v8 | `0x00080000` | `0x00000FFB` | bit11 窗口显示 |
| v9 | `0x00090000` | `0x00001FFB` | bit12 Alpha 连续供数 |
| v10 | `0x000A0000` | `0x00003FFB` | bit12 连续供数、bit13 敌弹源图缓存 |
| v11 | `0x000B0000` | `0x00007FFB` | bit14 两倍显示，保留 v10 的连续供数与源缓存 |

v11 由独立 `DISPLAY_SCALE2_ENABLE=1` 构建：640×480 的源窗口保持在 (640,300)，显示为 (320,60) 的 1280×960；WIDTH/HEIGHT/STRIDE、每帧 76,800 beat、所有 APB 偏移、Alpha / 队列 / 换帧规则保持原定义。核心仍为 100 MHz。新展示 / 压力 ELF 支持 v10 / v11；旧 ELF 使用原 bit。新增软件邮箱命令 10 和可选 `g_game_presentation`，没有新增 APB 寄存器，详见 [展示版说明](SHOWCASE_GAME.md)。

`HARDWARE_VERSION` / `EXTRA_CAPABILITIES` 参数仅改变版本和能力只读值，默认工程仍为 v7。缓存只复用已封存的 16×16 敌弹源图片，仍逐次读取当前 Back 背景；有效标记随平台复位清除，CPU Debug reset 不清除素材封存或缓存。v9 / v10 未新增 APB 寄存器，也没有软件缓存清除操作。

v8 写准入保留 LOW=384 / HIGH=512 迟滞及 B 完成前保持事务的规则。在 reader active 时，
真实显示 R 达到 quota，或 FIFO 已达到 HIGH，均可准入下一笔有界写事务；低于 LOW 后须恢复到 HIGH。
这是为避免顶部黑色区域令读 FIFO 预填满、停止新增读额度时阻塞绘图。reader safe 的空闲准入沿用原逻辑。
因此 v8 的 B4=128 是读额度参数，不代表每笔写都必须新返回 128 拍；bit6 用于识别该策略。

## Address and Access

- APB base=`0xF8100000`、window=`0x10000`，来源为正式生成的 `embedded_sw/soc_control/bsp/efinix/EfxSapphireSoc/include/soc.h` 中 `IO_APB_SLAVE_0_INPUT` / `IO_APB_SLAVE_0_INPUT_SIZE`，软件直接用宏。
- 同文件 `SYSTEM_RAM_A_CTRL=0xF9000000`、SIZE=`0x10000`；正式linker为64KiB OCRAM、默认8192byte stack，不能用旧Demo地址替代。
- offset为**本地byte地址**；下表Offset列均为十六进制。32bit整字、4byte对齐、无PSTRB/byte写。
- 写在PSEL&&PENABLE&&PREADY最终access边沿发生；默认WAIT_CYCLES=1。PSLVERROR仅最终access有效。setup/wait不重复写。
- `RO`无读清除；写RO报错。C8未映射；D8/DC为M2素材控制，E0/E4为v6 sprite控制/状态，E8及之后未映射，错误读返回0。不要让IDE Memory自动扫描整个64KiB窗口。

## Reset Notation

**C**=CPU/APB控制复位：PRESETn=soc_rst_n&&!system_reset，清RW参数、APB错误及输出pulse。**P**=平台数据域复位：沿用video reset同步到对应时钟域，清engine、初始化、manager、reader与诊断。CPU Debug reset不等于P。

下表“复位值”指全平台复位后的逻辑状态；只做C复位时，P域输入仍返回当时值。组合状态和FIFO水位不伪造一个固定常量；C/P已释放后的初始化、读帧会继续改变它们。

## Complete Register Table

| Offset | 名称 | 访问 | 复位值 / 域 | 位域、含义与清除语义 |
|---|---|---|---|---|
| 00 | ACCEL_ID | RO | 0x4143434C / 常量 | ASCII ACCL |
| 04 | ACCEL_VERSION | RO | 默认 0x00070000 / 常量 | 独立窗口构建 v8 / v9 / v10 的值见上表；保留绘图队列、Alpha、M2素材、Color Key、双缓冲与CPU DDR接口 |
| 08 | CONTROL | RW/W1 | 0 / C | bit0写1请求START、读0；bit1写1清APB错误；[31:1]保存写值并可读回，其他位无功能 |
| 0C | STATUS | RO | 0 / P输入与C错误组合 | bit0 BUSY，1 DONE，2 ERROR，3 INIT_DONE，4 OWNER_ACCEL，5 COMMAND_QUEUE_READY；[31:6]=0 |
| 10 | RECT_X | RW | 0 / C | x，pixel；新START快照，不影响在途命令 |
| 14 | RECT_Y | RW | 0 / C | y，pixel |
| 18 | RECT_WIDTH | RW | 0 / C | width，pixel，必须非0 |
| 1C | RECT_HEIGHT | RW | 0 / C | height，pixel，必须非0 |
| 20 | RECT_COLOR | RW | 0 / C | FILL使用完整XRGB；普通BLIT忽略；色键复制比较低24位RGB；Alpha用低8位作global alpha；START快照 |
| 24 | ERROR_CODE | RO | 0 / C及P组合 | init_error优先，其次engine_error、reader_error、APB error；清除方法见错误表 |
| 28 | SCRATCH | RW | 0 / C | 独立32bit读写验证，不控制DDR |
| 2C | FRONT_BUFFER_BASE | RO | 0x00000000 / P | 当前Front角色base，swap后可为00800000 |
| 30 | BACK_BUFFER_BASE | RO | 0x00800000 / P | 当前Back角色base，与Front不同 |
| 34 | FRAME_STRIDE | RO | 7680=0x1E00 / 常量 | bytes/line |
| 38 | FRAME_WIDTH | RO | 1920=0x780 / 常量 | pixels/line |
| 3C | FRAME_HEIGHT | RO | 1080=0x438 / 常量 | lines/frame |
| 40 | CAPABILITIES | RO | 默认 0x000007FB / 常量 | bit0寄存器、1 SCRATCH、3 FILL_RECT、4 INIT/写owner、5双缓冲swap、6 BLIT、7 Color Key、8 Alpha、9封存全屏背景、10命令队列、11窗口显示、12 Alpha连续供数、13敌弹源图缓存、14两倍显示；bit2=0，按构建启用 |
| 44 | INIT_DATA_BEATS | RO | 0 / P | 初始化WVALID&&WREADY数，单位128bit beat；INIT_DONE后冻结 |
| 48 | INIT_AW_BURSTS | RO | 0 / P | 初始化AW握手数，单位burst；完成后冻结 |
| 4C | INIT_WLAST_BURSTS | RO | 0 / P | 初始化W握手且WLAST数，单位burst；完成后冻结 |
| 50 | INIT_B_RESPONSES | RO | 0 / P | 初始化B握手数，单位burst；完成后冻结 |
| 54 | INIT_AW_BEATS | RO | 0 / P | 初始化所有AWLEN+1之和，单位128bit beat；完成后冻结 |
| 58 | WRITE_OWNER | RO | 0 / P | [0]=INIT_DONE：0 TPG/排空等待，1 Accelerator永久接管；高位0 |
| 5C | COMMAND_COUNT | RO | 0 / P | v7为队列成功接收的描述符数，v6为engine接收数；自然回绕，不由C复位清零 |
| 60 | SWAP_CONTROL | W1，读0 | 0 / 输出pulse由C清零 | bit0 REQUEST、bit1 CLEAR_DONE；写3清旧DONE并请求，其他位忽略 |
| 64 | BUFFER_STATUS | RO | 0x02加组合bit7 / P | bit0 FRONT_INDEX、1 BACK_INDEX、2 PENDING、3 DONE、4 FRONT_VALID、5 WRITER_OWNED、6 READER_ACTIVE、7 READER_SAFE；高位0 |
| 68 | READER_FRAME_BASE | RO | 0 / P | 本帧锁存Front地址，帧内不变；只在安全launch更新 |
| 6C | READER_OUTSTANDING | RO | 0 / P | 已接受AR但尚无RLAST的burst数，当前最大1 |
| 70 | READER_DATA_BEATS | RO | 0 / P；每launch清零 | 当前帧实际R握手数，单位128bit beat |
| 74 | READER_RESERVED_BEATS | RO | 0 / P；每launch清零 | 当前帧所有ARLEN+1总和；不是FIFO存量 |
| 78 | READER_ERROR | RO | 0 / P | sticky读协议/响应错误，只有P清除 |
| 7C | BOUNDARY_COUNT | RO | 0 / P | core收到的VS入口事件累计，32bit自然回绕 |
| 80 | SWAP_COUNT | RO | 0 / P | 实际安全提交交换次数，非REQUEST次数 |
| 84 | MISSED_BOUNDARY_COUNT | RO | 0 / P | 有效Front下边界到来而reader不safe，或flush错过blank窗口；不读清零 |
| 88 | SERVICE_STATUS | RO | 0x00000022 / P状态及常量 | [0]准入保持，[1]水位保护，[2]AW等待准入，[3]AW握手到B在途，[4]读额度满，[5]策略启用；高位0 |
| 8C | WRITER_THROTTLE_CYCLES | RO | 0 / P | raw engine AWVALID且尚未admit的core周期累计 |
| 90 | WRITER_BURSTS | RO | 0 / P | INIT_DONE之后engine实际AW握手数，单位burst，不包含TPG |
| 94 | READER_AR_STALL_CYCLES | RO | 0 / P | ARVALID&&!ARREADY的core周期累计 |
| 98 | READER_AR_MAX_STALL | RO | 0 / P | 最大连续AR等待，单位core周期 |
| 9C | READER_R_STALL_CYCLES | RO | 0 / P | outstanding!=0且无RVALID&&RREADY的core周期累计 |
| A0 | READER_R_MAX_STALL | RO | 0 / P | 上述R等待最大连续core周期；可能包含接收侧反压，不是RRESP错误数 |
| A4 | DISPLAY_UNDERFLOW_COUNT | RO | 0 / video及core P | 原CVO underflow=1的video周期累计，经Gray CDC；包含启动历史 |
| A8 | READER_FRAME_COMPLETIONS | RO | 0 / P | read guard active退出且safe时累计；完整R和流水线结束，不等于已扫描显示帧数 |
| AC | READER_FIFO_LEVEL | RO | FIFO复位后0 / 实时 | 原DDR read FIFO core写侧WrDNum，单位128bit word，范围0..1024 |
| B0 | WRITER_MAX_CYCLES | RO | 0 / P | 已准入AW暴露（含等AWREADY）至B结束的最大连续core周期 |
| B4 | SERVICE_READ_QUOTA | RO | 128=0x80 / 常量 | 上一笔写B之后所需真实R handshake数 |
| B8 | SERVICE_WATERMARKS | RO | 0x02000180 / 常量 | [31:16]HIGH512；[15:0]LOW384，单位128bit FIFO words |
| BC | COMMAND_OP | RW | 0 / C | 0 FILL，1 BLIT，2色键复制，3 Alpha Blend；其他值接受计数后报0x26；START时快照 |
| C0 | SRC_ADDR | RW | 0 / C | BLIT源绝对字节地址，16byte对齐；按命令限于Front、三张M2整图、封存全屏背景或sprite图集的合法矩形 |
| C4 | SRC_STRIDE | RW | 0 / C | 源行距bytes：Front和全屏背景为7680，M2整图或sprite为2560；START时快照 |
| CC | CPU_DDR_CONTROL | WO | 0 / C | Phase 3：bit0请求CPU会话，bit1请求释放，bit2清CPU DDR错误；会话与现有图形命令互斥 |
| D0 | CPU_DDR_STATUS | RO | 0x10 / P | Phase 3：bit0会话有效，bit1桥非空，bit2会话错误，bit4支持CPU DDR；释放前须等待bit1=0 |
| D4 | CPU_DDR_ERROR | RO | 0 / P | Phase 3桥首个错误码：1权限/协议，3 DDR响应ID，4 DDR响应错误，5 RLAST，6 CPU复位中止 |
| D8 | ASSET_CONTROL | WO | 0 / C | M2：bit0 BEGIN_LOAD，bit1 SEAL；其余位及两位同时写入非法；仅在无CPU会话、桥/引擎空闲且无关键错误时接受 |
| DC | ASSET_STATUS | RO | 0x80000000 / P | M2：bit31功能存在，bit0 LOADING，bit1 READY，bit2 CPU会话/桥错误；平台复位清LOADING/READY，CPU Debug Reset不清；READY后素材只读 |
| E0 | SPRITE_CONTROL | WO | 0 / C | v6：bit0 BEGIN_LOAD，bit1 SEAL；仅在M2素材已封存、CPU会话/桥及图形引擎空闲时接受 |
| E4 | SPRITE_STATUS | RO | 0x80000000 / P | v6：bit31功能存在，bit0 LOADING，bit1 SEALED，bit2 CPU会话/桥错误；平台复位清LOADING/SEALED |

CPU 外部DDR窗口从 `0x00001000` 起。桥将地址减 `0x1000` 并对齐到128-bit字；锁定的Back有效像素区可写，Front/Back有效像素区可读。M2加载期另外仅允许三张图片素材`0x01000000..0x01383FFF`读写，封存后素材只读。v6 sprite加载期仅允许图集`0x01384000..0x014AFFFF`读写，封存后只读；图集不能由普通BLIT读取。其他DDR地址仍拒绝。CPU会话期间禁止图形命令和Swap；Display Reader持续工作，写准入节流仍生效。M1a程序与栈仍在64KB OCRAM。

全屏扩展另允许物理背景窗口 `0x02000000..0x027e8fff`（1920×1080，stride=7680）。
该窗口仅在启用 sprite 的构建中存在，复用 ASSET 加载/封存生命周期：有效 CPU DDR 会话
且 LOADING 时可写，LOADING 或 READY 时可读，READY 后禁止修改。普通 BLIT 可在 READY
后读取窗口内的对齐矩形，含局部恢复；不能跨行或越出右/下边界。Color Key/Alpha 不可读取
该窗口。CPU 地址仍须加 `0x1000`；没有开放任意 DDR 范围。

BUFFER_STATUS复位时Front0、Back1、active/owned/valid/pending/done=0；bit7按`!active && reader_idle && !ARVALID && !RVALID && outstanding==0 && reader_error==0`实时组合。Reader/DDR空闲且复位已稳定时可读0x82，不能把bit7当manager存储复位常量。

SERVICE_STATUS复位healthy=0、read_credit=0、grant=0、transaction_active=0且ENABLE=1，因此0x22；bit1=1本身不是错误，reader safe的slack可准入。bit2只表示等待准入；bit3不是整条命令BUSY。一次准入锁存到B，不能通过软件写此寄存器解除保护。

## START / DONE / Swap Semantics

START有效时，先检查INIT_DONE。v6检查引擎BUSY和draw_ready；v7检查COMMAND_QUEUE_READY。成功APB access快照矩形字段及op/src_addr/src_stride，v6同步交给manager/engine，v7则按顺序放入8项FIFO，engine空闲时逐条取出。v7的BUSY覆盖FIFO和正在运行的命令，COMMAND_COUNT在FIFO成功接收时递增；交换缓冲区前必须等BUSY清零。width/height>0，矩形边界不得越出1920×1080。FILL的x/width无需4对齐；BLIT、色键和Alpha的x/width必须按4像素/16byte beat对齐。Front源矩形须在当前Front有效图像内，不能使用8MiB槽尾padding，也不能横跨源行。M2允许普通BLIT从ASSET_READY后的三张精确素材基址`0x01000000/0x0112C000/0x01258000`读取整张640×480图像。Color Key和Alpha另允许从已封存图集`0x01384000..0x014AFFFF`读取stride=2560、边界检查通过的矩形；普通BLIT不能读该图集。FILL不使用源字段，API每次显式写op=0。

色键复制继承BLIT几何、完成和错误规则。源RGB等于RECT_COLOR低24位时，对应四个byte strobe为0，保留Back完整XRGB；其他源像素完整复制。Alpha Blend仅在op=3时将源最高字节解释为逐像素Alpha，按`Aeff=(pixel_alpha*global_alpha+127)/255`及`Cout=(src*Aeff+dst*(255-Aeff)+127)/255`四舍五入混合RGB，并保留目标最高字节。Alpha每段先读sprite前景，再读当前Back背景，混合后写回；命令参数在START时锁存。Color Key和Alpha均复用同一图集窗口，普通BLIT仍不能读取图集。换帧不会自动复制Front背景；CPU和FPGA演示均先准备Back背景。v6游戏可使用其原能力集；全屏 v7 游戏要求bit9全屏背景和bit10绘图队列（必需掩码`0x600`），当前完整能力为`0x7FB`。软件按硬件版本选择v6同步或v7入队协议。

70/74/6C及94..A0、读quota只观察显示客户端的AR/R；BLIT读不计入显示帧或写准入额度。全局读仲裁最多一笔outstanding。共享协议FAULT映射READER_ERROR=0x2004，阻止新START、REQUEST和提交换帧；CPU reset不能清除，也不取消在途AR/R/AW/W/B。

STATUS.ERROR是init/engine/reader/APB任一非0的组合。成功FILL后通常STATUS=0x1A；INIT后未绘制通常0x18。DONE sticky，新engine接收命令清零；错误也可DONE，必须看ERROR_CODE和BUSY。正式SETTLE_FRAMES=0，以最后成功B为准，不等HDMI扫描。

REQUEST可在BUSY时提出，pending阻止新START，等待writer和安全读帧边界。新REQUEST不自动清旧SWAP_DONE；推荐写3并等待目标SWAP_COUNT与DONE、pending清零。CLEAR_DONE只清DONE，不清pending、不复位DMA。没有CANCEL_SWAP。完成后BUFFER_STATUS低5位通常交替0x19/0x1A，高位实时变化。

WRITE_OWNER是TPG是否永久交出写端口；WRITER_OWNED是当前命令是否持有Back，不能混同。SWAP_DONE表示已在安全窗口提交下一帧地址，非“矩形已经扫描输出”。

初始化成功44/54各518400；48/4C/50默认各4050且相等。前者是data beats、后者是bursts，不可混作同一个完成条件；初始化计数不统计后续FILL。

## Error Codes and Clear Semantics

本节错误码均为十六进制。错误访问会更新APB error，但不产生目标寄存器/命令副作用。

| ERROR_CODE | 条件 | 行为 / 清除 |
|---|---|---|
| 0x0000 | 无错误 | 正常 |
| 0x0001 | APB未对齐 | PSLVERROR；CONTROL bit1、下一成功APB START或C复位清APB error |
| 0x0002 | 未映射offset | 同上，PRDATA=0 |
| 0x0003 | 写RO | 同上 |
| 0x0004 | INIT_DONE前START，或Front无效时REQUEST | 不发pulse；清除同APB错误 |
| 0x0005 | BUSY或已有start_pulse时START | 不排队、不覆盖参数；清除同APB错误 |
| 0x0006 | draw_ready不成立时START，或重复pending/已有swap pulse时REQUEST | 不产生新命令；清除同APB错误 |
| 0x0011 | engine几何非法/越界 | DONE+ERROR，无AW；下一engine接收命令或P清 |
| 0x0012 | BRESP!=OKAY或BID!=0 | 当前B接收后终止，不发后续burst；下一engine接收命令或P清 |
| 0x0013 | engine无进展超时 | 不撤回VALID，排空当前事务后退出；完全失应答可能保持BUSY；下一命令或P清 |
| 0x0021 | BLIT/Alpha源范围、尺寸、stride或对齐错误 | 接受计数，DONE，无AR/AW，释放Back；下一engine接收命令或P清 |
| 0x0022 | BLIT/Alpha RRESP或RID错误 | 排空当前读burst，坏数据段不写出；下一命令或P清 |
| 0x0023 | BLIT/Alpha BRESP或BID错误 | 当前B后停止后续段；下一命令或P清 |
| 0x0024 | BLIT/Alpha无进展超时 | 保持已提出VALID，等待排空；可能持续BUSY；下一命令或P清 |
| 0x0025 | BLIT/Alpha RLAST拍数协议异常 | 保持BUSY和Back ownership直到实际R结束；无结束响应时保持BUSY；只能P恢复 |
| 0x0026 | 非法COMMAND_OP | 接受计数，DONE，无AR/AW；下一engine接收命令或P清 |
| 0x1001 | 初始化FIFO溢出 | INIT_DONE不置位，不交owner；P清 |
| 0x1002 | 初始化BRESP/BID错误 | 同上 |
| 0x1003 | 初始化地址/长度/WLAST/strobe/计数/协议错误 | 同上 |
| 0x1004 | 初始化无进展超时 | 同上 |
| 0x2001 | reader不safe时launch | sticky；禁止后续读启动/交换，P清 |
| 0x2002 | AR地址/size/burst/4KiB或R计数/RLAST协议错误 | 同上 |
| 0x2003 | RRESP!=OKAY或RID!=0 | 同上 |
| 0x2004 | 共享读仲裁出现无owner响应或RLAST/拍数错误 | 保持原owner与在途事务，阻止新命令/换帧，P清；engine错误优先读出 |

优先级：未对齐→未映射→写RO→START/REQUEST状态检查；ERROR_CODE读取优先init、engine、reader、APB。普通正确读写不清APB错误；CONTROL bit1不清INIT/engine/reader错误，不复位DDR或owner。组合写START+clear若START被拒绝，整个目标写不执行，只记录错误。

## Diagnostics and Software Observation

平台累计计数无读清除/W1C接口，CPU reset、START、CLEAR_DONE、swap均不清零；70/74是每frame launch清零的例外。32bit自然回绕，100MHz累计周期约42.95秒回绕；用uint32差值，不要求绝对单调。max寄存器是峰值，不用相减表示总等待。

UNDERFLOW_COUNT是video underflow高电平**周期数**，不是软件自定义的“黑屏次数”；启动未供数时可非0。记录稳定baseline后检查新增delta0；MISSED同理。FIFO_LEVEL不是reserved-data，后者为尚欠的R beats。各CSR独立读不是原子快照，frame计数可能跨launch清零。

当前软件`g_apb_test_result.diagnostics`保存原始值；`underflow_baseline/missed_baseline`与delta记录运行新增。硬件没有独立completed-command、rejected-command或AXI-error-total寄存器。软件commands_issued/completed、swaps_requested/completed、rejected_*和error_observations仅是本次CPU运行观测，不能写成额外硬件计数。

