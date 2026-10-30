# 显示与 BLIT 的 DDR 读仲裁

`rtl/framebuffer/ddr_read_arbiter.v` 是双客户端 AXI 读仲裁模块。显示与 BLIT 共用一条128位 DDR 读通道、ID0，全局最多一笔未完成的读事务。独立仿真通过，现已接入正式framebuffer、工程清单及显示FIFO/guard/写准入；系统验证见 [SYSTEM_BLIT](SYSTEM_BLIT.md)，综合时序及实板仍待验收。

## 这一步的作用

源窗口检查器回答“这块源图允许读吗”；仲裁器回答“这一次先让谁读，返回的数据给谁”。显示和 BLIT 分别提供自己的 AR 请求和 RREADY，仲裁器向 DDR 提交其中一笔，并只将对应 R 返回给原请求者。

```text
Display Reader 的 AR/R ─┐
                       ├─ ddr_read_arbiter ─ DDR 的 AR/R
BLIT 的 AR/R ──────────┘
```

它不处理写通道、图像范围、Back ownership、安全换帧或资源加载，也不占有整条 BLIT 命令的全部读服务时间。BLIT 两笔读 burst 之间可以穿插显示读取。

## 接口

| 信号 | 含义 |
|---|---|
| `clk / rst_n` | core时钟与平台复位；必须和DDR读通路、两个客户端一起恢复，不能使用CPU/debug reset取消DMA |
| `enabled` | 只控制新仲裁；已经提出的AR与已经接受的R事务继续完成 |
| `display_active / display_fifo_level` | 显示是否活跃及读FIFO的core域占用量；单位沿用现有reader的128位word |
| `display_launch / display_flush` | 仅重建显示供数优先级，不复位仲裁、地址或owner |
| `display_ar* / display_r*` | Display Reader的请求/响应；输入ADDR32、LEN8、VALID、RREADY，输出ARREADY和完整R |
| `blit_ar* / blit_r*` | B执行层的对应请求/响应，源地址已经是绝对字节地址 |
| 无前缀 `ar* / r*` | DDR一侧；数据128、RID4、RRESP2、RLAST；常量sideband为ID0/SIZE4/INCR/CACHE3/PROT2/LOCK0/QOS0 |
| `address_pending` | 已选中并暴露AR，但DDR尚未接受 |
| `read_active` | AR已被DDR接受，读事务尚未正常退休；协议FAULT也保持 |
| `busy / owner_blit` | busy表示pending或active；busy=1时owner_blit为0表示显示、1表示BLIT |
| `beats_left[8:0]` | 尚需接收的拍数，支持1～256拍；协议故障后饱和到0，不回绕 |
| `fault / fault_code` | 平台复位前保持的本地协议故障；wrapper将fault折叠为已有READER_ERROR=0x2004，fault_code本身不新增CSR或B错误码 |
| `display_bursts / blit_bursts` | 各自实际AR握手数 |
| `display_beats / blit_beats` | 各自实际R握手数，包括传给原owner的错误/故障响应；不是帧成功数 |

两个上游客户端必须遵守AXI规则：ARVALID提出后，地址和长度保持到自己的ARREADY握手。上游只有在对应DDR握手当拍才得到ARREADY，仲裁器没有提前接收的隐藏请求队列。

## 正常调度

1. 空闲时选择一方，寄存地址、长度和owner；下一拍对DDR暴露ARVALID。
2. DDR未给ARREADY时，保持ARVALID及载荷；后来出现更紧急的显示请求也不能撤回或替换这笔AR。
3. DDR接受AR后，保留owner；RVALID/DATA/ID/RESP/LAST只交给该方，DDR RREADY只取自该方。未选方的响应输出为0。
4. 接收到第 `ARLEN+1` 拍，且同次握手RLAST=1，才正常释放owner。新的请求随后再仲裁。

第一拍R与AR同拍握手也支持。若客户端当时未就绪，DDR必须按AXI规则保持RVALID及载荷，等原owner给RREADY。

默认低/高水位为384/512。显示活跃且FIFO达到或低于LOW时，显示优先；LOW与HIGH之间保持原健康状态，达到HIGH后恢复正常轮流。launch/flush也使显示先补数。仲裁直接观察即时低水位，避免等健康寄存器更新才响应。

两方持续请求、显示处于健康状态时，每次正常完成后优先权交给另一方。单次grant一旦选定就不抢占。只有BLIT请求时，即使显示低水位也可以服务BLIT。仲裁器支持整个AXI LEN范围1～256拍，保留现有显示128拍；B自己的最多32拍限制仍由B实施。

**进展条件有边界：** 健康状态下连续竞争的两方不会相互饿死；显示一直紧急时优先显示，不能承诺BLIT在固定秒数内获服务。当前事务本身也必须获得DDR响应和原owner的READY。正式接入后，需用实际FIFO水位、DDR延迟和负载核对B的27位无进展watchdog（100MHz约1.34秒），不能把模块仿真当作板级等待上限证明。

## 协议故障与恢复

| 本地fault_code | 触发条件 | 处理 |
|---|---|---|
| 1 | 没有已接受的AR时出现RVALID，包括AR尚未握手的情况 | 停止新仲裁；无在途读时不创建owner；已有待接受AR保持到握手，之后仍归原方 |
| 2 | R握手时RLAST早到、应到未到，或已耗尽拍数后仍接收数据 | 保留原owner/active，停止新仲裁；后续R只能路由到原方，不能因后来的RLAST而退休 |

只保留首次故障码。已经暴露的AR即使遇到故障也不能撤回。RRESP/RID错误原样交给owner处理，不把它们当作换owner的依据；拍数与RLAST合法的错误响应可以排空并退休。仲裁器不增加会取消DMA的超时。

fault只由统一平台复位清除；display_flush/launch和enabled变化不清故障。正式集成须让平台控制层观察fault并停止后续正常工作、记录诊断及执行统一恢复；不能因fault下busy=0就把无owner情况当作正常空闲。B的0x25和manager的Back ownership仍按各自契约保留；本地fault_code没有直接冒充B ERROR_CODE。

## 正式连接时需要处理的地方

- `rgb_framebuffer.v` 的 Display Reader 读端改接 `display_*`，B读端接 `blit_*`，共享DDR端接无前缀端口。现有reader ID为6位，按原平台约定截取/补零；两方的事务均使用ID0。
- 原 `read_frame_guard` 必须观察显示客户端自己的AR/R；`ddr_write_admission` 的read quota、outstanding和延迟统计也只能来自显示事务。BLIT的R不能进入显示FIFO或被计作显示服务。
- 显示flush只复位应复位的显示缓冲；保持B缓存、仲裁owner和在途事务。读通路故障后不能承诺HDMI继续正常供数。
- Back写地址仍只加一次manager锁存的 `command_base`，保留现有写准入策略。读服务不依赖先获得写准入。
- 新本地诊断未映射CSR，正式API/寄存器、版本/能力、工程源清单和综合时序仍待统一集成。

## 仿真复现

只检查仲裁器：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/run_read_arbiter_checks.ps1
```

也可运行原 `scripts/run_graphics_checks.ps1`，现在先执行仲裁器，再执行源范围、执行层、manager和双缓冲回归。两者都支持 `-NoWave`。需要PATH中的Icarus `iverilog`、`vvp`；仲裁器测试不需要Python。

独立入口输出在 `output/read_arbiter/`，统一入口对应 `output/graphics/read_arbiter/`，均已忽略提交。包含 `read_arbiter.log`、可选 `read_arbiter.vcd` 和故意串线的 `routing_expected_failure.log`。

测试使用独立的客户端握手记分板，不读DUT内部状态。覆盖显示128拍、BLIT32拍、计数器256拍边界、数据全部lane和sideband、R路由、AR/R停顿稳定、低/高水位双向滞回、健康持续竞争、launch/flush/enable、RID/RRESP传递、AR/R同拍、两种owner的早/缺RLAST及额外数据、无owner响应、AR等待期故障和平台复位恢复；另有200笔固定种子的随机事务。

2026-10-17：27个场景通过（其中包含200笔随机事务），共249次DDR AR握手、10,274拍归属受检的R握手；独立模块编译无warning。原图形回归的852个源矩形用例及124个执行/合同/双缓冲场景也通过；五种故意错误负对照分别被检测到（仲裁串线1种，原图形测试4种）。

`+SWAP_RESPONSES`负对照仅在testbench故意交换客户端看到的RVALID，独立记分板必须报“Read response routed to wrong master”，runner要求该次按预期失败。

这里的Display/BLIT客户端和DDR由测试激励提供，没有连接真实B执行层、显示reader、FIFO、写准入或完整1080p像素流水线。因此结果证明模块仲裁/路由协议，不证明整机显示无underflow/missed，也没有Efinity资源/时序或实板性能结果。
