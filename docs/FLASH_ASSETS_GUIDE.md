# Ti60F225-DK Flash：2D射击游戏图片存储与SPI配置说明

> 实现状态更新（2026-10-24）：本文保留早期只读调查与方案推导。`advanced_demo` 现已增加 SPI0、图片/特效和 A/B 存档实现，实际地址与操作步骤以 [Flash 交付说明](../advanced_demo/docs/FLASH_DELIVERY.md) 为准。下文“SPI 未启用”“待新增”“未运行构建”等描述对应早期调查时点，不能用作当前状态。


更新日期：2026-10-23  
适用板卡：本文资料中的 Ti60F225I3-V4／Ti60F225-DK，板载 GD25LQ64。  
工程检查位置：`D:/desktop/qiansai/2026FPGA`，含 `basic_demo` 与 `advanced_demo`。  
本文主方案：**整颗Flash只保存图片资源，不保存FPGA配置镜像或RISC-V应用镜像。**

本文是技术说明和实施建议。已只读检查工程、板卡手册和相关文档；没有修改SoC、运行构建、连接板卡或执行Flash擦写。除本Markdown外，没有新增实现代码。正文中的“待新增”文件、分区与接口均不是现有功能。

## 1. 结论与适用范围

- 板载Flash容量为64 Mbit，即8 MiB（8,388,608字节）。若全部保存未压缩32位像素，可放6张640×480图片，或512张64×64图片；这些是未预留目录的容量上限。[S1，页6、32；容量换算]
- 当前两个图形工程都未启用SPI0/1/2，活动图形软件未调用Flash接口。图片和Sprite目前由CPU按公式生成到DDR；附带的Flash驱动、示例和Bootloader并未构成活动应用的Flash资源通路。[S3、S4]
- 正常使用板载Flash，不需要在现有Type-C和HDMI以外再接SPI飞线：Flash已由PCB连到FPGA，板载FT4232HL通过Type-C提供供电、下载和UART功能。[S1，页13、14、32、34]
- 图片只存Flash时，每次上电仍需要经JTAG加载FPGA配置，并用IDE下载应用，除非另外引入其他启动存储方案。**图片存储不需要Bootloader；独立上电运行才需要另行解决启动问题。**[S2，页55；S7]

## 2. Flash的功能定义

### 2.1 它是什么

Flash是可电擦除、可重新写入、断电后保存内容的非易失存储器。本板使用外接GD25LQ64。板卡手册指出，它既可保存FPGA程序，也可保存用户数据；这里“FPGA程序”主要指配置镜像，用户数据则可包括图片、字体、游戏参数等。[S1，页6、32]

| 存储器 | 当前工程中的作用 | 断电后 |
|---|---|---|
| Flash | 长期保存图片资源；其他方案也可保存配置与应用 | 内容保留 |
| FPGA配置RAM（CRAM） | 保存当前有效的FPGA电路配置 | 需要重新配置 |
| OCRAM | RISC-V程序、变量、栈及小缓冲 | 需要重新装载或初始化 |
| DDR3 | 素材、Front/Back显存及运行数据 | 需要重新装载或初始化 |

Ti60的CRAM为易失存储器；Flash和DDR的作用不同，不能把“图片已存入Flash”理解为“加速器已经能直接读取并显示”。[S2，页55；S3、S4，内存与素材实现]

### 2.2 外接Flash与封装内置Flash不能混用

Ti60数据手册第45页的16 Mbit封装内置Flash针对F100S3F2。本文F225开发板的GD25LQ64是外接芯片，容量、电路及引脚以本板原理图为准，不套用封装内置Flash资源的连接方法。[S1，页32；S2，页45]

### 2.3 本项目建议的数据路径

```text
电脑PNG资源
  → 离线转换为XRGB/ARGB像素并打包
  → 烧入GD25LQ64
  → RISC-V经SPI分块读取
  → OCRAM小缓冲
  → DDR素材区
  → FPGA执行BLIT／Color Key／Alpha
  → Back显存
  → 安全换帧
  → HDMI
```

这是适配现有工程的建议路径，不是已经实现的功能。当前加速器从DDR取源数据，没有Flash地址空间中的直接取图能力。[S3、S4，图形引擎及源窗口检查]

## 3. 整颗Flash只存图片，可以存多少

### 3.1 按当前32位未压缩像素格式计算

XRGB8888和ARGB8888均为4字节/像素。以下不计压缩、不计目录与对齐：

```text
图片字节数 = 宽 × 高 × 4
数量上限 = floor(8,388,608 / 图片字节数)
```

| 分辨率 | 单张字节数 | 纯像素理论上限 | 预留64 KiB目录后的数量 |
|---|---:|---:|---:|
| 1920×1080 | 8,294,400 | 1张 | 1张 |
| 640×480 | 1,228,800 | 6张 | 6张 |
| 320×240 | 307,200 | 27张 | 27张 |
| 128×128 | 65,536 | 128张 | 127张 |
| 64×64 | 16,384 | 512张 | 508张 |
| 32×32 | 4,096 | 2,048张 | 2,032张 |

容量来自[S1]，格式来自[S3、S4]；表内数量为算术结果。“预留64 KiB”是本文建议，并非强制要求。其他预留区、存档、镜像和对齐会进一步减少可用容量。

### 3.2 射击游戏如何计数

一张角色图不等于一个游戏对象。同一张敌机或子弹贴图可以在一帧中绘制多次，不必在Flash中复制几百份。动画的不同帧、不同外观才增加素材存储。例如一种64×64敌机有8帧动画，占131,072字节；100个敌机对象可以共享这8帧。[工程设计建议；按当前4字节像素格式计算]

图集可以把小图放进一个大资源里。640×480图集在无间隔规则排列时，可容纳15个128×128图块、70个64×64图块或300个32×32图块。实际要计入边距、动画和对齐；图块数量不代表能达到60 FPS的同屏对象数量。[容量与排列计算]

PNG/JPEG按实际文件大小可存更多，但当前工程未接入通用解码器。首轮建议离线转换后存原始像素。若只保存转换后的像素，导出时可以重建PNG，但不能恢复原PNG的压缩字节及全部元数据。[S3、S4，当前实现；工程建议]

### 3.3 只存图片的示例分区

下面按64 KiB元数据区加6张640×480图片规划，末地址均为**不包含的结束地址**：

| 内容 | Flash起始偏移 | 结束偏移 | 长度 |
|---|---:|---:|---:|
| 资源目录、版本、CRC | `0x000000` | `0x010000` | `0x10000` |
| 图片0 | `0x010000` | `0x13C000` | `0x12C000` |
| 图片1 | `0x13C000` | `0x268000` | `0x12C000` |
| 图片2 | `0x268000` | `0x394000` | `0x12C000` |
| 图片3 | `0x394000` | `0x4C0000` | `0x12C000` |
| 图片4 | `0x4C0000` | `0x5EC000` | `0x12C000` |
| 图片5 | `0x5EC000` | `0x718000` | `0x12C000` |
| 剩余空间 | `0x718000` | `0x800000` | `0xE8000` |

**这是新的“图片专用”建议布局。前面对话中将图片放在`0x400000`的方案，是给FPGA与应用镜像留空间的另一方案，不能和本表混用。**

Flash地址0现在保存资源目录，而非有效FPGA镜像。因此上电不能期望从这颗Flash配置FPGA。按现有板级配置模式，上电尝试读取图片数据可能无法完成配置；应使用已验证的JTAG流程加载业务bitstream，不依赖该Flash启动。[S2，页55；工程应用说明]

## 4. 当前已经有的文件，以及实际完成程度

本节路径均相对于`D:/desktop/qiansai/2026FPGA`。两套工程都有厂商生成软件副本；不要把某个参考板目录中的文件误认为当前顶层已使用。

| 文件 | 含义与作用 | 当前检查结果 |
|---|---|---|
| `basic_demo/ip/soc_control/settings.json` | 当前SoC硬件参数 | SPI0/1/2均为`1'b0`；OCRAM为65536字节 |
| `advanced_demo/ip/soc_control/settings.json` | 高级版SoC硬件参数 | SPI0/1/2均关闭；CPU时钟配置100 MHz |
| 两套工程的`rtl/ti60f225_oob_top.v` | SoC、DDR、显示和加速器顶层接线 | 未检出活动Flash SPI接线 |
| 两套工程的`ti60f225_oob.peri.xml` | 当前接口与引脚配置 | 未检出对应活动SPI/Flash信号配置 |
| `embedded_sw/soc_control/software/standalone/driver/spi.h` | SPI控制器寄存器与收发接口 | 有代码，未被图形应用接入 |
| 同目录`spiFlash.h` | Flash初始化、读取、擦除等封装 | 有代码，不等于硬件已启用 |
| `embedded_sw/soc_control/software/standalone/spi/spiDemo/src/main.c` | 厂商独立SPI读写示例 | 会擦写数据，不是只读测试 |
| 上例的`userDef.h` | 示例SPI宏与测试位置 | 例程测试地址为`0x410000`，不能无检查运行 |
| `embedded_sw/soc_control/software/standalone/bootloader/src/bootloaderConfig.h` | 从Flash加载CPU应用的参数 | 源码使用Flash`0x00380000`、RAM`0xF9000000`；不等于当前启动实际使用 |
| `embedded_sw/soc_control/bsp/efinix/EfxSapphireSoc/openocd/flash_ti.cfg` | OpenOCD Flash访问示例配置 | 含参考SPI地址及容量，不能直接套用于本板新配置 |
| `basic_demo/software/m2_demo/assets.h`及`main.c` | 当前基础图片生成与装载 | 用`m2_image_pixel()`生成图片，未从Flash读取 |
| `advanced_demo/software/advanced_demo/main.c` | 高级图片、Sprite与渲染 | 用`asset_pixel()`、`sprite_pixel()`生成素材，未从Flash读取 |
| `ip/soc_control/Ti60F225_devkit/soc.peri.xml` | 厂商Ti60参考工程接口 | 有SPI参考接线，但不是当前V4工程自动生效的配置 |

上述结果来自[S3、S4]的源码与配置检查。Flash芯片当前实际内容、上次烧写方法以及板上运行镜像，不能由文件存在与否判断；本文没有执行板级读回。

## 5. 还需要配置或新增哪些文件

以下以`advanced_demo`为开发对象，因为它已有色键和Alpha图集通路。全部新功能应先在独立副本或开发分支验证，保留原基线。[工程建议]

| 文件/位置 | 需要做什么 | 作用 |
|---|---|---|
| `ip/soc_control/settings.json`对应IP配置 | 在Sapphire配置界面启用SPI0，Generate | 实际生成CPU可访问的SPI控制器；不要只改JSON而不生成 |
| 生成的`ip/soc_control/soc_control.v`和模板 | 由工具重新生成，检查端口 | 提供SPI时钟、片选、数据输入/输出及输出使能 |
| `rtl/ti60f225_oob_top.v` | 连接新SPI端口到接口层 | 接通SoC到板载Flash |
| `ti60f225_oob.peri.xml` | 在Interface Designer中配置信号、引脚、电平 | 保证逻辑信号连接到实际Flash引脚 |
| `ti60f225_oob.xml` | 核对顶层与源文件清单 | 使编译包含正确硬件 |
| 新生成的BSP `include/soc.h` | 核对SPI基址、频率宏 | 软件使用真实硬件地址，不手猜地址 |
| BSP `linker/default.ld` | 保持已验证OCRAM布局，检查新增缓冲占用 | 图片整图不能链接进64 KiB OCRAM |
| **待新增**`software/flash_assets/flash_layout.h` | 定义Flash分区与容量边界 | 与电脑打包工具共享布局约定 |
| **待新增**`flash_storage.c/.h` | 封装SPI初始化、读、可选写、超时与越界保护 | 为游戏提供稳定Flash接口 |
| **待新增**`asset_manifest.h` | 定义资源目录格式 | 记录ID、尺寸、格式、偏移、长度、CRC |
| **待新增**`flash_assets.c/.h` | 目录检查、分块读取、DDR装载和CRC | 完成Flash到DDR通路 |
| **待新增**`scripts/pack_assets.py` | PNG转换与资源包生成 | 输出`assets.bin`和资源清单 |
| **待新增**`scripts/unpack_assets.py` | 将读回的资源包还原为图片 | 导出PNG、检查CRC |
| **待新增**只读`flash_probe`与`flash_dump`程序 | 识别芯片、读回资源 | 分开调试通信和游戏集成 |
| 应用`main.c`、makefile或构建脚本 | 加入新源文件、初始化与错误处理 | 游戏启动时先装载资源再开始绘制 |
| IDE `.launch` | 更新BSP、OpenOCD、image、symbols路径 | 调试当前工程和当前ELF |
| **可选**UART配置及导出程序 | 启用UART、接线、配置串口和传输协议 | 批量把资源传回电脑 |

新文件名是设计建议，不是必须照搬的目录规范。厂商生成IP和BSP应由生成流程更新，不手工拼改生成RTL；应用适配代码放在自己的软件目录。[工程建议]

## 6. SPI硬件、引脚与软件配置

### 6.1 本板Flash连接

以下FPGA封装管脚来自V4板手册J6表，Flash管脚来自同手册原理图。与实物PCB版本一致后才能用于约束；原始参考板文件只作交叉核对。[S1，页32、34]

| 功能 | GD25LQ64脚位 | 板上信号 | FPGA管脚名 | FPGA封装脚 |
|---|---:|---|---|---|
| 片选，低有效 | 1 | SS | GPIOL_P_01_SSL_N | P1 |
| 时钟 | 6 | CCK | GPIOL_N_01_CCK | N1 |
| 单线发送MOSI | 5 | CDI0 | GPIOL_P_03_CDI0 | M1 |
| 单线接收MISO | 2 | CDI1 | GPIOL_N_03_CDI1 | L1 |
| 写保护／多线数据2 | 3 | CDI2 | GPIOL_P_04_CDI2 | H5 |
| 暂停／多线数据3 | 7 | CDI3 | GPIOL_N_04_CDI3 | H4 |

原理图标注Flash电源使用1.8 V。对照J6的Bank 1A电平和实际板卡配置，Interface Designer中相关接口必须匹配硬件电压。首轮用单线SPI，保持WP#/HOLD#非激活，核对已有上拉及未用输出的状态。[S1，页32、34]

原理图C153的0.1 μF是电源去耦；CLK对地的C154标为NC。手册“CLK一般不需要预留电容”不是让用户取消电源去耦，也不要求为SPI软件开发改焊已有板卡。[S1，页32]

### 6.2 Sapphire配置顺序

1. 打开所选工程的Efinity工程文件，确认是`advanced_demo`而非参考设计。
2. 在Sapphire IP中启用SPI0；首轮采用8位收发和1个片选，使用单线读模式。
3. 保持已验证的OCRAM、DDR接口、CPU时钟、Hard JTAG和缓存配置，不为接入Flash顺便重构它们。
4. Generate后比较实际端口和新BSP；通过模板更新顶层，不在旧SoC上凭空声明端口。
5. 在Interface Designer中配置相应GPIO/复用配置引脚及输出使能，避免一个物理脚被重复分配；外接Flash不直接套用封装内置Flash专用块。
6. 编译并检查100 MHz约束、资源、接口和新告警，生成与新软件配套的bitstream。

本步骤是建议实施流程，当前尚未执行。具体GUI字段名称以安装的2026.1和生成的RV32 IP为准，不套用RV64驱动示例。[S3、S4；S5、S7]

### 6.3 SPI初始化与地址

软件使用新BSP生成的`SYSTEM_SPI_0_IO_CTRL`，不能把旧示例中的`0xF8014000`视为本工程SPI0实际地址。当前SPI未启用时，BSP没有可用SPI宏。更不能把Flash偏移当成SPI寄存器地址。[S3、S4]

首轮建议：CPOL=0、CPHA=0；普通单线SPI；低速开始。附带驱动的分频公式是：

```text
SCK = SPI输入时钟 / [2 × (clkDivider + 1)]
```

若输入100 MHz，`clkDivider=19`得到2.5 MHz。若启用了独立外设时钟，要用实际外设时钟计算。单线SPI不等于只有一根信号线：仍有SCLK、CS#、MOSI和MISO。[S3、S4，SPI示例；参数为建议]

建议自己的初始化封装完成：片选空闲、SPI配置、唤醒、JEDEC ID读取、状态检查和错误返回。优先用对应芯片手册确认的普通读指令验证；模式和最高频率应按实际GD25LQ64后缀及走线验证，不直接使用其他芯片的最高值。[S5；工程建议]

### 6.4 暂时不要改动的内容

- 不因图片只存Flash就把应用链接地址改成Flash偏移。
- 不直接运行会擦除的`spiDemo`；它默认测试`0x410000`，可能覆盖图片。
- 不照抄参考OpenOCD Flash bank的容量和SPI基址；先核对实物和新BSP。
- 不假定打开SPI选项就能自动读取PNG；资源加载和解码是另外的软件功能。

这些限制来自现有示例行为、地址空间差异以及当前工程缺少加载器的事实。[S3、S4]

## 7. 除Type-C和HDMI之外，需要接什么线

### 7.1 正常使用板载Flash：不需要新增SPI外接线

本板已经焊有GD25LQ64，并通过PCB连接到FPGA。板载FT4232HL使一根Type-C数据线可承担供电、JTAG下载及UART；HDMI负责画面。因此沿用目前能正常供电和下载的Type-C连接，以及HDMI显示连接即可开展板载Flash开发。关键新增工作在硬件逻辑/约束和软件，而不是飞线。[S1，页13、14、32]

| 用途 | 需要额外接线吗 | 条件 |
|---|---|---|
| 经板载JTAG烧写Flash | 不需要 | Type-C具有数据功能，板载下载器可识别 |
| FPGA运行时SPI读取板载Flash | 不需要 | SoC、顶层与物理接口已正确配置 |
| 通过板载UART导出到电脑 | 通常不需要额外USB转串口模块 | 需启用FPGA UART并接到板载桥；选对FTDI串口通道 |
| JTAG/IDE分块导出 | 不需要 | 需要新增只读dump程序和主机端操作 |
| 独立外部JTAG下载器 | 需要 | 仅作为可选替代方式，不是本方案必需 |
| 外部SPI编程器 | 需要 | 仅特定调试场景，需要1.8 V兼容和控制权隔离 |
| 玩家按键、摇杆或其他输入 | 视输入方案而定 | 属于游戏交互，不是Flash所需线路 |

手册给出的板载UART是FPGA RX=`GPIOL_02/R4`、FPGA TX=`GPIOR_28/R14`。使用时还要核对当前PCB版本、电平、引脚占用和FTDI通道。**Type-C桥具备UART功能，不代表当前SoC已经启用UART。**[S1，页34；S3、S4]

### 7.2 外部编程器不是默认操作

手册另外描述：外接JTAG下载器接J8，需先按手册使板载FTDI处于高阻；外部SPI访问可使用J6的电源参考、SS、CDI0、CDI1、CCK和GND，并按复位与控制权要求操作。这些涉及不同接线方案，不应在使用板载Type-C时顺便短接J8、拉低复位或接入第二个SPI主机。[S1，页13、14、34]

不要给Flash接5 V或普通3.3 V SPI输出；外部工具必须与实际1.8 V接口兼容。本文没有验证任何外接编程器型号。[S1，页32、34；电气使用说明]

## 8. 图片准备与预烧入流程

### 8.1 电脑资源处理

1. 将背景、敌机、子弹、UI和动画帧整理为源PNG。
2. 首轮离线转为硬件支持的像素：背景XRGB8888，Alpha图集ARGB8888。
3. 采用小端逐像素顺序：XRGB写`B G R X`，ARGB写`B G R A`；逐行从上到下排列。
4. 为每项记录资源ID、偏移、宽高、stride、格式、长度和CRC32。
5. 输出`assets.bin`及人可读资源清单；目录中的偏移明确为包内偏移，板端只加一次烧写基址。
6. 验证总长度不超过8 MiB，条目不重叠、不越界；固定目录端序和版本。

这是待新增打包工具的要求。当前加速器不负责PNG解码；压缩资源要另外实现板端解码及内存预算。[S3、S4；工程建议]

### 8.2 烧写图片区

1. 备份需要保留的旧Flash内容；“整颗只存图片”会替换其中原有配置或应用。
2. 使用Programmer可接受的原始镜像/地址格式。若需要从`.bin`转换，使用该版本支持的镜像转换或Generic Image Combination流程；不把应用Intel HEX直接当原始Flash HEX。
3. 本文资源包的Flash起始地址为0；包内图片0偏移为`0x010000`。不要在打包和烧写界面重复加偏移。
4. 通过板载Type-C，在Programmer选择与板卡及Flash匹配的JTAG Bridge烧写流程；擦除、编程、校验。
5. 烧写后桥接配置可能已替换当前用户逻辑。重新经JTAG加载带SPI的业务bitstream，再用IDE下载资源测试ELF。
6. 读取目录、抽样像素和整项CRC；只看到Programmer“完成”不足以证明游戏格式正确。

板卡手册说明默认经USB和JTAG Bridge编程Flash；格式转换与写入地址以实际Programmer版本为准。先在小资源包验证流程，不假定工具对所有纯数据格式都可直接写入。[S1，页14、88～90；S6]

## 9. IDE和RISC-V调试配置

当前IDE可执行文件：`C:/Efinity/efinity-riscv-ide-2026.1/Efinity-RISCV-IDE/efinity-riscv-ide.exe`。本工程构建脚本默认IDE根路径仍为`D:/Efinity/efinity-riscv-ide-2026.1`；使用时传入正确`--ide-root`或在本地构建配置中更新，不用默认路径假定工具已找到。[本机文件检查；S3、S4，构建脚本]

1. 用当前硬件Generate产生的BSP导入应用，不混用旧SoC的`soc.h`和外设地址。
2. 给Flash小测试程序建立独立构建入口；当前构建脚本不自动支持新取的程序名。
3. 使用当前64 KiB OCRAM链接布局；只放目录和行/块缓冲，不把整张640×480图片作为数组链接进去。
4. 检查`.launch`中的BSP、OpenOCD脚本、image、symbols都指向所选工程与新ELF，保持已验证的Hard JTAG模式。
5. 停止占用同一JTAG接口的Programmer操作后再调试。首轮不新增并发调试配置。
6. 在固定断点观察JEDEC ID、状态、偏移、长度、进度、CRC及错误码；通信计时期间不反复单步。
7. 第一项只读验证成功后，再接入DDR和游戏；擦写测试另外建立程序并限制地址范围。

上述为待实施流程，不是报告已完成的调试。应用仍在CPU地址`0xF9000000`运行；Flash偏移不是应用运行地址。[S3、S4；S5]

## 10. 从Flash加载到DDR并显示

### 10.1 三种地址不能混淆

| 含义 | 示例 | 谁使用 |
|---|---|---|
| Flash偏移 | `0x010000` | SPI读指令 |
| DDR物理素材地址 | `0x01000000` | FPGA图形加速器 |
| CPU访问DDR别名 | `0x01001000` | RISC-V load/store，当前为物理地址加`0x1000` |
| SPI外设基址 | 新BSP的`SYSTEM_SPI_0_IO_CTRL` | CPU访问SPI寄存器 |

这是当前CPU DDR桥与图形通路的地址关系。把Flash偏移传给BLIT，或把DDR物理地址直接当CPU别名，都会访问错误位置。[S3、S4]

### 10.2 分块装载流程

```text
读取目录并验证尺寸/格式/范围
  → 申请素材装载状态
  → 申请CPU DDR会话
  → Flash读一行到OCRAM
  → 将字节组装为32位像素写入DDR
  → 重复并计算CRC
  → fence、等待桥排空、释放CPU会话
  → DDR读回校验
  → 封存素材
  → 开始BLIT/色键/Alpha和安全换帧
```

640×480的32位图片可用2560字节的一行缓冲。现有`spiFlash_f2m()`逐字节写内存，首轮推荐先读OCRAM，再按现有已验证32位像素路径写DDR，明确处理小端、stride和错误。会话、排空和封存使用当前工程机制，不绕过保护。[S3、S4]

### 10.3 Flash能存6张，不代表现有硬件能直接用6个DDR入口

基础版开放3张固定640×480素材入口；高级版另开放1张640×480图集。普通素材复制、图集色键/Alpha的操作类型和源窗口各有限制。若要6张同时驻留并任意选择，需要同步扩展CPU桥、源检查器、资源管理、软件及测试；若只选一部分，启动时把所需资源装入现有槽位。[S3、S4，`cpu_ddr_bridge.v`、`blit_source_guard.v`]

当前封存机制并非可随时覆盖的通用缓存：未重新设计安全重载流程前，不能在运行中直接覆写已封存素材。要换关卡，可先选定开机装载子集，后续再实现排空、解封/重载、重新校验和封存状态机。[S4；工程建议]

当前M2校验仍按`m2_image_pixel()`生成公式比较，高级版也按程序公式校验。加载真实图片时要改为资源目录CRC或正确参考数据，否则正确图片也会被误判为错误。[S3、S4]

## 11. 从Flash“导出图片”有哪几种含义

### 11.1 导出到屏幕

按上一节读入DDR，再调用现有加速器绘制和换帧即可。Flash中的原始像素不需要转回PNG才能显示；游戏运行期间反复使用DDR素材，无需每帧从Flash读取。[S3、S4；建议实现]

### 11.2 导出回电脑：方案A，JTAG/IDE分块读取

这是优先推荐的最小改动方案，不额外启用UART：

1. 新增只读`flash_dump`程序，使用OCRAM固定缓冲，例如2560字节。
2. 主机给定Flash偏移、总长度；程序每次读一个块到`g_flash_buf`，记录`offset`、`length`和CRC。
3. 在读取完成后的固定断点暂停CPU，使用IDE/GDB将该缓冲导出为二进制；长度和符号地址从当前ELF取得，不猜地址。
4. 主机按偏移拼接，继续程序处理下一块。正式批量导出应写自动化脚本，避免人工拼接上千块。
5. 比较完整资源CRC，再由`unpack_assets.py`按目录转换回PNG。

这些程序与自动化尚未实现。应从OCRAM缓冲导出，不假定IDE/GDB可以在任意会话状态直接读取受保护DDR窗口。[S3、S4；工程建议]

### 11.3 导出回电脑：方案B，板载UART

1. 在Sapphire中启用UART并重新生成BSP。
2. 将FPGA TX/RX通过正确约束连接到板载FT4232HL的UART路径；通常沿用同一Type-C，无需外接模块。
3. 电脑识别相应COM口，双方统一波特率、8N1等设置。
4. 使用二进制协议：包头、资源ID、偏移、长度、数据、CRC以及重传/应答。
5. 主机保存`.bin`并校验、重建图片。不要将二进制负载与调试printf混在同一未分帧数据流中。

UART当前未在活动SoC中启用。手册说明桥有UART功能，但仍需配置SoC、引脚和软件；本节为新增方案。[S1，页13、34；S3、S4]

### 11.4 其他读回工具

Efinix有JTAG SPI Flash Loader，支持指定地址和长度的读、写、校验等功能；它可以作为独立导出途径。是否已安装、是否支持本板GD25LQ64及当前桥接流程，需先实际确认。本文不假定当前Programmer界面已有可直接导出PNG的按钮。[S8]

### 11.5 二进制怎样转回图片

导出时必须同时保留宽、高、stride、像素格式、方向和端序。XRGB的每像素字节按B/G/R/X解读，ARGB按B/G/R/A解读；去掉行padding后才能保存正确PNG。导出的是原始像素时，可重建可视图片；若要求与原PNG逐字节一致，必须原样保存PNG文件，或者保留电脑源文件。[S3、S4，格式；工程建议]

## 12. 运行时保存图片或存档到Flash

若只需要静态游戏素材，电脑预烧即可，不必首先实现板端写入。若要截图、编辑图片或保存存档，则增加受限写接口：范围检查、按实际芯片页/扇区参数分块、写使能、擦除、编程、忙状态超时、读回CRC及最后提交有效标记。[S5；工程建议]

必须先读取实际芯片后缀/JEDEC并核对对应GD25LQ64手册，确认页大小、擦除粒度、保护位及最大耗时；本文不把其他芯片的保护或解锁指令当作通用行为。NOR擦除按区域进行，擦除包含其他资源的扇区会同时破坏它们。运行时写入与图片只读可分开实现。[S5；工程建议]

不建议把当前显示显存按像素变化持续写Flash：它不是实时显存，存在擦写延迟与寿命限制。对游戏存档保存状态参数通常比保存整屏更合适；完整1080p、4字节像素一张约7.91 MiB，几乎占满本板Flash。[容量计算；工程建议]

## 13. 是否需要Bootloader

| 使用方式 | 需要Bootloader吗 |
|---|---|
| IDE下载程序，程序读取Flash图片 | 不需要 |
| 程序运行时保存数据到Flash | 不需要 |
| JTAG/IDE/UART导出Flash图片 | 不需要 |
| 断开电脑后上电自动运行游戏 | 需要另行安排启动：Bootloader、应用随配置初始化或其他启动源 |

本文整颗Flash只存图片，和“同一颗Flash还保存FPGA/CPU启动镜像”不是同一个方案。若以后改为独立启动，就要重新分区，图片数量也必须按剩余容量计算。[S1；S2，页55；S7]

当前Bootloader源码从Flash`0x00380000`读取应用到`0xF9000000`，长度`0xFC00`。在图片专用布局中，这个位置可能是图片像素，不能运行旧Bootloader去加载；必须禁用该不适用启动路径或另选启动方案。板卡手册在此处有`0x380000`与`0x38000`两种写法，不能照抄，应以实际有效的启动代码和地址规划为准。[S1，页88；S3、S4]

## 14. 推荐实施与验收顺序

| 阶段 | 交付 | 验收标准 |
|---|---|---|
| 1 | SPI只读probe | 新硬件接线正确；ID/状态可重复读取；不擦写 |
| 2 | 小测试资源包 | Programmer校验通过；CPU读取字节/CRC一致 |
| 3 | 一张640×480图片 | Flash→OCRAM→DDR读回一致；正常显示 |
| 4 | 一张Alpha图集 | 格式、透明度、边缘、源窗口正确 |
| 5 | 资源目录与导出 | 整包CRC正确；读回电脑能重建图片 |
| 6 | 多资源游戏 | 素材共享、切换及既有显示保护正常 |
| 7，可选 | 运行时存档/图片写入 | 仅修改允许区；超时与断电中断可识别 |
| 8，另立需求 | 独立启动 | 重新安排启动存储；无IDE也能上电运行 |

各阶段保存源码版本、FPGA bitstream/ELF哈希、资源包版本、Flash布局及测试结果；明确区分仿真、工具校验和实体板卡运行。本文只完成文档整理，以上实施阶段尚未执行。

## 15. 资料与工程依据

- **S1：板卡手册**：[TI60F225I3-V4 DEMO板软硬件设计说明-260924.pdf](<D:/desktop/TI60F225I3-V4 DEMO板软硬件设计说明-260924.pdf>)。页6：8 MB与型号；页13：Type-C/FT4232HL；页14：默认JTAG Bridge及外部SPI方式；页32：Flash原理图、电源、电容；页34：J6及UART引脚；页88～90：固化流程。印刷页码比PDF物理页序号小1。
- **S2：Ti60数据手册v3.9**：[ti60-ds-v3.9.pdf](D:/desktop/ti60-ds-v3.9.pdf)。页45：特定封装内置Flash；页55：CRAM及配置模式；页74：配置/复用引脚。
- **S3：基础工程**：[SoC配置](D:/desktop/qiansai/2026FPGA/basic_demo/ip/soc_control/settings.json)、[顶层](D:/desktop/qiansai/2026FPGA/basic_demo/rtl/ti60f225_oob_top.v)、[SPI驱动](D:/desktop/qiansai/2026FPGA/basic_demo/embedded_sw/soc_control/software/standalone/driver/spi.h)、[Flash驱动](D:/desktop/qiansai/2026FPGA/basic_demo/embedded_sw/soc_control/software/standalone/driver/spiFlash.h)、[SPI示例](D:/desktop/qiansai/2026FPGA/basic_demo/embedded_sw/soc_control/software/standalone/spi/spiDemo/src/main.c)、[M2图片生成](D:/desktop/qiansai/2026FPGA/basic_demo/software/m2_demo/main.c)、[Bootloader参数](D:/desktop/qiansai/2026FPGA/basic_demo/embedded_sw/soc_control/software/standalone/bootloader/src/bootloaderConfig.h)。
- **S4：高级工程**：[SoC配置](D:/desktop/qiansai/2026FPGA/advanced_demo/ip/soc_control/settings.json)、[活动应用](D:/desktop/qiansai/2026FPGA/advanced_demo/software/advanced_demo/main.c)、[素材源检查](D:/desktop/qiansai/2026FPGA/advanced_demo/rtl/framebuffer/blit_source_guard.v)、[CPU DDR桥](D:/desktop/qiansai/2026FPGA/advanced_demo/rtl/framebuffer/cpu_ddr_bridge.v)、[地址合同](D:/desktop/qiansai/2026FPGA/advanced_demo/docs/REGISTER_MAP.md)。
- **S5：RV32 Flash API**：[Efinix SPI Flash Memory API Calls](https://www.efinixinc.com/docs-html/rv32-sapphire-ug/topics/riscv-sw-api-spiflash.html)。实际调用签名以项目内RV32驱动为准，不混用RV64新API。
- **S6：镜像转换**：[Efinix二进制转Programmer原始HEX](https://www.efinixinc.com/docs-html/rv32-sapphire-hpb-ug/topics/riscv-sw-convert-bin-to-raw-hex.html)。该页面属HPB产品文档，此处仅引用Programmer格式/偏移规则，不套用其应用运行地址。
- **S7：启动配置**：[Efinix Sapphire RV32 Modify the Bootloader](https://www.efinixinc.com/docs-html/rv32-sapphire-ug/topics/riscv-change-bootloader-ram-size-sapphire.html)。
- **S8：独立Flash读回工具**：[Efinix JTAG SPI Flash Loader](https://www.efinixinc.com/support/ip/flash-controller.php)。仅作为候选工具，不表示已在本机或本板验证。

资料给出的硬件事实、工程现状和本文建议分别标注。工程若发生变更，应重新核对SPI使能、有效顶层、BSP、资源权限及板上实际镜像。
