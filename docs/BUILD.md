# Build and Debug

当前Phase 2基线已由负责人完成A～E实板验收。本指南供团队从仓库复现：Efinity Compile → Programmer → RISC-V IDE Build → Hard JTAG Debug → HDMI Demo。正常流程无需重新Generate IP，也不依赖UART。

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

## 1. Efinity Compile

1. Efinity2026.1 → File → Open Project → 根`ti60f225_oob.xml`。确认top仍ti60f225_oob_top，51个design entries及单独soc_control IP。
2. 当前生成文件齐全，**无需Generate Sapphire或修改Interface Designer**。如工具确切提示interface output缺失，才打开根peri、保持参数原值Generate Interface Output Files；不要导入另一Demo整板配置。
3. 从Synthesis开始运行完整flow，经Place and Route、Timing至Bitstream。保存资源和时序报告；不拿仿真stub代替真实IP。
4. 核对100MHz、74.25MHz、148.5MHz相关路径与CDC；missing/duplicate module、黑盒、license、RAM init、latch、多驱动、地址截断、资源/时序失败必须定位。旧常量位宽提示单独核对，不加全局false path掩盖问题。

当前bitstream应由本次源和工具产生；仅改文档不要求重编FPGA。需要修改SoC/IP时，先按[共享变更规则](TEAM_SPLIT.md#shared-interface-change-policy)协调，再由硬件负责人操作GUI并重新核对BSP/地址/公共端口。

## 2. Programmer

Tools → Open Programmer → 使用已验证USB Target，下载本次Compile生成的`outflow/ti60f225_oob.bit`，确认来源/时间。本流程不默认烧录SPI Flash。

复位后等待DDR/video初始化：CPU程序尚未启动时，HDMI应稳定显示红、绿、蓝、白四条竖条。TPG只初始化Front0一帧，完成排空后退出；Back1需软件完整重建。

VERSION=00030000不能区分修复前/后D bit，另核对SERVICE_STATUS bit5=1、SERVICE_READ_QUOTA=128、SERVICE_WATERMARKS=02000180，确保有正式写准入保护。

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

在main确认`g_demo_mode=0`、`g_frame_limit=0`、`g_hold_frames=60`、`g_validation_target=1000`。取消scene_begin/back_ready/frame_presented断点后Resume；可保留仅失败或显式有限停止进入的apb_test_done断点。

启动先检查初始化/ID/配置/SCRATCH，等待旧BUSY/owned/pending结束及3个显示周期，再建立固定baseline。每轮全屏FILL、三个矩形逐条wait_done、一次显式swap/wait，再保持约60个边界周期。

| 场景 | 背景及矩形(x,y,w,h,color) |
|---|---|
| A | 背景00102060；参数矩形默认240,180,360,240,00FF0000；绿760,240,300,300,0000FF00；蓝1260,590,450,280,000000FF |
| B | 背景001C140C；黄140,630,470,170,00FFFF00；青960,130,220,410,0000FFFF；品红1300,500,370,330,00FF00FF |

默认每场景4命令/1swap。g_frame_limit=0无限，非0为显示场景数；target1000只是里程碑，达到后继续运行。CPU暂停不暂停视频/DMA，Debug重跑不清平台owner/计数。不能用暂停CPU或增hold代替连续显示验收。

### Five-parameter Test

只修改`software/apb_reg_test/demo_config.h`的TEST_RECT_X/Y/W/H/COLOR，Build新ELF并Debug；main处设`g_demo_mode=1`，两场景都变为黑底单参数矩形。比如321/123/137/89/00123456应对应移动/缩放/颜色变化，无需重编FPGA。

可在main编辑g_test_rectangle；每轮在scene_begin hook之前快照，所以在该hook修改应按下一轮生效理解。尺寸非零、矩形不越界，默认多矩形模式要注意遮挡。这里是后续复验操作，本次文档整理未改五参数或任何软件。

## 7. Variables / Breakpoints

展开`g_apb_test_result`及其`diagnostics`：

| 观察 | 正常解释 |
|---|---|
| id/version | 4143434C / 00030000 |
| pass/errors/running | 两次成功swap后pass1，errors0；无限模式running1，出错pass回0 |
| iterations/target_reached | 持续增加，>=1000后里程碑1，继续循环 |
| commands_issued/completed | 每正常场景各+4，back_ready时相等；绘制中可差1 |
| swaps_requested/completed | 每场景+1，pending时可差1 |
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
