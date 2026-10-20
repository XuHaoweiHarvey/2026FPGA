# Architecture

本文描述当前源码架构。Phase 2旧FILL/v3已上板通过；当前v5的BLIT/色键系统仿真、软件构建和静态时序通过，已收到三轮全屏板级测速及色键画面，范围和待补项见 [V5_BOARD_BENCHMARK](V5_BOARD_BENCHMARK.md)。历史系统验证见 [SYSTEM_BLIT](SYSTEM_BLIT.md)。开发故障见 [TROUBLESHOOTING](TROUBLESHOOTING.md)，阶段证据见 [VALIDATION](VALIDATION.md)，共享契约见 [INTERFACES](INTERFACES.md)。CPU软件对照仍在方案阶段，见 [CPU_RENDER_PLAN](CPU_RENDER_PLAN.md)。

## Overall Architecture

根项目 [ti60f225_oob.xml](../ti60f225_oob.xml)，顶层 [ti60f225_oob_top.v](../rtl/ti60f225_oob_top.v)。当前为55个 design entries 和单独注册的 `soc_control` IP；不要重复加入生成 RTL。

```text
u_control: sapphire_control
  u_soc_control: Sapphire / OCRAM / Hard JTAG
    → APB3 → u_accel_regs: accel_regs
    → cmd_* / start_test_pulse
checker0: rgb_framebuffer
  d_buffers.manager: buffer_manager → command_accept / 锁存 command_base
  c_control.graphics.source_guard: blit_source_guard → 锁存Front源范围结果
  c_control.graphics.engine: graphics_engine → FILL/BLIT选择、相对AXI写地址
  d_buffers.write_service: ddr_write_admission → 新 AW 准入
  写 owner mux + command_base → u_ddr3_top → DDR Back

cvo_axi_inst.fifo_rd_period → d_buffers.frame_cdc: video_frame_cdc
  d_buffers.guard: read_frame_guard ← 显示客户端AR/R、reader idle
  d_buffers.manager → safe swap / reader_base / flush / launch
  u_ddr_rd_buffer: ddr_rd_buffer ← DDR Front
    → u_unpack: rgb_unpack128_to64 → cvo_axi_inst: cvo_axi
    → u_rgb_to_hdmi: rgb_to_hdmi → dvi_encoder_m0 → HDMI LVDS TX
  shared_read.arbiter: ddr_read_arbiter ← 显示/BLIT的AR/R → DDR Front
```

graphics_engine选择FILL或BLIT，统一AW/W/B和执行状态；BLIT另有源读AR/R。读仲裁全局一笔outstanding，按burst固定owner并单独路由R。当前无通用命令队列，CPU无DDR端口，不逐像素写framebuffer。

Camera/CSI/Sensor 配置 RTL 不在活动2D链路，Bayer/Debayer不参与当前像素处理。Interface Designer 保留原 Camera D-PHY、DSI、相关 PLL、端口和 pin assignment；不能根据模块名称删除仍供 core/video 使用的时钟。

## Clock Domains

来源：[peri配置](../ti60f225_oob.peri.xml)、[SDC](../ti60f225_oob.sdc)和顶层接线。

| 时钟 | 频率 | 来源 / 用途 |
|---|---:|---|
| core_clk | 100 MHz | MIPI_TX_PLL；CPU、APB、engine、buffer manager、AXI与reader控制 |
| i_mipi_rx_pclk | 50 MHz | pll_inst4；仅启动TPG输入，名字不代表仍接摄像头 |
| vid_clk_dvi2 | 74.25 MHz | USER_PLL；128→64 unpack、双像素 CVO、视频边界 |
| hdmi_tx_slow_clk | 148.5 MHz | USER_PLL；单像素RGB选择及encoder |
| hdmi_tx_fast_clk | 742.5 MHz | USER_PLL；HDMI LVDS串行输出所用时钟 |
| sdram_clk / calibration clocks | 400 MHz | DDR3_PLL；原DDR physical/校准 |

H active/front/sync/back=1920/88/44/148，V=1080/4/5/36；总计2200×1125，148.5MHz对应60Hz。CVO处理每拍双像素，不能把74.25MHz误写为最终pixel clock。

## RISC-V / APB Control Plane

`sapphire_control`将Sapphire APB0的16-bit本地byte PADDR零扩展到32位，连接`accel_regs`；APB数据32位，默认WAIT_CYCLES=1，仅最终access产生写副作用。软件用32位MMIO和`fence iorw,iorw`。

正式BSP `embedded_sw/soc_control/bsp/efinix/EfxSapphireSoc/include/soc.h`：APB=`0xF8100000`/64KiB；OCRAM=`0xF9000000`/64KiB。linker/default.ld使用该RAM，默认stack8192bytes；项目为OpenOCD保留最后1KiB `0xF900FC00..0xF900FFFF`。

### 已生成的 Sapphire 配置摘要

| 页面 / 项目 | 当前配置 |
|---|---|
| SOC | Sapphire3.4.0，Standard，单核，100MHz，独立peripheral clock关闭 |
| Memory | Cache关闭、external DDR关闭、OCRAM65536；不依赖UART/默认bootloader运行Demo |
| APB3 | Slave0开启/65536byte，Slave1～4关闭 |
| Peripherals | UART/SPI/I2C/GPIO、用户中断/timer/watchdog均关闭 |
| Debug | Hard TAP/port1/JTAG_USER1；Soft TAP、Co Debug、Standard RISC-V Debug关闭；DEVKIT=11 Titanium |
| Address | AUTO；以生成soc.h和linker为准，不照搬Demo08地址 |
| ISA | 生成soc.h确认RV32I+M、Zicsr/Zifence；A/C/F/D关闭 |

`settings.json`含隐藏/失效旧字段，例如`AXIMaster=1`，不能单凭字段名判断外部接口；当前生成`soc_control.v`公共端口没有DDR/AXI master。配置只作核对依据，当前无需重新Generate。生成配置来源直接查看[ip/soc_control/settings.json](../ip/soc_control/settings.json)、正式生成RTL及BSP的soc.h/linker，不再依赖开发期指纹清单。

## Accelerator

当前命令FILL_RECT和Front→Back BLIT。APB START快照`op/x/y/width/height/color/src_addr/src_stride`；manager accept锁Back与源范围结果，engine下一拍检查源。尺寸非零、完全在1920×1080内，不裁剪，33位坐标相加检查溢出。

`fill_rect_writer`逐行生成相对byte地址；每burst最多32个128-bit beats、一个outstanding，不跨4KiB。边缘使用每pixel四byte的WSTRB，不修改矩形外像素。状态机为IDLE→PREP→ADDR→DATA→RESP；当前调用`SETTLE_FRAMES=0`，最后成功B后DONE，不等显示扫描。软件另外检查BUSY=0、WRITER_OWNED已释放。错误命令也可能DONE，必须检查ERROR_CODE。

BLIT源为Front绝对地址，16byte对齐、stride7680，目标x/width为4像素倍数；读最多32beats、不跨4KiB，缓存读段后再写Back。27位无进展watchdog不撤回已出现的AR/AW/W VALID，排空后退出；协议FAULT保留BUSY/Back及原读owner，只平台复位恢复。当前没有Line、Alpha、命令FIFO或中断。

## DDR Access and Initialization

原`ddr3_top`/PHY直接连接wrapper的AW/W/B和AR/R；QoS保持原固定0，不推断加密scheduler。`ddr3_parameter.vh`为ROW14/COL10/BANK3/DQ16/RANK1，配置容量256MiB；AXI128、address32、byte单位，ID0/AXSIZE4/INCR。

启动`u_rgb_tpg`以ONE_FRAME=1产生一帧红绿蓝白，经过`u_ddr_wr_buffer`写Buffer0；无直连HDMI旁路。TPG每拍四pixels，H_BLANK_CYCLES=320、V_BLANK_LINES=170，50MHz/(800×1250)=50fps的时序只用于该一次初始化，来源rgb_tpg_config.vh。

`init_write_monitor`分别统计518400 W data beats和AWLEN+1 beats，及4050 AW/WLAST/B bursts；源结束已同步、FIFO empty、writer idle、AW/W/B均无待处理、burst剩余计数0、所有B成功且无错误后才INIT_DONE。仅source_done或bank_sw不能替代此屏障。

INIT_DONE前START拒绝，读不启动。成功后总写owner永久由TPG切到Accelerator，Front有效；Back1尚无有效场景，须软件完整重建。初始化失败不会转交；CPU Debug reset也不会重启TPG。AW/W/B是统一二选一，绝不OR。

## XRGB8888 Framebuffer

`[31:24]=X，[23:16]=R，[15:8]=G，[7:0]=B`。地址由低到高存B/G/R/X；128bit word的最低32bit为P0，其后P1/P2/P3。unpack先发{P1,P0}再{P3,P2}；rgb_to_hdmi在相关2倍频时钟下先P0后P1，丢X、不交换R/B；gamma_sel=0。

| 项目 | 值 |
|---|---|
| 尺寸 / bytes per pixel | 1920×1080 / 4 |
| stride / frame bytes | 7680=`0x1E00` / 8294400=`0x7E9000` |
| frame AXI beats | 518400，单位128-bit data beat |
| Buffer0有效范围 | `0x00000000..0x007E8FFF` |
| Buffer1有效范围 | `0x00800000..0x00FE8FFF` |
| 槽间距 / 帧尾余量 | 8MiB / `0x17000`bytes，不参与显示 |

当前X不是Alpha。Bayer历史仅保留在排障/验证的历史说明中，不应用于当前颜色定义。

## Front / Back and Buffer Ownership

复位Front0、Back1、FRONT_VALID=0；INIT_DONE后Front有效。manager的command_accept锁存当前back_base为command_base，与engine参数同一命令生效。实际AW地址=`command_base + engine_awaddr`，直到命令完成保持。

Front≠Back；显示与BLIT只读Front，Accelerator只写锁存Back。BUSY、writer_owned、swap_pending或共享读故障阻止新命令。多条绘图完成后由软件显式swap，不能每条矩形自动交换。Swap只交换角色，不隐式复制；BLIT必须单独提交。

## VBlank-safe Swap

1. `fifo_rd_period`是原CVO的`v_state==S_V_SYNC`，上升沿位于VS入口。video_frame_cdc传递事件toggle及blank level至core域。
2. core记录SWAP_PENDING。boundary时需Front有效、blank且reader_safe，快照是否可交换：pending、writer无busy/owned、无新cmd_request、writer_error=0。
3. read_frame_guard按真实ARLEN+1、R/RLAST、outstanding检查完整帧；收齐518400 beats、无在途burst且reader最后R→FIFO注册流水线idle后才safe。**最后AR完成不等于帧读完。**
4. 安全窗口内reset原DDR read FIFO 8个core周期，释放后等待FIFO empty和safe、blank仍成立；CVO/unpack按原VS逻辑flush/hold。
5. 同拍对调Front/Back、锁存新reader_base、清pending、置sticky SWAP_DONE、增加SWAP_COUNT并发reader_launch。无swap请求时仍启动原Front下一帧。

边界之后才结束的writer必须等下个边界；旧R迟到时不清FIFO/不启动新帧；flush错过blank则保留pending下次重试。旧reader的bank_sw/ddr_read_stop可能在最后AR就置位，不能用于完整完成判定。当前没有取消swap指令。

## Display Reader and HDMI

`ddr_rd_buffer`每次一个burst，state1用`RD_FIFO_DEPTH >= rd_fifo_wrusedw + BURST_LEN + 5`预留返回空间；state2等ARREADY，state3等R/RLAST。正式BURST_LEN=127表示128beats，read FIFO为1024×128bit。导出的idle/empty/level仅观察原逻辑。

Reader一帧锁存一次base，整个帧不变。`rgb_unpack128_to64`保留FIFO延迟/反压下的数据和标记；每行960个双像素word，TUSER首pair、TLAST行末。CVO FIFO1024×64bit，输出经related-clock RGB adapter、原DVI encoder及LVDS TX到HDMI。

## Display-protection Write Admission

正式策略位于`ddr_write_admission`，只控制**下一笔新AW准入**，不是CPU delay，也不是修改DDR内部优先级。

| 参数 | 正式值 | 作用 |
|---|---:|---|
| WRITE_SERVICE_ENABLE | 1 | 正式启用 |
| WRITE_READ_QUOTA | 128 | 上一笔写B之后的真实RVALID&&RREADY数 |
| WRITE_FIFO_LOW | 384 | FIFO≤该值进入保护 |
| WRITE_FIFO_HIGH | 512 | FIFO≥该值恢复，准入时仍须高于LOW |

Reader active时额度和水位都满足才准入最多32beat写；写进行中的R不预付下一笔额度。已暴露AW的grant保持至B结束，即使水位变低或新帧开始也不撤销。W/B、AR/R直通。Reader整帧完成且safe时可使用slack；launch/flush清新准入额度和水位状态，已有事务照常排空。Reader错误禁止新写准入，不中断已有写。

FIFO水位是既有core写侧WrDNum；`reserved_beats-data_beats`表示尚欠R数据，不是FIFO存量。低水位6144bytes按active594MB/s提供约10.34µs名义存量余量，但不是未知DDR最坏延迟保证；真实系统已做功能/稳定性验收，板级吞吐/延迟原始测量尚未提供。

## Reset and CDC

`w_arstn=i_pll_locked & pll_locked & user_pll_locked`，DDR rstn接w_arstn；video保持原fixed delay/dly_cnt[26]，cal_done仅诊断，不改变释放序列。各数据域沿用rst_n_piple同步释放。CPU控制岛另以`i_arstn && w_arstn`异步断言/三拍释放；Sapphire io_systemReset仅清APB寄存器。

| 跨域关系 | 当前处理 / 责任 |
|---|---|
| TPG50→AXI100 | 原双时钟FIFO；frame_start为注册20ns脉冲，原writer同步/边沿检测；source_done/overflow三拍同步 |
| Reader core→video74.25 | 原DC_FIFO同步Gray读指针，unpack观察FIFO延迟 |
| frame boundary video→core | toggle+三拍同步/异或，blank level独立三拍；事件须间隔至少4个core周期，真实帧间隔约16.7ms |
| underflow video→core | 每个underflow周期计数、注册Gray、三拍同步和译码，包含启动历史 |
| 74.25→148.5 RGB | 同源USER_PLL相关时钟传输，保持原相关路径约束，不当作任意异步CDC |
| Front/Back地址 | 全部留在core100MHz，不裸跨多位地址 |

CPU Debug reset不清DMA、owner、manager、pending或平台计数，不撤回在途AXI。软件重跑先等旧操作结束，再完整重建Back。INIT/reader故障平台复位才清；恢复前保存诊断，不强制提前swap。不得增加全局false path掩盖时序问题。
