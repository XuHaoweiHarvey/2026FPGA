# 系统架构与接口

本页描述 [基础版工程](../basic_demo/ti60f225_oob.xml) 的最终接口。基础软件已合并为 [software/basic_demo](../basic_demo/software/basic_demo/README.md)，直接运行原 M2 的 CPU/FPGA 对比。高级版的 Alpha、队列及游戏扩展见 [高级版系统说明](../starry_demo/advanced_demo/docs/SYSTEM_OVERVIEW.md) 和 [寄存器表](../starry_demo/advanced_demo/docs/REGISTER_MAP.md)。

## 数据路径

```text
Sapphire RISC-V / OCRAM
  ├─ APB → accel_regs → 命令快照 → buffer_manager 锁定 Back
  │                              → graphics_engine → FILL / BLIT / Color Key
  └─ External AXI → cpu_ddr_bridge → CPU 会话保护
                 ↓
      DDR 读仲裁 / 写准入 → DDR3 Front、Back、只读图片区
                 ↓
      Display Reader → 128→64 unpack → 双像素 CVO → HDMI
```

顶层为 [ti60f225_oob_top.v](../basic_demo/rtl/ti60f225_oob_top.v)，平台逻辑为 [rgb_framebuffer.v](../basic_demo/rtl/framebuffer/rgb_framebuffer.v)。Sapphire IP 单独注册在工程中，不能再把生成的 `soc_control.v` 重复加入 design files。Camera/Debayer 不参与当前 2D 数据路径；外围保留的 MIPI/PLL 名称可能仍服务 core/video 时钟。

## 时钟与像素格式

| 时钟 | 频率 | 用途 |
|---|---:|---|
| core_clk | 100 MHz | CPU、APB、加速器、AXI、buffer manager |
| TPG 输入 | 50 MHz | 一次性启动色条 |
| vid_clk_dvi2 | 74.25 MHz | unpack、每拍双像素 CVO |
| HDMI 像素时钟 | 148.5 MHz | RGB 选择和编码 |
| HDMI 串行时钟 | 742.5 MHz | LVDS 发送 |
| DDR 时钟 | 400 MHz | DDR3 PHY/校准 |

输出为 1920×1080@60 Hz，总时序 2200×1125；74.25 MHz 是双像素处理时钟。像素格式为 XRGB8888：`[31:24]=X, [23:16]=R, [15:8]=G, [7:0]=B`，内存低地址到高地址为 B/G/R/X。128-bit beat 为 `{P3,P2,P1,P0}`，先输出 P0；X 在基础版中不表示 Alpha。

## 内存与总线合同

| 区域 | 地址 / 长度 | 用途 |
|---|---|---|
| APB | `0xF8100000` / 64 KiB | 32-bit MMIO |
| OCRAM | `0xF9000000..0xF900FFFF` | CPU 程序、数据和栈 |
| OpenOCD 工作区 | `0xF900FC00..0xF900FFFF` | 保留末 1 KiB，应用不得占用 |
| DDR 槽 0 | `0x00000000..0x007E8FFF` | Front/Back 角色之一 |
| DDR 槽 1 | `0x00800000..0x00FE8FFF` | 另一角色 |
| M2 图片 0/1/2 | `0x01000000 / 0x0112C000 / 0x01258000` | 各 640×480×4 字节，总尾地址 `0x01384000`（不含） |

帧 stride=7680，活动区长度=`0x7E9000`。两槽间隔 8 MiB，槽尾 padding 不可作为合法像素。CPU 的 uncached DDR alias 为**物理地址加 `0x1000`**；程序仍在 OCRAM 执行。具体地址以 [生成 BSP](../basic_demo/embedded_sw/soc_control/bsp/efinix/EfxSapphireSoc/include/soc.h) 和链接脚本为准。

APB offset 是本地 byte 地址，32-bit、4-byte 对齐，无 PSTRB；默认一个等待周期，写副作用只在 `PSEL && PENABLE && PREADY` 最终访问边沿发生。软件 MMIO 使用 32-bit 访问及 `fence iorw,iorw`，禁止 IDE 自动扫描未映射窗口。

DDR AXI 为 128-bit 数据、32-bit byte 地址，ID0、SIZE=4、INCR、CACHE=3、PROT=2、LOCK=0、QOS=0。加速器地址与 CPU alias 不能混用。绘图、仲裁和错误合同见 [GRAPHICS_ENGINE](GRAPHICS_ENGINE.md)。

## CPU DDR 会话

M1a 已实现真实 CPU→DDR 访问。生成的 Sapphire 开启 External Memory AXI，关闭 Cache，保留 RV32IM、Hard JTAG 和 64 KiB OCRAM；早期“CPU 没有 DDR 端口”的描述已失效。

1. 请求 `CPU_DDR_CONTROL(0xCC)` 会话，等待 `STATUS(0xD0)` 确认。取得前需 Front 有效、加速器/桥空闲且无待换帧。
2. [cpu_ddr_bridge](../basic_demo/rtl/framebuffer/cpu_ddr_bridge.v) 减去 alias 的 `0x1000`，按 16-byte beat 定位。32-bit store 由生成 upsizer 放入对应 lane；只接受单拍 INCR、无 lock 的访问。
3. CPU 可读 Front/Back 活动区，只能写会话锁定的 Back。padding、越界、非法 lane 被拒绝。会话期间图形 START 和 Swap 被禁止，显示仍持续读取 Front。
4. 软件完成 fence，等待桥排空，检查 `CPU_DDR_ERROR(0xD4)`，再请求释放。故障不会自动解锁或发布 Back。

桥分别接收 AW/W，缓存完整 W 后才发下游 AW；下游固定 ID0，上游响应恢复原 ID。CPU Debug reset 后，已发 DDR 事务仍排空，平台会话锁保留；重新运行的软件必须检查旧状态。

## M2 素材装载与封存

`ASSET_CONTROL(0xD8)` 的 BEGIN_LOAD 开启素材写权限；CPU 在合法会话中逐像素生成三张图片，逐像素读回并核对 hash。排空并释放会话后 SEAL，`ASSET_STATUS(0xDC)` 置 READY，素材转为只读。

封存后普通 BLIT 仅接受三个精确基址、640×480、stride=2560 的整图复制；READY 前不发素材 AR，Color Key 不使用该素材窗口。CPU Debug reset 保留 READY，软件重新校验；平台复位清 READY 并重新装载。

## 初始化、所有权与安全换帧

启动 TPG 只写一次色条到槽 0。初始化屏障同时检查 518400 个 W beats、AWLEN 累计 beats、4050 个 AW/WLAST/B bursts，以及 FIFO、writer、所有响应均已排空且无错误；仅 source_done 或最后 AW 不代表完成。INIT_DONE 后 Front 有效，TPG 永久交出写端口，Back 需要软件构建。

manager 在最终 `command_accept` 锁存当时的 Back base；实际写地址为锁存 base 加 engine 相对地址。Front 与 Back 不相等，不能写正在显示的 Front。基础加速器一次执行一条命令，无通用命令 FIFO；命令完成和安全换帧分开。

Swap 的流程是：请求 pending → 等 writer 释放及 VS blank → 确认旧显示帧的 R/RLAST、outstanding 与注册流水线全部结束 → 清读 FIFO 并确认 empty → blank 内交换角色、锁新 reader base、增加 SWAP_COUNT、启动新帧。最后 AR 不等于读完；错过窗口保留 pending 到下一次。请求建议写 REQUEST|CLEAR_DONE 并等待目标 SWAP_COUNT；没有取消指令。Swap 只交换角色，不复制像素。

## 复位与 CDC

平台复位清 DMA、初始化、读帧、会话、素材和累计诊断；CPU/APB 控制复位只清控制寄存器与 pulse。CPU Debug reset 不取消 DMA、pending 或已经发出的 AXI。INIT/严重读协议故障需要平台复位恢复。

TPG→core、reader→video 使用原双时钟 FIFO；video 帧边界经 toggle 和三级同步送 core，blank 单独同步；underflow 以注册 Gray 计数跨域。74.25/148.5 MHz 来自同一 USER_PLL，按相关时钟约束处理。Front/Back 地址留在 core 域，不裸跨多位地址，也不增加全局 false path 掩盖时序。
