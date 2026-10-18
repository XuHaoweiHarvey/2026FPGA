# 正式系统 BLIT 接线

2026-10-18：将已完成的B执行层和C侧模块接入正式工程，补齐CPU发命令所需的最小控制/软件路径。对应赛题二的Block Copy基础功能；Line、Alpha Blend和图片资源加载不在本轮范围。

## 数据路径与软件兼容

`accel_regs → sapphire_control → top → rgb_framebuffer → graphics_engine`接收同一组命令。APB成功START快照op/五矩形字段/源地址/stride；manager最终accept时锁存Back，源检查器同拍锁结果，engine下一拍读取。CPU reset及之后修改参数不改变正在执行的DMA。

Display Reader和BLIT经`ddr_read_arbiter`共享DDR AR/R。全局最多一笔读burst，显示最多128拍、BLIT最多32拍；返回数据只交给原owner。真实显示FIFO水位决定显示优先级。显示guard、outstanding、读等待统计和写准入quota只计算显示端AR/R，BLIT读不能赚写额度。

FILL/BLIT写统一经过原Back偏移及写准入，只加一次锁存command_base。写准入保持到B，W/B不额外门控；最后B前保持BUSY和Back。普通显示flush不会清除BLIT缓存或仲裁owner。

正式顶层开启`BLIT_ENABLE=1`；参数默认0以保留旧A/B/C/D回归。新增模块均加入`ti60f225_oob.xml`。DDR PHY、时钟约束、Sapphire生成文件、厂商FIFO/reader和HDMI编码器未修改。

| 项目 | v4源码合同 |
|---|---|
| VERSION / CAPABILITIES | 0x00040000 / 0x7B |
| 新RW寄存器 | BC COMMAND_OP、C0 SRC_ADDR、C4 SRC_STRIDE；复位0，START快照 |
| 操作 | op0 FILL；op1 BLIT；其他接受计数后报0x26 |
| BLIT源 | 当前Front有效图像，绝对地址，16byte对齐，stride7680，不能横跨源行或读槽尾padding |
| BLIT目标 | x/width为4像素倍数，矩形非零且在画面内；AW相对Back |
| FILL | 原任意像素x/width及边缘WSTRB能力保留，API每次显式op0 |
| 新API | accel_blit(src_addr,src_stride,x,y,width,height) |
| 返回0 | 仅COMMAND_COUNT确认接收，仍须accel_wait_done，再显式swap/wait |
| 共享读FAULT | READER_ERROR=0x2004，阻止新START/REQUEST及换帧提交；在途事务保留，统一平台复位恢复 |

旧v3 ELF的精确版本检查会失败；必须重新Build。默认`DEMO_MODE=0`继续运行原FILL场景；编译时设`DEMO_MODE=2`可运行下方验收用BLIT演示，保持FILL兼容回归不变。完整寄存器和错误码见[REGISTER_MAP](REGISTER_MAP.md)。

## 软件 BLIT 演示

设置`software/apb_reg_test/demo_config.h`中的`DEMO_MODE`为2并Build，或从仓库根目录生成独立ELF：

```powershell
python scripts/build_apb_software.py --define DEMO_MODE=2 --output output/graphics/blit-demo
```

每轮先FILL清空Back，在`(0,0)`绘制红/绿/蓝/黄四块16×16像素，再换帧将图块置为Front。软件清空新的Back，以Front绝对基址和7680字节stride提交32×32 BLIT，目标为`(64,64)`；命令完成后显式换帧。屏幕在源图和复制图间交替。调试器可检查`g_apb_test_result.blit_commands_issued/completed`、`source_swaps_completed`、`blit_source_base`与目标参数；正常时每轮增加一次成功BLIT和两次swap，错误及显示欠载/漏帧增量保持0。

每轮共6条FILL、1条BLIT和2次swap；两次swap后Front/Back恢复该轮开始时的物理槽角色。首次在main设置`g_frame_limit=2`，预期完成14条命令、2条BLIT、4次swap，`pass=1`且`errors=0`。`g_hold_frames`只保持最终复制画面。RTL错误用例覆盖BLIT读/写响应错误，失败时保留源Front，失败的Back不会换上屏幕。

## 自己运行系统仿真

在仓库根目录执行，python可替换为本机解释器完整路径：

```powershell
python scripts/run_d_checks.py --graphics --apb-waits 0 1 3
python scripts/run_d_checks.py --apb-waits 1
python scripts/run_rgb_checks.py --quick
```

第一条使用真实APB寄存器、TPG初始化、B执行层、源检查器、仲裁器、显示reader/FIFO、写准入、manager、CVO和RGB串行器，DDR由双槽内存模型提供；不执行Sapphire CPU指令或加密DDR/HDMI IP。缩小画面512×64、stride2048、FIFO256，时钟保持core100MHz/双像素74.25MHz/像素148.5MHz。

流程：保留旧FILL/busy/pending/reset用例；拒绝Back源和非法opcode；FILL构建32×32四色源并换帧；清空新Back；显示扫描同时BLIT到(64,16)；启动后改APB参数、CPU reset、延迟最后B并排队swap；确认旧Front保持、最后B后才换帧；逐像素检查源/拷贝画面。随后保留最后R跨边界恢复测试，末尾注入共享无owner R，检查0x2004及CPU reset不清除故障。

测试对正常拷贝阶段要求underflow/missed的baseline增量为0；刻意延迟最后R的独立场景允许missed增长。模块测试与缩小画面通过不能推导完整1080p带宽或固定最坏等待。

## 本轮验证记录

| 验证 | 2026-10-18本机结果 |
|---|---|
| 正式共享读系统，APB WAIT0/1/3 | 各4次swap、27个完整受检帧及部分帧，共916257次像素比较；正常拷贝underflow/missed增量0；参数改写、CPU reset、最后B、最后R及0x2004保护通过 |
| 并发覆盖 | 每组拷贝期间显示接受74笔AR，其中包含最后B等待期；显示active期间BLIT接受10笔AR；两方同时提出AR的竞争场景已覆盖。这些是覆盖计数，不是带宽指标 |
| 故意接错线的负对照 | 显示reader误接公共RVALID、写准入额度误计BLIT R两种临时错误均被对应检查拒绝；不修改正式RTL |
| APB独立测试 | 旧B合同WAIT0/1/3各113access；新增v4合同各39access，检查8字段快照、RW、拒绝和CPU reset |
| 旧D / RGB | 旧D WAIT1：5次swap、29完整帧/981792像素比较；RGB回归和当前v4顶层端口展开通过 |
| 原独立图形/源检查/仲裁测试 | 统一入口回归通过，含852个源矩形、124个执行/合同/双槽场景、27个仲裁场景与200笔随机读、原5项负对照 |
| 工程一致性 | 55个现存且唯一源文件；RTL/头文件/寄存器表50个offset一致 |
| 软件构建 | 本机没有默认路径的Efinix IDE工具链，使用已安装Xilinx GNU RISC-V GCC13.3.0、正式Sapphire BSP和RV32IM配置构建RAM ELF，LOAD/关键符号位于64KiB OCRAM；另以保留全部inline函数方式编译，确认BLIT API也生成目标代码 |
| BLIT演示软件（错误处理修正前） | 默认FILL和DEMO_MODE=2均构建通过；Unicorn 2.1.4执行真实RV32 ELF，旧FILL连续1000轮/4000命令/1000次swap，BLIT两轮14命令/2次BLIT/4次swap；编译默认模式、60周期保持、计数回绕和另一初始Front通过 |
| 软件错误边界复验 | 补充BLIT错误注入时，成功完成计数断言失败；已增加DONE后的ERROR_CODE复查，并保留读/写错误回归和实际计数输出。最终修正版尚待重新构建及完整软件回归，不能以此前正常流程结果代替复验 |

软件产物位于忽略目录`output/graphics/software/`，未提交。使用替代GNU工具链的命令：

```powershell
python scripts/build_apb_software.py --toolchain-prefix 'D:/Xilinx/2025.1/gnu/riscv/nt/riscv64-unknown-elf/bin/riscv64-unknown-elf-' --output output/graphics/software
```

默认构建仍指向团队Efinix IDE。替代编译和CPU/MMIO行为模型不等于IDE/JTAG、真实DDR或HDMI运行通过。旧E实板记录属于旧FILL基线。Icarus仍有原FIFO constant-select提示、既有timescale及顶层常量位宽警告；新接线未新增端口不匹配。GNU链接器的RAM RWX段提示沿用当前BSP linker布局。

软件行为检查使用Unicorn 2.1.4；先构建当前默认模式ELF，再运行：

```powershell
python -m pip install --target "$env:TEMP/fpga-e-test-deps" unicorn==2.1.4
python scripts/run_e_software_checks.py --unicorn-path "$env:TEMP/fpga-e-test-deps"
```

检查器保留默认IDE工具链，也支持`--toolchain-prefix`指定上面的替代前缀，并用`--elf output/graphics/software/apb_reg_test.elf`选取刚构建的默认模式ELF；参数变化和BLIT用例会自动另建临时ELF。

## 板卡上的下一步

1. 使用A已验证的Efinity 2026.1环境重新综合、布局布线，检查新增源范围常量除法/仲裁的资源与100MHz时序。
2. 使用正式BSP重新构建v4软件，读取VERSION/CAPABILITIES核对硬件与ELF匹配。
3. 使用`DEMO_MODE=2`软件运行上述源图构建、BLIT、完成等待和swap流程。
4. 核对旧源显示稳定、拷贝像素正确，记录underflow/missed增量、命令/交换计数、读写等待峰值和连续运行时长。

本轮的源码接线和仿真不更新旧A～E板级记录。尚无v4 Efinity资源/时序报告，也没有真实DDR/1080p HDMI并发或BLIT实板验收。
