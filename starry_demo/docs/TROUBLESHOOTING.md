# Troubleshooting

只记录仓库历史与当前源码能支持的问题；正常构建见[BUILD](BUILD.md)，当前架构见[ARCHITECTURE](ARCHITECTURE.md)，测试数据见[VALIDATION](VALIDATION.md)。A～E最终均已实板通过。下文的旧接线/旧像素格式只用于说明故障，不是当前修改指令。

## HDMI black screen during continuous rendering

### Symptom

Back做全屏FILL+矩形时HDMI黑屏，尚未REQUEST就出现；CPU halt约30秒或Writer停止后旧Front稳定。hold从60改400曾用于诊断，能观察“Writer活跃黑屏、空闲恢复”。missed_boundaries在绘制期10→19，真正swap后仍19；reader_error/error_code/errors为0，Front/Back及reader_base交换本身正确。

### Cause

```text
Writer连续写burst过于激进
 → Display Reader服务不足 / AR或R等待
 → DDR read FIFO、unpack、Display FIFO供数不足
 → cvo_axi_v2: fifo_rd_empty && fifo_rd_en
 → 清frame_ena，H/V状态回SYNC、计数重启
 → HDMI black screen / 重新锁定
 → 新边界出现而旧DDR帧未完成，missed_boundaries增长
```

原FILL最大32beats/burst、一个outstanding，RESP收到成功B后立即回PREP继续写，全屏16200bursts。原Reader reservation仅保证有空间容纳返回，不保证DDR何时服务。合法延迟的RRESP仍可一直OKAY，所以reader_error=0不排除显示饥饿。

**可确认的是外部写负载缺少读服务约束及CVO欠载后重启时序；加密scheduler内部具体AR优先级或R延迟分配无法由已有资料可靠断言。** 新诊断分别记录AR/R等待，不把推测写成控制器内部事实。

### Diagnosis

比较Writer活跃/空闲、back_ready/frame_presented、hold和missed增量，排除“每次swap自身黑屏”的解释。逐模块跟踪fill_rect_writer、ddr_rd_buffer、FIFO、CVO和manager。

合法写偏置AXI模型复现：Back构建时busy=1、R_wait=5817、FIFO=0并触发CVO underflow；关闭新策略的同模型负对照同样失败。照片/LED本身不足以定位AR还是R。

### Fix

正式保留`ddr_write_admission`，不改Front/Back/swap和原CVO：

1. Reader active时，上一笔写B以后须完成128个真实RVALID&&RREADY，才考虑下一笔最多32beat写。
2. FIFO≤384保护、≥512恢复，准入时仍须>384；水位为core域既有WrDNum。
3. 新AW准入一旦暴露就锁存到B，不能因水位下降撤回VALID；W/B、AR/R不门控，已有事务完整排空。
4. 写进行中的R不预付下一笔额度；新reader launch/flush清新额度，reader整帧完成且safe时允许slack进展。
5. 追加88..B8诊断；video underflow按周期计数，经注册Gray/三拍到core，保留启动历史。

不降低分辨率/刷新率，不删全屏fill、不增hold掩盖、不清missed、不忽略欠载、不强制提前swap。低水位6144bytes在active594MB/s下约10.34µs名义余量；严苛模型最大R等待422cycles=4.22µs、已暴露写事务70cycles=0.70µs。这是测试预算，不是未知DDR最坏延迟的数学保证。

### Verification

完整1920×1080并发WAIT0/1/3及更严R/B延迟检查248,832,000最终pixels，稳定期欠载/missed增量0、Writer持续进展、安全swap正确；C功能回归通过。负责人随后重新Compile、下载并确认实板连续显示稳定，D通过；最终E也已通过。

复现命令及Simulation throughput见[VALIDATION](VALIDATION.md)。负对照`--unthrottled`预期失败，仅用于仿真，不把关闭保护的配置用于正式设计。

## GDB disconnects after the target is examined

### Symptom

OpenOCD识别Ti60 TAP `0x10660A79`、Target successfully examined、接受GDB连接后退出。IDE日志保留了确切失败：

```text
Error in final launch sequence
Failed to execute MI command:
set $pc=0x0xf9000000
Invalid number "0x0xf9000000".
```

### Cause

Startup的Set PC hex字段错误填写`0xf9000000`，IDE自行再加`0x`。Target Description disabled和Prefer extended-remote是warning，不是这次退出根因。

### Diagnosis

正式workspace曾在`embedded_sw/soc_control/bsp`；`.metadata/.log`于2026-10-14 22:12:22记录该MI错误。用同版本实际GDB解析器离线重放，稳定复现Invalid number。

### Fix

Set PC字段填`f9000000`（无0x），命令应为`set $pc=0xf9000000`。当前`apb_reg_test_ti.launch`与项目配置生成器已采用正确格式；保留成功gpioDemo_ti的Titanium Hard JTAG组织，不切Soft TAP或改Target Description模式。

### Verification

`check_apb_debug.py`用实际GDB和OpenOCD Jim验证解析/配置（硬件命令mock）；负责人完成真实Hard JTAG/APB验收并确认B通过。当前软件沿用同一launch，E已实板通过。

## FTDI target description and the wrong configuration file

### Symptom

生成配置的FTDI description与Programmer实际USB Target不一致。修改旧Demo路径下ftdi_ti.cfg不一定影响当前应用。历史未保留该次失败的完整错误原文，不编造OpenOCD报错字符串。

### Cause

实际板卡为Quad RS232-HS；成功参考是2026.1重新生成BSP的`gpioDemo_ti.launch`，并非旧memTest_ti。当前launch使用本项目`software/apb_reg_test/openocd/`的配置副本，不使用旧D:/Efinity/projects/...路径。

### Diagnosis

以Programmer检测结果和Debug Configurations实际`-f`路径核对，不仅看FPGA型号、旧settings的Trion DEVKIT或编辑过的同名文件。

### Fix

保持当前已验证参数：

```tcl
ftdi device_desc "Quad RS232-HS"
ftdi vid_pid 0x0403 0x6011
ftdi channel 1
```

Titanium DEVKIT=11、Hard JTAG_USER1、800kHz、readWaitCycles40、jtagMapping 8 8 0 1 2 2；`cpu0.yaml`来自正式soc_control。OpenOCD工作区固定末1KiB F900FC00，避免覆盖RAM应用入口；不为修复改生成Sapphire或参考Demo。

### Verification

负责人在成功gpioDemo_ti环境确认单步、Resume与程序运行；正式apb_reg_test随后B～E均通过。当前具体配置入口见[BUILD](BUILD.md)。

## Jim Tcl does not support the wrapper's info script command

### Symptom

用户实际反馈，项目包装脚本第二行的`[info script]`在当前Efinix OpenOCD内置Jim Tcl中不支持。没有归档完整异常文本，不补写猜测的错误字符串。

### Cause

包装脚本依赖该Tcl命令求自身路径，与本版Jim实现不兼容。

### Diagnosis

按当前launch实际配置入口执行；本地检查使用真正的OpenOCD/Jim，而非只用普通Tcl代替。

### Fix

`debug_ti.cfg`直接使用launch显式传入的`bsp_loc`作为proj_loc，不依赖`info script`、cwd或逐级父目录搜索。保持gpioDemo_ti的`-c set bsp_loc`和两个`-f`组织；兼容入口`sapphire.cfg`也不再使用该命令。

### Verification

实际Jim配置解析回归通过；B已由负责人真实Debug验收，后续阶段保持成功文件。

## Packer: required pin jtag_inst1_TDI is not found

### Symptom

无CPU/EDB的早期显示基线packing报告：

```text
ERROR : Required pin jtag_inst1_TDI is not found
ERROR : Found 1 errors while checking core interface requirements
ERROR : Failed to run packer
```

### Cause

仍保留JTAG_USER1 physical，但TDO曾接常量0，TDI无使用者被优化删除；generated interface要求该输入存在。

### Diagnosis

核对peri required input/output、顶层TDI实际使用及综合结果，不直接删除物理JTAG block。

### Fix

**历史无CPU基线**曾用TDI→TDO透传保留required pin，临时副本综合/packing验证通过。**当前正式版本**已由Sapphire唯一驱动TDO；必须移除历史占位，不能同时存在Sapphire/透传/EDB多个驱动者。不要将旧透传重新加回当前顶层。

### Verification

历史packing检查解决required pin错误；当前Sapphire接入和Hard JTAG已通过B～E实板验收。当前无EDB依赖，也未手改生成debug_top.v。

## RGB color bars corrupted by an asynchronous frame-start glitch

### Symptom

早期RGB基线HDMI有重复明暗横带和密集彩色竖纹，用户反馈LED2/3/7全闪烁。

### Cause

旧`rgb_tpg`组合译码`rst_n && v_count==0 && h_count==0`同时用于writer start及write FIFO异步reset。首活动行结束时h从末值回0、v从0变1，传播间隙可短暂译码为真，帧中清FIFO。只按clk边沿采样的测试会漏掉这种毛刺。

### Diagnosis

逐个frame_start事件检查捕获异常脉冲；64×8激励曾出现560ns额外间隔，正常应6720ns。连续512×64路径第一帧8192beats变成8064beats，随后像素/地址错误；1536word跨FIFO回绕测试通过，排除单纯FIFO顺序假设。

### Fix

将frame_start改为寄存器，在最后一行最后一周期置高一拍；进入首行horizontal blank时输出20ns脉冲，下一拍清零。保持原writer同步与FIFO reset接法、固定启动delay和DDR/IP参数。当前RGB TPG继续保留这一修复。

### Verification

四次frame_start间隔正确；连续三帧98304pixels逐像素通过，P0/P1/P2/P3、128→64、双像素和RGB分量检查通过。负责人2026-10-14确认A持续红绿蓝白显示通过。

当前LED2/7为sticky、LED3是实时underflow；“全闪烁”本身不能证明AXI错误或唯一根因，也不能据此猜改reset。降低TPG帧率只可作为隔离带宽的诊断，不代替毛刺修复。

## Historical Bayer / Debayer chain (inactive)

### Symptom

首个无摄像头基线曾复用Demo10 Bayer链，本地仿真发现红蓝色条内部周期性混色。**当前XRGB8888链不经过该Debayer，不按本节设置当前颜色。**

### Cause

按旧Framebuffer读序 `[31:24]→[23:16]→[15:8]→[7:0]`定义连续Bayer8样本，有效输入相位为BGGR：偶行B G B G，奇行G R G R。旧raw_to_rgb偶数处理行high像素的R/B插值来源接反；代码注释互相矛盾，不能按注释猜相位。

### Diagnosis

历史CSI截断顺序为`{data[39:32],data[29:22],data[19:12],data[9:2]}`，TPG接其后的32bit vin。ser2par把早字移到128bit高位，vid_par2ser高16bit先输出；gain在VS下降沿复位行相位，偶行high/low使用B/G增益、奇行使用G/R。line_buffer中o_p_01为当前行、o_p_00上一行、o_p_11上上行；按中间行追踪raw_to_rgb，再核对debayer输出内部B/G/R与历史顶层R/B mapping，不能把byte/pixel序号反过来。

### Fix

历史正式副本仅交换raw_to_rgb偶数处理行high像素的`w_r_00_00_h0`/`w_b_00_00_h0`取值来源：内部R取后者>>1、B取前者>>1，保持其余插值。gain=Q8.8的0100、gamma旁路；保留历史顶层再次R/B映射，得到最终RGB。首两行、左边界及色条交界仍受旧插值边界影响，未重写边界算法。

| 历史最终色条 | 偶行32bit字 | 奇行32bit字 | 修正后内部RGB | 历史DVI输入RGB |
|---|---|---|---|---|
| RED | 00000000 | 00FF00FF | 0000FF | FF0000 |
| GREEN | 00FF00FF | FF00FF00 | 00FF00 | 00FF00 |
| BLUE | FF00FF00 | 00000000 | FF0000 | 0000FF |
| WHITE | FFFFFFFF | FFFFFFFF | FFFFFF | FFFFFF |

这些字按**高byte先**解释，与当前XRGB beat低pixel先不同。历史配置在tpg_config.vh，当前RGB配置在rgb_tpg_config.vh，不混用。

### Verification

历史gain/line_buffer/raw_to_rgb仿真及无摄像头显示基线通过；Phase 2转为XRGB8888后用独立RGB路径验证颜色。**Needs confirmation：有效输入BGGR不证明Sensor原生Bayer相位，后者仍需CSI物理序号/Sensor坐标资料；该未知项不影响当前架构。**

## Runtime triage: pending swap or black screen

### Symptom

复验/后续扩展时pending不清、画面不更新或启动黑屏。

### Cause

不能仅凭现象认定新根因。可能是仍在等B、没有边界事件、旧R/流水线未结束、FIFO empty未确认、INIT/reader错误或误用旧bit/ELF。

### Diagnosis

按序读取：

1. SERVICE_STATUS bit5、QUOTA=128、WATERMARKS=02000180确认含正式保护的bit；VERSION相同不能单独识别修复前后版本。
2. cal_done/PLL及INIT_DONE、init beats/bursts、FRONT_VALID；CPU运行前应能稳定显示启动色条。
3. STATUS.BUSY/ERROR_CODE、BUFFER_STATUS.WRITER_OWNED；最后B未完成不能swap。
4. BOUNDARY_COUNT是否前进；READER_OUTSTANDING、DATA/RESERVED、READER_ERROR与FIFO水位；最后AR不是读完成。
5. underflow/missed相对稳定baseline的delta、AR/R各自max与writer max。AR max大偏向请求等待，R max大偏向在途返回/接收进展不足；这些不是对IP内部的确定证明。

### Fix

先保存完整CSR/结果结构、bit/ELF来源和时序报告；不清历史计数掩盖错误，不用增hold、取消全屏fill、改DDR timing/PLL或强制交换绕过。CLEAR_DONE不是取消pending。INIT/reader错误按当前设计需平台复位/重新配置恢复；软件不能中断未完成AXI。

### Verification

以连续绘制/显示、读写均进展、无稳态欠载/missed、正确安全换帧与参数图像为标准，使用[VALIDATION](VALIDATION.md)复验，不把CPU暂停后的恢复当连续性通过。

## LED observations

当前顶层LED的**逻辑含义**如下，板上亮灭极性需按原硬件判断；优先以CSR确认，不仅凭闪烁推断故障。

| LED | 逻辑信号 |
|---|---|
| 0 | cal_done后心跳cnt[24] |
| 1 | INIT_DONE |
| 2 | write FIFO full sticky，随对应TPG域复位清除 |
| 3 | CVO实时read_underflow，非sticky计数 |
| 4 | AXI write beat counter的bit22 |
| 5 | AXI read beat counter的bit22 |
| 6 | vid_rst_n |
| 7 | AXI response error sticky，随对应诊断域复位清除 |

read_underflow_sticky虽在内部存在，LED3实际接实时信号；新增DISPLAY_UNDERFLOW_COUNT提供平台累计观察。启动期短暂欠载与稳态持续新增按baseline/delta区分。

## Legacy notes retained without code changes

历史Phase 1记录的`frame_info_det.frame_len_d0 <= frame_end_r0`不是可靠帧长度比较；旧FrameBuffer存在6bit内部ID到4bit DDR接口等继承细节。当前活动RGB路径不使用该旧frame_info_det；相关源码本次只读，未顺手修复。重新启用旧链前须独立复核，不能从Phase 2颜色验收推导旧Camera/Debayer全链已验证。

SDC历史将CLK_25M的`<USER_PERIOD>`修正为40.000ns，已在当前基线中；不要求本轮再改约束。Camera/DSI物理块仍保留，时钟名含MIPI也可能服务core/TPG，不按名称删除。
