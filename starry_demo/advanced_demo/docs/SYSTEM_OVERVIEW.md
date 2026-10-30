# 当前系统实现与架构总览

核对日期：2026-10-28。本文以 advanced_demo 当前 v7 源码为准；basic_demo 是独立保留的基础/M2 工程。根目录部分历史文档中的“没有 Alpha、队列、UART、CPU DDR”等描述不适用于当前高级工程。

## 核心实现方式

系统在 Efinix Ti60F225 FPGA 上同时实现 Sapphire RISC-V 软核处理器和专用 2D 绘图硬件。RISC-V 执行裸机 C 程序，计算输入、运动、碰撞、关卡、计分并生成绘图命令；FPGA 绘图引擎处理像素读写；DDR 保存帧缓冲与素材；独立显示链路持续输出 HDMI。

厂商生成的 Sapphire SoC、DDR 控制器/PHY，以及继承的视频 FIFO/CVO/HDMI 链路构成平台基础。项目自有逻辑围绕图形寄存器、绘图引擎、命令队列、受控 CPU DDR 桥、素材访问检查、共享 DDR 仲裁和安全换帧展开。

~~~mermaid
flowchart TD
    PC["电脑：键盘发送与调试窗口"] -->|"UART 按键"| CPU["RISC-V 裸机游戏程序"]
    PC -.->|"JTAG 下载、命令与状态观察"| CPU
    CPU -->|"APB3 写参数 / START"| REG["图形控制寄存器"]
    REG --> Q["8 项绘图命令 FIFO"]
    Q --> GFX["2D 引擎：FILL / BLIT / Key / Alpha"]
    CPU -.->|"受控 DDR 会话：初始化与 CPU 对照"| BR["CPU DDR 桥"]
    GFX <--> AXI["共享 DDR 通路：读仲裁与写入准入"]
    BR <--> AXI
    AXI <--> DDR["DDR：Front、Back、背景、精灵图集"]
    AXI --> R["显示读通路、跨时钟 FIFO、像素拆包"]
    R --> H["CVO / RGB 转换 / HDMI：1080p60"]
    CPU -->|"换帧请求"| SWAP["双缓冲管理器"]
    SWAP -.->|"安全边界交换角色、更新读帧地址"| DDR
~~~

共享 DDR 通路是功能概括；实际 RTL 分别处理显示/绘图读仲裁、CPU 会话和写端所有权。CPU 访问 DDR 同样经过权限检查和显示保护。

## 各层职责

| 层次 | 实现与职责 |
|---|---|
| 游戏软件 | 单核 Sapphire RISC-V，100 MHz，64 KiB OCRAM，裸机 C 主循环；解析按键，更新敌机、子弹、碰撞、Boss、分数和生命 |
| 控制接口 | APB3、32 位寄存器，基址 0xF8100000；接收操作码、源地址、目标位置、尺寸、颜色/透明度，返回能力、忙闲、错误和统计 |
| 命令缓冲 | 8 项、每项 256 bit 描述符 FIFO；快照参数并按顺序发给引擎，队满时 CPU 等待 |
| 图形执行 | FILL、BLIT/Color Key、Alpha；产生 DDR AXI 事务，完成填色、复制和混合 |
| 存储与保护 | 128 位 AXI、DDR、CPU DDR 桥、读仲裁、写准入、源范围检查；共享显存，保护 Front 和封存素材 |
| 显示 | DDR Reader、FIFO、128→64 bit 拆包、CVO、RGB→HDMI；持续扫描 Front，输出 1920×1080@60 Hz |
| 观察与测试 | UART 输入、JTAG/OpenOCD、Python 调试窗口、板端计数；重开、调参、自测、压力场景及独立 60 秒测量 |

队列允许 CPU 提交与当前绘图重叠，但命令仍顺序执行；它没有增加 DDR 带宽，也不等于同时运行八个引擎。正常游戏不使用 CPU 逐像素重画整帧；CPU DDR 通路用于素材准备、校验、自测读回和基础 CPU/FPGA 对照等。

## 图形能力

- FILL_RECT：产生指定颜色，按行、按 burst 写 Back。
- BLIT：从合法源区域读像素，再写到 Back，游戏用它恢复海岛背景。
- Color Key：源 RGB 等于透明色键时，将对应像素写 strobe 置零，保留 Back；飞机和字形使用该路径。
- Alpha：读取图集前景与 Back 背景，结合逐像素 Alpha 和命令全局 Alpha 混合后写回；用于子弹、光晕和爆炸。

Alpha 的概念公式为 Aeff=round(Apixel×Aglobal/255)，Cout=round((Csrc×Aeff+Cdst×(255−Aeff))/255)。RTL 使用四像素计算通路、寄存器流水和整数运算；这不代表整个 DDR 读改写过程每个时钟都完成四个像素。

帧缓冲采用 XRGB8888，每像素 4 字节，显示只使用 RGB。图集在 Alpha 命令中把最高字节作为 A，Color Key 比较低 24 位 RGB。

## DDR 与双缓冲

| 区域 | DDR 物理起点 | 用途 |
|---|---|---|
| Buffer0 | 0x00000000 | Front/Back 物理槽之一 |
| Buffer1 | 0x00800000 | 另一个物理槽 |
| 三张 M2 素材 | 0x01000000、0x0112C000、0x01258000 | 基础图片对照及兼容素材接口 |
| 精灵/字形图集 | 0x01384000 | 飞机、子弹、爆炸、字形等 |
| 全屏海岛背景 | 0x02000000 | 1920×1080 背景及局部恢复源 |

单帧为 1920×1080×4=8,294,400 字节，stride=7680 字节；每个帧槽预留 8 MiB。CPU 地址别名与物理地址之间有 0x1000 偏移，访问需申请受控会话，并遵守白名单及素材装载/封存状态。封存后背景与图集只读。

显示读取 Front，绘图写 Back。软件请求 Swap 后，硬件确认命令/写响应排空、旧读事务完成、FIFO 可安全清理且处于垂直消隐窗口，才交换角色并锁存新读地址。交换改变地址角色，不复制整幅画面。

旧 Front 会变为下一轮 Back，因此两个物理槽分别管理背景、旧精灵覆盖区与 HUD 状态。

## 一帧如何生成

1. CPU 轮询 UART 和调试命令，按 16 ms 固定逻辑步更新游戏；渲染较慢时允许补做逻辑步。
2. 取得 Back 物理地址，开始一批命令。
3. 恢复背景，再提交效果、敌机、子弹、玩家和 HUD 的绘制命令。
4. CPU 入队，硬件顺序执行；队满时产生背压。
5. 帧末等待整批完成，检查错误。
6. 请求并等待安全换帧，更新耗时、呈现帧率和统计。

居中素材版启动时把整幅海岛复制到两个帧槽，正常帧恢复中央 640×480，再画精灵，外围保持静止。全屏版按物理槽保存 16×16 网格损伤信息，合并恢复区域，必要时完整恢复。居中版还没有同样的局部恢复，且 HUD 缓存在每帧被失效，仍有减少重复工作的空间。

## 显示保护与当前性能

DDR 同时服务显示读取、图形源读取和写回。显示 FIFO 水位低时，读仲裁优先补充显示数据；写准入根据水位及实际返回的显示读数据，控制下一笔写 burst 能否开始。

典型参数为 FIFO 低/高水位 384/512 个 128 bit word、读配额 128 beat。已开始的 AXI 事务保持到完成，不随意撤回 VALID 或打断响应。

新帧没准备好时，显示再次扫描旧 Front，所以 HDMI 60 Hz 与游戏 30 FPS 可以同时成立。2026-10-26 居中满载截图的 60 秒报告为平均/最低秒窗 30.00/30.00 FPS，最慢绘制 27.134 ms，新增 underflow/missed 为 0；满载定义仍为 48 敌机、64 敌弹。60 FPS 的整帧预算为 16.667 ms，当前绘制跨过一个刷新边界后需等下一个边界换帧。

写节流高说明写服务长期等待，不足以单独证明 DDR 物理带宽已满。下一步优先减少背景/HUD 重复恢复及短事务，再依据测量研究写准入和 Alpha/DMA 服务效率。

## 工程、启动与 Flash

basic_demo 保留基础 A–E 与 M2 CPU/FPGA 对照；advanced_demo 加入 Alpha、图集/背景、队列、互动游戏和调试测量，两套工程的 bit/ELF 分别配套。

bit 定义 FPGA 电路，ELF 是 RISC-V 程序。当前展示由电脑 JTAG 配置 bit，再加载 ELF 到 OCRAM；CMD 打开调试窗口并选择 ELF。输入经过 UART，调参/观察走 JTAG，游戏逻辑与像素绘制都在板上运行。

另有 SPI Flash 素材/最高分/难度存档实现；当前居中和全屏演示 ELF 显式关闭 GAME_FLASH_ENABLE，素材来自编译进 ELF 的转换数据，启动后展开到 DDR。Flash 扩展不能描述为当前展示版已使用 Flash 自动启动。

## 源码入口

- 顶层：advanced_demo/rtl/ti60f225_oob_top.v
- CPU/APB/UART/CPU DDR 桥集成：advanced_demo/rtl/control/sapphire_control.v
- 图形寄存器：advanced_demo/rtl/control/accel_regs.v
- 队列/绘图/DDR/显示/Swap 集成：advanced_demo/rtl/framebuffer/rgb_framebuffer.v
- 队列：advanced_demo/rtl/accelerator/graphics_command_queue.v
- 绘图分发：advanced_demo/rtl/accelerator/graphics_engine.v
- Alpha：advanced_demo/rtl/accelerator/alpha_blit_engine.v、alpha_pixel_pipeline.v
- 游戏主循环与渲染：advanced_demo/software/interactive_demo/game_main.c
- 运动/碰撞/战役：advanced_demo/software/interactive_demo/game_logic.c
- 软件绘图接口：advanced_demo/software/apb_reg_test/accel_api.h
- 当前寄存器与契约：advanced_demo/docs/REGISTER_MAP.md
- 演示配对：advanced_demo/docs/DEMO_GUIDE_20261028.md
