# Validation

## Status and Evidence Rules

**Phase 2基础框架已完成，Checkpoint A～E均由项目负责人完成实际FPGA验收并明确确认通过。** D包含连续显示修复后的重新Compile/Programmer/HDMI验证，E包含最终Demo验收。

板级通过依据是负责人的实际验收确认，不是把软件模型或RTL仿真冒充硬件。已有记录没有单独附完整bit/ELF时间、运行时长、所有CSR原始读数或板级吞吐数值；这些不能由“通过”反推出具体数字。开发记录日期集中在2026-10-14～15，后续复验应另记实际环境。

## Checkpoint Matrix

| Checkpoint | 范围 | Simulation / local evidence | Hardware |
|---|---|---|---|
| A | XRGB8888 TPG→DDR→RGB Reader→HDMI | RGB顺序、FIFO回绕、注册frame_start、连续三帧并发路径通过 | 负责人确认持续红/绿/蓝/白四竖条稳定，通过 |
| B | Sapphire OCRAM、APB3、自定义regs、Hard JTAG | WAIT0/1/3各113access；GDB/Jim配置解析通过 | 负责人确认Debug、ID/版本/RW/SCRATCH验证通过 |
| C | FILL_RECT→AXI写→DDR槽0→HDMI | init屏障、writer像素/strobe、错误/排空、WAIT0/1/3集成通过 | 修改x/y/w/h/color能改变实际矩形；同buffer绘制期间允许tearing，通过 |
| D | Front/Back、safe swap、连续显示 | manager/CDC、完整R guard、全尺寸并发压力及C回归通过 | 修复Writer期黑屏后重新Compile/下载，连续HDMI稳定，通过 |
| E | 多命令完整场景、API、无限循环、参数模式与诊断 | 实际ELF在MMIO模型下1000场景/4000命令/1000交换确认；错误注入通过 | 负责人明确确认Checkpoint E通过；Phase 2完成 |

早期Phase 1无摄像头Bayer显示基线也曾由负责人确认通过，但不是当前正式2D数据路径。其有效Bayer相位、修正和限制归入[TROUBLESHOOTING](TROUBLESHOOTING.md)。

## Simulation Results

### RGB / APB / FILL_RECT

| 测试 | 已记录覆盖 |
|---|---|
| rgb_tpg / tb_rgb_tpg_pulse | 连续完整1080p帧、518400beats/frame、集中blank参数；修复前额外frame_start脉冲，修复后四个间隔正确 |
| RGB数据序测试 | P0/P1/P2/P3相邻不同颜色、AXI byte lane、128→64、双像素、74.25→148.5MHz和RGB通道 |
| tb_fifo_sequence | 原FIFO1536个不同word跨1024深度回绕 |
| tb_rgb_pipeline | 512×64连续TPG/共享DDR/原reader/CVO/serializer，三帧98304最终pixels；修复前首帧8192beats仅写8064，修复后通过 |
| tb_accel_regs | APB WAIT=0/1/3，各113access；setup/access wait、RO/RW、错地址/对齐/PSLVERROR、START单次与reset |
| tb_init_write_monitor | 延迟最后B、FIFO/流水线idle、BRESP/overflow/WLAST/协议/无进展超时，INIT_DONE不可提前或回退 |
| full-init | 1920×1080：518400个W beats、4050 AW/WLAST/B bursts，真实初始化writer；不是单独的完整1080p显示带宽证明 |
| tb_fill_rect_writer | 独立像素记分板、矩形外保持、非四对齐/WSTRB、4KiB、最大burst、多色、右下角1pixel、整屏clear、输入快照、非法几何/加法溢出、AW/W背压、B错误、超时VALID保持并排空、最后B前不DONE |
| tb_checkpoint_c | ONE_FRAME TPG、原writer/reader/FIFO、APB/monitor/engine、unpack/CVO/serializer共享DDR模型；WAIT0/1/3各检查98304pixels，含early START/BUSY拒绝及CPU reset不破坏命令 |

C历史成功DONE额外等待两个VS（SETTLE_FRAMES=2），且读写同槽0；**当前正式模式使用SETTLE_FRAMES=0及双缓冲**，不能把旧完成规则搬入当前寄存器说明。

### BLIT Independent RTL Prototype

2026-10-17 将 Person B 本地原型整理到仓库，并从新的 `scripts/run_blit_checks.ps1` 入口复验。执行单元为 `rtl/accelerator/blit_engine.v`，测试平台为 `sim/tb_blit_engine.v`；接口草案、工具依赖、运行及输出说明见 [BLIT](BLIT.md)。

| 测试组 | 结果 / 范围 |
|---|---|
| basic，64×48，最多32beats | 32用例：四像素/棋盘/唯一像素、stride padding、边缘、参数快照、非法参数、R/B响应与ID错误、五通道超时排空、RLAST异常及平台复位 |
| boundaries，1088×48，最多32beats | 5用例：长行分段、源4KiB、目标4KiB、读写距边界不同、右下角 |
| single_beat_buffer，1088×48，最多1beat | 同5用例通过，验证最小缓存与计数边界 |
| scoreboard negative control | 故意改坏像素后，自动比较按预期失败；runner要求检测到错误才判定负对照通过 |

共42个用例通过，另通过一次错误像素检测负对照。目标像素、区域外保持、源不变及AXI burst/握手由独立记分板和内存模型检查。PNG只转换实际内存导出的PPM，不参与正确性判定。

该模块尚未加入正式顶层或Efinity源清单，未改现有FILL_RECT、寄存器、DDR/显示路径或生成IP。本轮没有验证Efinity综合、资源/时序、真实DDR并发、HDMI显示和板级性能。

### FILL / BLIT Dispatcher Independent RTL（源检查器接入前记录）

2026-10-17：`graphics_engine.v` 在独立仿真中组合原FILL/BLIT，尚未加入正式顶层或Efinity源清单。复现入口为 `scripts/run_graphics_checks.ps1`，运行和端口规则见 [GRAPHICS_ENGINE](GRAPHICS_ENGINE.md)。

| 配置 | 结果 |
|---|---|
| basic：32beat，FILL=0/BLIT=1 | 43用例通过 |
| single_beat_remapped：1beat，FILL=7/BLIT=9 | 42用例通过；无提前RLAST的多beat条件，跳过该用例 |
| manager_contract：现有真实buffer_manager+B | 7用例通过；C源检查结果寄存模型、模拟DDR、reader-safe/empty为测试输入 |
| scoreboard negative control | 故意写坏像素，按预期被逐像素记分板拒绝 |

共92个用例：覆盖FILL→BLIT→FILL与同类连续执行、任意像素FILL边缘、参数/操作快照、公共计数和旧状态隔离、disabled/忙时请求、非法操作/几何、最后B前不完成、AXI停顿稳定、读写响应错误、两类超时安全排空、BLIT协议FAULT和平台复位。逐像素检查目标、区域外保持和源不变；分步图片导自实际目标模拟内存。

本轮A/C适配新增：公开op/x/y/width/height/color/src_addr/src_stride/start/accept端口；非法opcode改为0x26；C在accept边沿锁存源范围结果，B在下一拍CHECK_SOURCE读取，结果无效也计数、报0x21且不启动BLIT/不暴露AR/AW；FILL忽略源范围限制。真实manager合同检查0x21/0x26结束后释放Back、只由真正接收的新命令清错误、pending时不接收及0x25保持Back/BUSY并阻止swap提交。未修改manager实现。

原BLIT42用例及其负对照、原 `tb_fill_rect_writer` 回归通过；工程51个源条目/47个CSR一致性检查通过。共享模拟内存新增可选byte-strobe模式，BLIT原用例默认仍要求全strobe。PNG脚本新增可选名称参数，旧调用兼容。FILL/BLIT子执行单元、正式APB/软件、Framebuffer/显示、生成IP和工程清单均未修改。本轮未验证C的真实源窗口算法、显示/BLIT读仲裁/owner路由/最大等待，也没有Efinity综合/时序、真实DDR/显示并发或实板性能结果。首轮src_stride=7680由C检查；模型中的其他stride用于验证B通用搬运能力，不代表正式平台允许其他stride。

### FILL / BLIT Double-buffer Loop（首次记录）

2026-10-17：新增 `sim/tb_graphics_double_buffer.v` 与 `sim/graphics_double_buffer_memory.v`，由 `scripts/run_graphics_checks.ps1` 一并运行。连接真实B执行层和现有真实manager，两块物理内存均可读写且跨换帧保留内容；源图由FILL命令生成，不预置图块。

| 配置 | 结果 |
|---|---|
| double_buffer：最多32beat | 11个场景、20条命令、8次换帧、178,176次像素比较通过；导出7步实际内存图片和可选VCD |
| double_buffer_single_beat：最多1beat | 同11个场景、20条命令、8次换帧、178,176次像素比较通过 |
| CORRUPT_FRAME负对照 | 故意修改第二次换帧后的Front像素，独立记分板按预期报错 |
| STALE_BACK_BASE负对照 | 故意让wrapper在换帧后仍写Buffer1，地址断言按预期报错 |

覆盖四色图块FILL构建、两方向BLIT、多次成功swap、非零源坐标、右下角、非对齐FILL叠加、AR反压下pending及额外命令拒绝；全部W完成但最后B被扣住时仍保持BUSY/Back ownership且不能swap，B结束和释放后仍等下一边界。另检查reader-safe/FIFO-empty确认、sticky swap结果清除、命令计数、AXI稳定性和目标基地址只加一次。

原执行层85场景、错误manager合同7场景及新增22场景，共114场景通过；3个故意错误的负对照均被拦截。原BLIT42用例及其负对照、原FILL回归通过。Icarus提示原 `fill_rect_writer` / `buffer_manager` 继承timescale，未修改这些已验证RTL。

本次改动是仿真模型、测试、运行入口和文档。64×48画布/256字节stride用于缩短仿真；APB命令、真实C源检查器、显示读仲裁、显示FIFO/CDC、HDMI和DDR/PHY不在本测试路径。reader-safe/FIFO-empty及边界由测试驱动；故意制造的reader不安全边界使missed计数增1，不能据此报告实板underflow/missed或带宽。后续仍需正式接入、综合/时序检查和实板验收。运行与7张分步图说明见 [GRAPHICS_ENGINE](GRAPHICS_ENGINE.md)。

### BLIT Source Guard（当前仿真）

在上述初版基础上，新增 `rtl/framebuffer/blit_source_guard.v` 和 `sim/tb_blit_source_guard.v`，合同及双缓冲测试已改为连接真实源检查器。实现和接收时序见 [BLIT_SOURCE_GUARD](BLIT_SOURCE_GUARD.md)，同一个 `scripts/run_graphics_checks.ps1` 入口运行。

| 配置 | 结果 |
|---|---|
| source_guard_1080p，1920×1080 / stride7680 | 426个矩形，其中400个固定种子随机；保持/复位检查通过 |
| source_guard_small，64×48 / stride256 | 同426个矩形及保持/复位检查通过 |
| manager_contract，真实B/manager/检查器 | 扩展为17场景，源拒绝计数/0x21/无AXI/释放Back、连续有效/无效快照、FILL兼容、pending/FAULT保护通过 |
| double_buffer / double_buffer_single_beat | 每组仍11场景、20命令、8次swap、178,176次像素比较；Front角色交替时由真实检查器计算结果 |
| BYPASS_SOURCE_GUARD负对照 | 故意将B范围输入绑1，断言检测到非法命令暴露AXI，按预期失败 |

两组独立源矩形共852个，加原执行层85场景、当前合同17场景、双缓冲22场景；总入口合计852个源矩形与124个执行/合同/双缓冲场景，4种故意错误负对照通过。参考逐行检查源字节区间，覆盖源行跨越、右下边界、有效图像后空隙、Front/Back角色、非像素对齐、错误stride、巨大宽高及地址溢出；接收后变更实时参数不改变已锁存结果。

正式APB/软件、`rgb_framebuffer.v`、工程源清单、DDR/PHY、HDMI未修改。源检查器仍待正式接入与Efinity综合/时序检查，常量除法/取余的100MHz时序与资源尚未验证。DDR、显示边界、reader-safe/FIFO-empty仍是模型/测试输入；当前不含读仲裁、实际读owner/响应路由/最大等待、显示并发连续性或新实板验收。原FILL/BLIT执行RTL和manager均未修改；继承timescale提示保留。

### Buffer Manager / Reader / CDC

- manager单测64个异相事件、11次交换，检查Front≠Back、busy/pending、writer完成仍无边界、边界到来但writer未完、sticky DONE/CLEAR_DONE及FIFO empty反馈。
- video周期13.466ns、core10ns、初相2.123ns；包含50个单video周期窄事件，验证toggle事件不丢失。
- read guard使用正式518400R beats/4050bursts；最后R反压、FIFO写流水线未idle、第二帧base、AR/RLAST/RRESP/relaunch错误。
- D最终缩放pipeline WAIT0/1/3各5次swap，日志报告29完整帧/981792受检pixels；检查AW只落Back、AR只落Front、帧内base固定、多命令不自动swap、CPU reset不丢所有权。
- 故意扣住最后R跨两个boundary时，禁止flush/launch/swap；故障窗口允许显示异常、暂停像素断言，不把此窗口计作“无欠载通过”；释放后恢复完整新帧检查。
- 引入读进展准入后，旧激励“永久扣最后R→等Writer完成→才放R”会互等。测试改为先完成Back，再扣R并请求swap；保留读响应排空安全断言。准入单测另测无读进展不得发新写。

初版D未加连续性保护时，缩放pipeline曾报告18帧/621343受检pixels，但随后实板连续写黑屏。因此“局部仿真通过”不能替代完整并发压力和硬件验收。故障定位/最终修复见[TROUBLESHOOTING](TROUBLESHOOTING.md)。

### Display-protection / Full 1080p Concurrent DDR Stress

准入单测覆盖真实128个R握手额度、RREADY=0不记账、B前R不预付、滞回、已暴露AW保持、safe slack进展、reader错误、计数与异相Gray underflow CDC。

压力使用实际reader/FIFO/unpack/CVO/serializer和FILL模块，1920×1080、518400R beats/frame、read FIFO1024×128、CVO1024×64、100/74.25/148.5MHz。每run四轮全屏clear+非对齐矩形、四次swap；在active第8行启动Writer，不只躲在VBlank写入。

DDR模型加入独立AR/AW背压、W接受间隔、B延后、first-R延后及写偏置read turnaround；RVALID一旦出现保持至READY。这不是加密DDR真实内部模型。

| WAIT | 返回延迟参数 / core cycles | 帧 / swaps | 检查pixels | Writer MB/s — Simulation Result | 最长R等待 / cycles | underflow / missed增量 |
|---|---:|---:|---:|---:|---:|---:|
| 0 | 64 | 24 / 4 | 49,766,400 | 130.660124 | 101 | 0 / 0 |
| 1 | 64 | 24 / 4 | 49,766,400 | 129.884659 | 102 | 0 / 0 |
| 3 | 64 | 24 / 4 | 49,766,400 | 128.880378 | 102 | 0 / 0 |
| 3 | 384 | 48 / 4 | 99,532,800 | 51.665033 | 422 | 0 / 0 |

合计248,832,000个最终RGB像素，Front构建期不变、Writer最终完成、swap后reader_base=Front且图像正确。每run为2,074,798个W beats；最严写忙64,253,841core cycles。吞吐按握手beat数×16bytes/命令写忙时间计，部分边缘WSTRB仍按总线beat计；不含hold，不是板级有效图像拷贝测速。

最严诊断：WR_bursts64872、throttle59695188、AR_wait6984/max_AR1、R_wait45951132/max_R422、underflow_delta0、frame_completions49、max_write70。读帧完成可比已显示完整帧多1，因为下一帧已预取结束。

负对照关闭准入策略，512×64在busy=1、R_wait5817、FIFO0时underflow失败，失效前Writer约933.924310MB/s；这是**预期失败**，不能拿失效前速度作可持续吞吐。打开策略同小模型通过16帧/4swap/524288pixels，约163.930549MB/s，不替代上述全尺寸运行。

### Software / Debug / Provenance

实际默认RV32 ELF在Unicorn2.1.4中执行，外设为MMIO行为模型：1000连续场景、4000完成命令、1000交换确认，target到达后running仍1；验证所有命令参数、Front/Back归属及CPU仅访问OCRAM/APB。

另测旧sticky DONE、command/swap自然回绕、hold60、启动历史underflow7/missed3基准、CPU重跑等待旧writer或pending swap。仅改五参数重编得到321/123/137/89/00123456，单矩形模式提交值一致。宽0保留硬件11错误、不发布失败Back；ID/策略关闭、init/ack/done/swap/hold超时、拒绝、B/reader错误、underflow/missed新增均保存快照、pass回0并停止提交，无reset。

这些是**软件控制流/寄存器模型测试**，不模拟真实Sapphire器件、HDL safe boundary、DDR PHY或HDMI。缩短poll的故障ELF和参数变体在Temp，正式ELF仍20,000,000次poll。

实际GDB数字解析器及OpenOCD Jim配置回归使用硬件mock；真实Hard JTAG成功来自负责人B～E实板确认。正式BSP/linker/start.S的构建为rv32im/Og/g3/Wall/Wextra/Werror，LOAD/stack只在OCRAM且低于F900FC00。

原参考区1775文件的内容/集合曾校验不变。D连续性保护清单原含2351项，其中IDE `.metadata`日志/索引会随用户Debug变化；E收尾时曾校验2338个硬件/生成/Debug文件，排除这些运行时状态，不能用重置IDE缓存伪装源码一致。

## Hardware Acceptance

A～E均已由负责人明确确认通过。已知D实测为Writer活跃期黑屏→写准入修复→重新Compile/下载→持续稳定，E最终Demo也已确认通过。

**没有单独提供的原始数据仍留作待记录项，不影响已经确认的验收结论：**

| 证据项目 | 已有记录 / TODO |
|---|---|
| 各阶段功能与最终视觉验收 | 负责人确认A～E通过 |
| 本次bit/ELF来源、时间、完整Compile资源/时序报告 | TODO：需要长期追溯时补录原始文件/报告 |
| 连续运行实际时长、iterations、commands/swaps | TODO：未提供独立数值，不用1000轮软件模型替代 |
| underflow/missed稳定baseline→最终值、AR/R max、FIFO、throttle进展 | TODO：未提供板级原始采样值 |
| 板级Writer/DDR吞吐、CPU负载、软硬FPS对比 | TODO：尚无真实性能测量；部分对比功能仍Planned |

## Revalidation Checklist

复验操作见[BUILD](BUILD.md)。默认mode0、limit0、hold60、target1000，取消绘图断点；建议至少10分钟并继续到1000场景，记录1/5/10分钟及里程碑。它是**复验标准**，不是在此补造既往实测时长。

- HDMI两组场景整帧切换；绘制Back期间旧Front稳定，无黑屏/闪屏/明显tearing/半屏/颜色顺序异常。
- 命令、完成、swap和读帧数进展；back_ready时issued=completed，默认每场景4命令/1swap；无限循环里程碑后继续运行。
- 初始化稳定并等待3个显示周期后软件保存baseline，保留历史非零值；运行后underflow_delta/missed_delta=0，不能清零/重建基准掩盖新错误。
- error_code/reader_error、errors/timeouts/rejected均0，pass1；AR/R等待和throttle增长正常，max不是错误计数，32位累计周期自然回绕。
- 再用back_ready确认旧Front，frame_presented确认地址互换；五参数重编/单参数模式验证位置尺寸颜色。断点检查不替代连续运行。

建议每次新增功能保存：工具/bit/ELF版本，运行时长，initial/final/delta计数，图像与故障记录，板级性能计量口径。软件pass1是自动检查结果，项目负责人完成视觉和长时验收后才签收新功能。

## Reproduction

以下为后续可复现入口，本次纯文档整理不重建代码或FPGA：

```powershell
python scripts/check_project.py
python scripts/check_apb_debug.py
python scripts/run_apb_checks.py
python scripts/run_rgb_checks.py --quick
python scripts/run_c_checks.py --full-init
python scripts/run_d_checks.py
python scripts/run_ddr_stress.py --simulator modelsim
python scripts/run_ddr_stress.py --simulator modelsim --apb-waits 3 --return-delay 384
python scripts/build_apb_software.py
```

当前静态入口为check_project.py，核对活动工程源和RTL/header/REGISTER_MAP一致性，不再调用阶段快照链。C/D及其它功能回归runner与testbench仍保留。

负对照（**预期失败，仅仿真**）：

```powershell
python scripts/run_ddr_stress.py --small --apb-waits 1 --unthrottled --simulator modelsim
```

Icarus/ModelSim需要本机已安装；ModelSim runner支持--modelsim-bin。软件MMIO模型可选依赖Unicorn2.1.4（不属于FPGA或BSP依赖），在临时目录安装后运行：

```powershell
python -m pip install --target "$env:TEMP/fpga-e-test-deps" unicorn==2.1.4
python scripts/run_e_software_checks.py --unicorn-path "$env:TEMP/fpga-e-test-deps"
```

## Warnings and Measurement Boundaries

- E历史C编译无warning（Wall/Wextra/Werror）；厂商统一OCRAM linker仍有LOAD RWX提示，未改生成linker。
- ModelSim最终压力harness有33项继承/未使用输出端口提示：FIFO DataVal、旧reader/writer test/QoS、testbench固定sideband/TPG统计等。早期完整WAIT矩阵尚未接新增诊断观察线有60项，后续严苛run/smoke补齐后33项并核对新CSR；不控制像素/准入逻辑。
- Icarus旧DC_FIFO constant-select和顶层timing32→13/audio_N32→20提示保留。仿真准备只在Temp兼容副本处理无尺寸拼接/Gray time-zero求值，不回写正式RTL。
- 顶层elaboration用真实module header生成空stub只验证接线；正式XML仍使用真IP。模拟器不执行加密DDR PHY/HDMI/CPU，不能据此证明物理时序、calibration或scheduler最坏时延。
- 128bit×100MHz的AXI单方向理论payload1600MB/s；DQ16×DDR400MHz双沿的理论峰值也为1600MB/s，均不是持续实测带宽。显示平均读payload497.664MB/s、active594MB/s。
- 约130～52MB/s为上述**Simulation Result**；最严模型8.2944MB全屏按51.67MB/s约0.161s，不能当作板上耗时。27位engine无进展watchdog约1.342s，软件poll次数非精确秒。

## Historical Compatibility and Evidence Files

历史地址/像素组织只用于解释旧测试，当前正式地址始终0/00800000：

| 阶段 | 历史组织 | 当前处理 |
|---|---|---|
| Phase 1 Bayer | Bayer8帧0x1FA400/129600 AXI beats；旧32bit输入518400有效字，非当前RGB beats | 不在活动2D链 |
| Phase 1 / A / B | 旧三槽0/007E9200/00FD2400，slot公式1920×1080×32/8+0x200 | 旧bank_switch模式保留给回归；正式D_MODE不用它 |
| C | 槽0原地绘制，SETTLE_FRAMES=2，允许绘制中tearing | 软件存档software/checkpoint_c，不用于当前验收 |
| D初版 / 连续性修复 | 49→51 design entries；swap基本正确但初版连续性失败 | 最终51项+IP，正式保护保留 |
| E | 软件/API/文档整理，硬件配置沿用修复后D | 当前活动software/apb_reg_test |

旧ELF符号只作追溯，**不作为当前固定地址**：

| 历史产物 | apb_test_done | g_apb_test_result / bytes | _sp |
|---|---|---|---|
| C | F9000460 | F900065C / 88 | F90026C0 |
| D初版 | F90009B0 | F9000B28 / 140 | F9002BC0 |
| D连续性修复 | F9000AE8 | F9000C60 / 192 | F9002D20 |
| E本地记录 | F9000CE0 | F900105C / 260 | F9003160 |

这些产物_start均F9000000，main曾为F900006C；Build后用符号查询。历史Temp快照包括fpga-checkpoint-c-baseline-3hqsdpd3、fpga-checkpoint-d-baseline-4p1nuf_f、fpga-d-continuity-baseline-7rp8sdu7，位于系统Temp，可能已清理，不能充当长期Git备份。

连续性/软件摘要中的关键数值、覆盖范围、warning和证据边界已合并至本文；独立阶段摘要已删除。旧日志中的“hardware pending”表示当时执行状态，当前实板结论仍以负责人最终确认优先。

可追溯Temp运行名：完整WAIT矩阵fpga-ddr-stress-na3bejd3，严苛fpga-ddr-stress-rny16y_v，负对照fpga-ddr-stress-t2iqk6gg，D回归fpga-d-checks-qtekut9x，C回归fpga-c-checks-7pb8trfa，RGB回归fpga-rgb-checks-bk3zxscb；E软件fpga-e-software-rncmwdcq，Debug解析fpga-apb-debug-check-1x500340，APB兼容fpga-apb-checks-i4iw15qi。若Temp已清理，用脚本重跑，不伪造日志。

阶段性哈希/来源指纹清单及其快照门禁已清理。它们不参与Efinity/RTL编译、软件Build或testbench；活动IP/BSP来源仍以正式生成配置、公共端口、soc.h和linker为准。保留的当前工程检查不需要这些历史文件。

## Documentation Consolidation Record

上轮Markdown整理逐文件阅读、核对独有信息后归并；随后本轮继续清理阶段性辅助快照/摘要。下表保留Markdown迁移去向：

| 原Markdown | 用途 / 判断 | 最终处置与独有内容归宿 |
|---|---|---|
| ARCHITECTURE.md | 长期有效；混有阶段描述 | 保留重写：最终模块/时钟/复位/所有权，合入Sapphire配置和D协议 |
| INTERFACES.md | 长期有效；与阶段owner文档重复 | 保留重写：A↔B/B↔C/A↔C冻结合同 |
| REGISTER_MAP.md | 长期有效；原表缺逐项reset | 保留重写：按当前RTL补47项reset/clear/bit field，含88..B8 |
| BUILD.md | 长期有效；Debug历史与流程混杂 | 保留重写：当前真实操作；故障原文移TROUBLESHOOTING |
| VALIDATION.md | 长期有效；阶段证据分散 | 保留重写：Simulation/Hardware分开，汇总历史独有测试和性能边界 |
| TEAM_SPLIT.md | 长期有效 | 保留细化：主责/禁止区/联调与共享变更政策 |
| PHASE1_ARCHITECTURE.md | 旧Bayer架构，不能当当前设计；含独有相位/打包/RB修正、JTAG和遗留细节 | 内容合入TROUBLESHOOTING历史Bayer/JTAG、本文历史地址；删除原文 |
| DEBUG_CHECKPOINT_A.md | 已解决frame_start毛刺，根因和证据有效 | 合入TROUBLESHOOTING与本文RGB回归；删除原文 |
| DEBUG_CHECKPOINT_B.md | 已解决PC前缀/Jim/FTDI，日志证据有效 | 合入TROUBLESHOOTING；正确步骤入BUILD；删除原文 |
| CHECKPOINT_B_SAPPHIRE.md | 逐页生成记录；阶段源数过时，配置来源有效 | 当前配置/隐藏字段/来源入ARCHITECTURE，Debug入BUILD/TROUBLESHOOTING；正式IP/BSP来源保留；删除原文 |
| CHECKPOINT_C_OWNERSHIP.md | 临时单槽规则已被双缓冲替代；初始化屏障仍有效 | 屏障入ARCHITECTURE/INTERFACES，旧单槽/settle语义入本文；删除原文 |
| CHECKPOINT_D_OWNERSHIP.md | 双缓冲/guard/CDC协议有效，与长期文档重复 | 完整安全交换/迟到R/flush/reset入ARCHITECTURE/INTERFACES；删除原文 |
| CHECKPOINT_D_CONTINUITY_FIX.md | 故障链、修复/参数/吞吐有效 | 故障入TROUBLESHOOTING，正式策略入ARCHITECTURE，性能/证据入本文；删除原文 |
| BUILD_CHECKPOINT_D.md | 重复BUILD，旧软件字段/场景已过时 | 当前步骤入BUILD，LED/排障入TROUBLESHOOTING；删除原文 |
| VALIDATION_CHECKPOINT_C.md | 历史全尺寸初始化/错误排空等独有证据 | 汇总至本文C覆盖、历史兼容和来源；删除原文 |
| VALIDATION_CHECKPOINT_D_INITIAL.md | 初版缩放仿真，随后板上失败；不能保留旧待验收为现状 | 测试范围/注入限制及前后区别入本文，故障入TROUBLESHOOTING；删除原文 |
| VALIDATION_CHECKPOINT_D_CONTINUITY.md | 最终完整压力、warning、边界和Temp来源 | 全尺寸矩阵/33与60条提示/迟到R激励调整入本文；删除原文 |

最终新人入口是README和八份长期Markdown。新建TROUBLESHOOTING.md、ROADMAP.md；没有因文件名带Checkpoint就跳过独有信息。

## Historical Documentation Maintenance Verification

上轮为纯文档整理：README170行，17份旧Markdown收敛为8份长期Markdown（新增2份、整合后删除11份）；当时暂保留辅助快照和摘要，本轮按当前依赖关系一并清理。

只读检查确认47个CSR offset与RTL/软件头文件一致、50个相对链接和锚点有效、UTF-8和代码围栏有效；该轮2338项硬件/生成/成功Debug基线hash通过，未改RTL/软件/IP/工程配置。全仓非文档分组内容比较中，仅embedded_sw/soc_control的IDE运行时缓存/锁发生会话变化；其全部433个非.metadata文件均受基线覆盖且hash一致。该轮未写这些缓存，也未执行Build、仿真、FPGA Compile、Programmer或Git提交操作。

## Auxiliary Verification Cleanup

本轮全仓引用扫描确认：七份开发阶段JSON仅由固定Checkpoint指纹校验链读取，两份TXT只提供历史摘要；Efinity/IP工程、RTL/testbench、RISC-V软件构建均不读取它们。因此删除七份JSON、两份TXT和五个阶段快照脚本，不把它们继续作为后续开发门禁。

保留check_project.py中的当前工程/源文件/活动链路检查，迁入原有的RTL/header/REGISTER_MAP一致性检查，移除Demo对照/固定哈希依赖。RGB runner仍执行它。统一回归入口改为调用当前检查；同时按D runner现有CLI直接调用，移除其原先不支持的工具参数传递。

保留所有sim/testbench、RGB/APB/C/D/DDR压力/软件模型runner、仿真准备、软件构建/IDE准备及实际GDB/Jim和综合JTAG连接检查。它们的测试激励与断言没有因清理而删除或放宽。本轮不修改RTL、软件、IP、工程/物理配置。

本轮清理后复验通过：当前51项工程源/47项CSR一致性；实际GDB/Jim配置解析；APB WAIT0/1/3各113access；RGB quick回归与正式top端口elaboration；D准入/manager/完整518400beat guard及WAIT1端到端5次swap、29帧/981792受检pixels。PowerShell统一入口语法及所有子脚本路径有效。继承的Icarus constant-select、timing/audio端口定宽提示未改动，不据此宣称新增硬件验收。

清理前后2458个不在本次修改白名单内的文件内容/集合分组hash一致，覆盖RTL、软件/ELF、所有sim/testbench、IP/BSP、工程/物理配置和保留的独立runner；只调整当前工程检查及统一入口两个辅助脚本。仿真产物在系统Temp，不重新Build软件或下载FPGA。文档相对链接/锚点和全仓删除目标引用检查通过。
