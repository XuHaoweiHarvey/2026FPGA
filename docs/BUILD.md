# Build and Debug

Phase 3 M1a 已在独立工作树完成 Sapphire External Memory AXI Generate、RTL/软件检查和 Efinity 2026.1.132 完整编译；项目负责人于 2026-10-21 确认实板验收通过。当前 bit/ELF 哈希、验收边界及复验步骤见 [M1A_CPU_DDR](M1A_CPU_DDR.md)。下文保留的 55 个 design entries 和 v5 bit/ELF 操作属于历史基线；M1a 正式工程应为 56 项，不得混用产物。

原FILL基线已由负责人完成A～E实板验收；当前v5 BLIT/色键在2026-10-19修复长路径后已通过Efinity完整编译及当前约束下静态时序，接口告警和实板仍待验收，见[V5_TIMING_FIX](V5_TIMING_FIX.md)。本指南供团队从仓库复现：Efinity Compile → Programmer → RISC-V IDE Build → Hard JTAG Debug → HDMI Demo。正常流程无需重新Generate IP，也不依赖UART。

## Environment and Inputs

| 项目 | 已验证配置 / 位置 |
|---|---|
| FPGA / tools | Ti60F225；Efinity2026.1、Efinix RISC-V IDE2026.1；工程记录2026.1.132 |
| 根项目 / top | ti60f225_oob.xml / ti60f225_oob_top |
| 物理配置 | ti60f225_oob.peri.xml、package_settings.xml、ti60f225_oob.sdc，保持基线 |
| Sapphire | ip/soc_control，生成版本3.4.0；不导入devkit整板example覆盖根工程 |
| IDE应用 | software/apb_reg_test，项目与launch名称保留，不使用checkpoint_b/c/d归档软件 |
| 正式BSP | embedded_sw/soc_control/bsp/efinix/EfxSapphireSoc |
| 正式启动文件 | embedded_sw/soc_control/software/standalone/common/start.S |
| RAM应用 | build/apb_reg_test.elf；OCRAM F9000000/64KiB，末1KiB留给OpenOCD |

以下用已验证工作目录`D:/Github_repositories/2026FPGA`举例。若克隆到不同路径，在IDE中核对launch的绝对bsp_loc、两个-f、target register/SVD路径；不能假定旧绝对路径会自动重定位。普通软件参数变化只需Build/Debug；改变硬件RTL后才需重新Compile/下载。

## M1a 从 Git 检出复现与本地 IDE 路径

M1a 的根项目 `ti60f225_oob.xml` 使用相对设计文件路径，包含 `rtl/framebuffer/cpu_ddr_bridge.v`，总计 56 个 design entries，并以相对路径注册 `ip/soc_control/settings.json`。Sapphire 配置、生成 RTL/netlist、ROM 初始化文件、IP 元数据、正式 BSP `soc.h` 和 OCRAM linker 均随 Git 源码检出；正常打开工程不需要重新 Generate Sapphire。若工具要求重新生成，先在独立验证目录比较生成结果，不覆盖已验收的 P3 文件。

在目标检出目录的根目录运行 `python scripts/check_project.py`、`python scripts/run_m1a_checks.py`、`python scripts/run_d_checks.py --apb-waits 1 --cpu-ddr` 和 `python scripts/run_d_checks.py --apb-waits 1 --graphics --color-key`。软件用 `python scripts/build_apb_software.py --program m1a --opt O2 --output software/m1a_ddr_smoke/build` 重新生成；脚本从自身位置解析仓库根目录，可通过 `--ide-root` 或 `--toolchain-prefix` 指向本机工具链，检查程序的 LOAD 段仍在 `0xF9000000` 的 64 KB OCRAM。`outflow/`、`work_pnr/`、`work_syn/` 和软件 `build/` 均为本地输出，不从 P3 拷贝旧 bit/ELF 当作目标检出的验证结果。

`software/apb_reg_test/.project`、`.cproject`、`apb_reg_test_ti.launch` 和 `openocd/sapphire.cfg` 含本机绝对路径。P3 工作树中的这些修改服务于当前已验证的 IDE 会话，**不纳入 M1a 通用提交，也不要直接复制到另一检出目录**。在 RISC-V IDE 中从 `<目标检出目录>/software/apb_reg_test` 导入项目，不勾选 Copy projects into workspace；将 linked `common`、`bsp`、C/C++ include 路径、`bsp_loc`、两个 OpenOCD `-f`、寄存器描述和 SVD 全部重新指向目标检出目录。复制 Titanium Hard JTAG launch 为本机 M1a 配置，将 image、symbols 和 Main/Application 设为新生成的 `software/m1a_ddr_smoke/build/m1a_ddr_smoke.elf`，Startup PC 设为 `f9000000`，禁用自动重建旧 `apb_reg_test`。IDE 本地配置应保留在本机，提交前检查其中没有 P3 专属路径。原目录另有一个未跟踪的 M1a launch，它当前也指向 P3，不能直接用于原目录复验。

完成目标目录 Efinity Compile 后，只下载该目录新生成的 `outflow/ti60f225_oob.bit`，记录时间与 SHA256；再加载同次构建的 ELF，按 [M1a 板级复验步骤](M1A_CPU_DDR.md#已由负责人确认通过的板级验收与复验步骤)检查结果。当前 P3 验收不能替代合并后或干净检出的重建复验。

## 1. Efinity Compile

1. Efinity2026.1 → File → Open Project → 根`ti60f225_oob.xml`。确认top仍ti60f225_oob_top，55个design entries及单独soc_control IP。
2. 当前生成文件齐全，**无需Generate Sapphire或修改Interface Designer**。如工具确切提示interface output缺失，才打开根peri、保持参数原值Generate Interface Output Files；不要导入另一Demo整板配置。
3. 从Synthesis开始运行完整flow，经Place and Route、Timing至Bitstream。保存资源和时序报告；不拿仿真stub代替真实IP。
4. 核对100MHz、74.25MHz、148.5MHz相关路径与CDC；missing/duplicate module、黑盒、license、RAM init、latch、多驱动、地址截断、资源/时序失败必须定位。旧常量位宽提示单独核对，不加全局false path掩盖问题。

当前bitstream应由本次源和工具产生；仅改文档不要求重编FPGA。需要修改SoC/IP时，先按[共享变更规则](TEAM_SPLIT.md#shared-interface-change-policy)协调，再由硬件负责人操作GUI并重新核对BSP/地址/公共端口。

## 2. Programmer

Tools → Open Programmer → 使用已验证USB Target，下载本次Compile生成的`outflow/ti60f225_oob.bit`，确认来源/时间。本流程不默认烧录SPI Flash。

复位后等待DDR/video初始化：CPU程序尚未启动时，HDMI应稳定显示红、绿、蓝、白四条竖条。TPG只初始化Front0一帧，完成排空后退出；Back1需软件完整重建。当前v5硬件应读回VERSION=`0x00050000`、CAPABILITIES=`0x000000FB`；A～E旧板级记录使用的是BLIT前硬件，不代表v5已上板通过。

历史VERSION=00030000不能区分修复前/后D bit。当前v5仍须核对SERVICE_STATUS bit5=1、SERVICE_READ_QUOTA=128、SERVICE_WATERMARKS=02000180，确保有正式写准入保护。新软件严格要求v5/FB；旧v3/v4 bit或ELF须配套更新。

## 3. Workspace / BSP / Import

沿用成功IDE workspace即可；历史成功workspace位于`embedded_sw/soc_control/bsp`。已有apb_reg_test项目按F5刷新。首次导入：

```text
File → Import → General → Existing Projects into Workspace
Root directory: <repository>/software/apb_reg_test
不要勾选 Copy projects into workspace
```

BSP使用正式soc_control目录；soc.h中APB宏F8100000/10000、RAM宏F9000000/10000与linker/default.ld必须一致。该SoC为控制专用，不能使用Demo08的DDR linker或旧BSP。

## 4. Build Software

Project → Build Project；项目external make调用Python脚本。也可在仓库根目录执行：

```powershell
python scripts/build_apb_software.py
```

输出`software/apb_reg_test/build/apb_reg_test.elf`及bin/hex/map/disasm。使用rv32im、-Og/-g3、Wall/Wextra/Werror，无libc/UART依赖。脚本检查全部LOAD和stack位于OCRAM且低于F900FC00；GNU ld统一RAM的LOAD RWX提示为继承提示，不据此修改生成linker。

若IDE找不到python，将make参数PYTHON设为本机有效解释器。后续重建符号地址会变化，Debug使用新ELF符号，不复用旧结果结构地址或偏移。

## 5. Hard JTAG Debug

先关闭Programmer及旧OpenOCD/GDB，释放FTDI。Run → Debug Configurations → GDB OpenOCD Debugging → **apb_reg_test_ti**：

| 页面 | 正确配置 |
|---|---|
| Main | Project=apb_reg_test；Application=build/apb_reg_test.elf |
| Debugger | 现有Titanium Hard JTAG OpenOCD配置；不要切Soft TAP或加EDB |
| Startup | Load image/symbols；Stop at main；Set PC hex=`f9000000`，**不加0x** |

实际Config options组织保持成功gpioDemo_ti方式：

```text
-c 'set bsp_loc {D:/Github_repositories/2026FPGA/embedded_sw/soc_control}'
-f 'D:/Github_repositories/2026FPGA/software/apb_reg_test/openocd/ftdi_ti.cfg'
-f 'D:/Github_repositories/2026FPGA/software/apb_reg_test/openocd/debug_ti.cfg'
```

FTDI=`Quad RS232-HS`，VID:PID=0403:6011，channel1；800kHz，readWaitCycles40，jtagMapping 8 8 0 1 2 2，正式cpu0.yaml。工作区F900FC00/1024bytes。`debug_ti.cfg`直接使用bsp_loc，不依赖本版Jim不支持的`info script`。

PC前缀重复、FTDI配置来源和GDB连接后退出的已验证故障见[TROUBLESHOOTING](TROUBLESHOOTING.md)。TDO当前只有Sapphire一个驱动，不加历史TDI透传。

## 6. Run Demo

原FILL演示使用`g_demo_mode=0`、`g_frame_limit=0`、`g_hold_frames=60`、`g_validation_target=1000`。取消scene_begin/back_ready/frame_presented断点后Resume；可保留仅失败或显式有限停止进入的apb_test_done断点。

启动先检查初始化/ID/配置/SCRATCH，等待旧BUSY/owned/pending结束及3个显示周期，再建立固定baseline。每轮全屏FILL、三个矩形逐条wait_done、一次显式swap/wait，再保持约60个边界周期。

| 场景 | 背景及矩形(x,y,w,h,color) |
|---|---|
| A | 背景00102060；参数矩形默认240,180,360,240,00FF0000；绿760,240,300,300,0000FF00；蓝1260,590,450,280,000000FF |
| B | 背景001C140C；黄140,630,470,170,00FFFF00；青960,130,220,410,0000FFFF；品红1300,500,370,330,00FF00FF |

默认每场景4命令/1swap。g_frame_limit=0无限，非0为显示场景数；target1000只是里程碑，达到后继续运行。CPU暂停不暂停视频/DMA，Debug重跑不清平台owner/计数。不能用暂停CPU或增hold代替连续显示验收。

### BLIT Copy Demo

将`software/apb_reg_test/demo_config.h`中的`DEMO_MODE`设为`2`后Build，并下载匹配的当前v5 FPGA配置和新ELF。也可以从仓库根目录用`python scripts/build_apb_software.py --define DEMO_MODE=2 --output output/graphics/blit-demo`生成独立ELF，再让IDE使用该ELF。旧v4行为检查保留在[SYSTEM_BLIT](SYSTEM_BLIT.md)，本轮v5的CPU指令检查受依赖权限限制未执行。

模式2每轮先清Back并在左上角画红、绿、蓝、黄四个16×16色块，换帧显示源图；再清新的Back，用`src=当前Front`、stride=7680执行32×32 BLIT到`(64,64)`，最后换帧显示复制结果。无限运行时会在源图/复制图之间交替。保留`g_demo_mode=2`，可查看`blit_commands_issued/completed`、`source_swaps_completed`、`blit_source_base`及`blit_target_*`；成功时BLIT计数持续一致增长，error/underflow/missed增量应为0。此前v4软件行为检查通过；当前v5静态时序通过，CPU指令和实板仍未验收。

首次联调可在main断点设置`g_frame_limit=2`，两轮后在`apb_test_done`停止：`iterations=2`、`commands_issued=commands_completed=14`、`blit_commands_issued=blit_commands_completed=2`、`swaps_requested=swaps_completed=4`、`source_swaps_completed=2`、`pass=1`、`errors=0`。模式2的iteration/frame_limit统计一次完整复制流程，包含源图和复制图两次换帧；`g_hold_frames`保持最终复制画面。

### Color Keying Compare Demo

将DEMO_MODE设为3，或执行`python scripts/build_apb_software.py --define DEMO_MODE=3 --output output/graphics/color-key-demo-v5`，IDE使用对应的新ELF。9条FILL先生成128×128紫底机器人，第一次swap将它设为Front；随后画深蓝/绿色Back背景，普通复制到(384,384)，以0xFF00FF为key的透明复制到(1152,384)，第二次swap呈现左右对比。透明复制保留Back已有背景，不解释源X为Alpha。

两轮有限运行预期26条完成命令、普通BLIT和色键各2条、4次swap；新增`color_key_commands_issued/completed`应一致，`color_key_rgb=0xFF00FF`。这是板级预期，尚未在板卡或本轮CPU指令模型中验收。当前软件已用正式BSP和替代GNU工具链编译通过；共享DDR显示系统的缩小场景RTL检查通过。详细约束与复现见[COLOR_KEY](COLOR_KEY.md)。

### Fixed-workload Benchmark

`DEMO_MODE=4` 在当前v5 bit上运行有限测速，只需Build/下载新ELF。四种尺寸各测FILL/BLIT/色键，默认预热1次、计时8次；准备背景和swap从绘制耗时中分开。命令行：

```powershell
python scripts/build_apb_software.py --define DEMO_MODE=4 --output output/graphics/benchmark_v5
```

取消计时过程的断点，在`apb_test_done`停止后展开`g_benchmark_result.cases`。默认预期12组完成、96条被计时命令、总计252条完成命令和24次swap，pass=1、error_code=0、underflow/missed增量0。模式4不使用g_hold_frames/g_frame_limit或模式2/3专用计数。结果是轮询API的端到端时间，板级数据待采集；完整操作、字段与软件检查见[BENCHMARK](BENCHMARK.md)。

### Five-parameter Test

只修改`software/apb_reg_test/demo_config.h`的TEST_RECT_X/Y/W/H/COLOR，Build新ELF并Debug；`g_demo_mode=1`时两场景都变为黑底单参数矩形。比如321/123/137/89/00123456应对应移动/缩放/颜色变化，无需重编FPGA。

可在main编辑g_test_rectangle；每轮在scene_begin hook之前快照，所以在该hook修改应按下一轮生效理解。尺寸非零、矩形不越界，默认多矩形模式要注意遮挡。

## 7. Variables / Breakpoints

展开`g_apb_test_result`及其`diagnostics`：

| 观察 | 正常解释 |
|---|---|
| id/version | 当前v5为4143434C / 00050000 |
| pass/errors/running | 两轮完整演示后pass1，errors0；无限模式running1，出错pass回0 |
| iterations/target_reached | 持续增加，>=1000后里程碑1，继续循环 |
| commands_issued/completed | 模式0每轮+4，模式1每轮+2，模式2每轮+7，模式3每轮+13；back_ready时相等，绘制中可差1 |
| swaps_requested/completed | 模式0/1每轮+1，模式2/3每轮+2；pending时可差1 |
| command_delta/swap_delta | 原始硬件计数减启动baseline；与本次成功API统计对照 |
| underflow/missed baseline、value、delta | 启动历史可非0；稳定期两项delta保持0 |
| errors/timeouts/rejected_*、diagnostics.error_code/reader_error | 正常均0；故障保留failure_phase/failure_code |
| writer_throttle_cycles/bursts、reader_frame_completions | 等待/节流可增长，读写均需有进展 |
| AR/R max、writer max、FIFO level | 时延峰值和动态水位，不要求等待为0，结合欠载/进展判断 |
| front_base/back_base/reader_base | 0/00800000角色交换、永不相同；swap提交后reader_base=Front |

phase=1 INIT、2 BUILD、3 RECT、4 BACK_READY、5 SWAP、6 HOLD、7有限正常停止、255失败。错误详情和计数单位见[REGISTER_MAP](REGISTER_MAP.md)。快照不是所有CSR原子读取；100MHz累计周期32位约42.95秒回绕，用uint32差值。

调试所有权时：back_ready停在绘图已完成、尚未REQUEST，应一直显示旧Front；frame_presented停在交换已提交，随后active video出现完整新场景；scene_begin观察绘制前状态。**连续测试时取消这些绘图断点。**

## 8. Revalidation and Failure Handling

建议连续至少10分钟并继续至1000场景，记录1/5/10分钟和里程碑的计数；HDMI须无黑屏、闪烁、明显tearing、半屏或颜色顺序错误，绘制期间旧Front稳定。复验标准和板级记录边界见[VALIDATION](VALIDATION.md)。

软件每次wait默认20,000,000次poll，非精确秒；超时保存STATUS、ERROR_CODE、BUFFER_STATUS及连续性/AR/R诊断并停止提交，不reset/cancel在途事务。MMIO指令本身永久卡住时不能指望同CPU的poll循环恢复。故障先保存结果、bit/ELF来源和完整Compile报告，再按[TROUBLESHOOTING](TROUBLESHOOTING.md)排查。

## Automated Checks

只读契约检查：

```powershell
python scripts/check_project.py
python scripts/check_apb_debug.py
```

仿真/构建命令与依赖集中见[VALIDATION](VALIDATION.md#reproduction)。当前工程检查直接读取活动XML、RTL、软件头文件和寄存器文档，不依赖阶段快照。辅助文件清理不重建软件或FPGA；正式仿真仍由保留的runner执行。
