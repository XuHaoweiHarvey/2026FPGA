# Ti60F225 游戏 Flash 封装与交付说明

日期：2026-10-24。基于团队 `8765c081` 的 `advanced_demo` UART 生存射击游戏、v6 Alpha/Color Key 图形引擎。

**本次实现采用已经确定的方式：每次上电由电脑通过 JTAG 下载 FPGA 配置，再由 RISC-V IDE 下载应用到片内 RAM。Flash 保存素材和存档。没有自动启动游戏，也不需要另加 Bootloader。**

本文中的“已实现”表示有源代码、生成结果和离线验证；板卡实测必须按末尾清单逐项记录，不能把软件模拟结果当成上板结果。

## 1. Flash 是什么，本项目保存什么

Flash 是断电后仍保留内容的非易失性存储器。板卡使用外接 GD25LQ64 串行 NOR Flash，64 Mbit 即 8 MiB（8,388,608 字节），不是 FPGA 片内 RAM。它既可用于 FPGA 配置，也可在 FPGA 运行后作为用户数据存储。本方案将其作为用户素材和存档区，程序运行在 OCRAM、图片显示从 DDR 读取。[资料：V4 板卡说明第 32 页“七、Flash”；容量换算为本说明计算；当前程序路径见第 4 节。]

板上 Flash 使用 1.8 V 供电，不能把它当作 3.3 V SPI 外设接线。手册说明 CLK 第 6 脚一般不需要预留电容，原图 C154 标为 NC；C153 是电源去耦，二者作用不同。本实现使用单线 SPI、Mode 0、约 2.5 MHz，不修改 QE 或保护寄存器。[资料：V4 板卡说明第 32 页原理图；本项目 `flash_spi.c`。]

首版保存三张背景和一张精灵/特效图集，每张 640×480、每像素 4 字节。图集内部有玩家、敌人、子弹、光晕；它不是“只能有一张小精灵”。最高分和难度独立存储，难度 0/1/2 分别对应简单/普通/困难，通过生成间隔影响敌人数量。没有保存战场中每个敌人的实时位置，也没有实现完整断点续关。[来源：`game_main.c`、`game_logic.c`、`game_flash.c`。]

## 2. 地址与格式：三种地址不能混用

下表的 Flash 地址是芯片内**字节偏移**，不是 RISC-V 指针。CPU 通过 SPI0 寄存器 `0xF8014000` 发命令、地址和数据；不能直接解引用 `0x7E0000` 来读取 Flash。[来源：生成的 BSP `soc.h`、`flash_spi.c`。]

| Flash 范围 | 内容 | 规则 |
|---|---|---|
| `0x000000–0x00009F` | 32 字节包头 + 4×32 字节资源目录 | 小端、版本 1、头/目录 CRC32 |
| `0x0000A0–0x00FFFF` | 预留填充 | `0xFF` |
| `0x010000–0x13BFFF` | ID1 背景 0 | 640×480 XRGB8888 |
| `0x13C000–0x267FFF` | ID2 背景 1 | 同上 |
| `0x268000–0x393FFF` | ID3 背景 2 | 同上 |
| `0x394000–0x4BFFFF` | ID4 精灵图集 | 640×480 ARGB8888 |
| `0x4C0000–0x7DFFFF` | 当前未用素材空间 | 需扩展目录/渲染契约后才能增加资源 |
| `0x7E0000–0x7E0FFF` | 存档 A 扇区 | 只擦除这一 4 KiB 扇区 |
| `0x7F0000–0x7F0FFF` | 存档 B 扇区 | 同上，其余保留空间不使用 |

素材包精确长度 `0x4C0000`，即 4,980,736 字节。只按容量计算，在保留当前头部和存档区后最多能容纳 **6 张** 640×480×4 的独立图片；**本版软件与 DDR 白名单配置为 4 个资源，不能直接放 6 张就要求游戏显示**。更小的精灵可拼到图集中，当前实际读取位置见第 5 节。[来源：`flash_store.h/.c` 和打包工具；容量计算 `(0x7E0000-0x10000)//(640*480*4)=6`。]

| 资源 | DDR 物理地址（图形引擎） | CPU 地址（当前无缓存别名） |
|---|---|---|
| 背景 0 | `0x01000000` | `0x01001000` |
| 背景 1 | `0x0112C000` | `0x0112D000` |
| 背景 2 | `0x01258000` | `0x01259000` |
| 图集 | `0x01384000` | `0x01385000` |

每个窗口 1,228,800 字节，行跨度 2560 字节。不要改变团队现有 DDR 别名、窗口范围或显示引擎白名单。图形引擎拿的是物理地址，CPU 指针则加 `SYSTEM_DDR_BMB=0x1000`。[来源：团队 `accel_api.h`、`blit_source_guard.v`、`game_main.c` 和 BSP。]

## 3. 封装边界与文件职责

以下路径均相对 `advanced_demo`。调用方向为：游戏 → `game_flash` → `flash_store` / `flash_spi` → SPI0 → 板载 Flash；素材加载成功后走已有 DDR/图形引擎。

| 文件 | 已完成内容、接口与边界 |
|---|---|
| `ip/soc_control/settings.json` | 保持 UART0、DDR、64 KiB OCRAM、Hard JTAG 和无缓存配置；启用 SPI0，SPI1/2 关闭；选择自定义 RAM 初始化文件。 |
| `scripts/generate_flash_soc.py` | 调用本机 Efinity IP Manager 3.4 官方生成接口，生成 SoC/BSP/模板/RAM 文件，不手改厂商 RTL。使用前必须进入 Efinity 命令行环境。 |
| `software/flash/jtag_wait.hex` | 一条 `jal x0,0` 指令，位于复位向量 `0xF9000000`，等待电脑下载；不会读取 Flash 头部或跳转游戏。 |
| `software/flash/ocram.ld` | 项目自有链接脚本，64 KiB OCRAM、8 KiB 栈；绕开生成器启用 DDR+SPI 后默认产生的 DDR 启动链接脚本。所有正式应用构建均显式使用它。 |
| `rtl/ti60f225_oob_top.v` | 增加 4 个板级 SPI 信号，传给控制封装。 |
| `rtl/control/sapphire_control.v` | 将 SoC IO0 接 MOSI、IO1 接 MISO，连接 SCLK/CS；未使用 IO2/3 输入置高，输出不接。 |
| `ti60f225_oob.peri.xml` | 配置四个物理管脚与 1.8 V 电平；WP#/HOLD# 保留板上拉高，不由用户逻辑驱动。 |
| `software/flash/flash_spi.c` | 直接使用生成的 FIFO 寄存器契约，实现 JEDEC 检查、读取、页写、4 KiB 擦除、WEL/BUSY/超时；游戏只能写 A/B 存档扇区。 |
| `software/flash/flash_store.h/.c` | 与硬件无关的读取/写入/擦除回调接口；字节序、CRC32、包头/目录/资源边界验证、双份存档提交与恢复。 |
| `software/flash/game_flash.h/.c` | 游戏门面：初始化、按行读取、期望 CRC、最高分更新；诊断结构 `g_flash_result` 可在 IDE 查看。 |
| `software/interactive_demo/game_main.c` | Flash 图片逐行装入原有 DDR 窗口，验证数据与 DDR 回读，再封存；背景按每 1000 分轮换，图集走 Color Key/Alpha；结束时按需保存最高分，HUD 显示 BEST、难度及保存错误。 |
| `software/interactive_demo/game_logic.h/.c` | 增加难度参数；普通难度维持原逻辑，简单/困难的生成间隔分别为原来的 1.5/0.75 倍。 |
| `software/flash/flash_probe.c` | 只读导出程序；每次最多 2560 字节，停在 `flash_dump_ready`，不调用写入/擦除。 |
| `software/flash/flash_maint.c` | 单独下载的维护程序。动作 1 读取、2 擦素材扇区、3 写素材并回读比对、4 提交存档；写操作还要求显式 cookie。它不是 Bootloader。 |
| `tools/flash_assets.py` | PNG 示例、打包、检查、还原 PNG、解析存档；不直接连接板卡。 |
| `tools/flash_transfer.py` | 生成 GDB 写入/导出/设置脚本和数据分块；上传限定素材区、遇错停止后续动作；合并导出块。 |
| `scripts/build_apb_software.py` | 复用队友的正式 BSP/启动代码，支持 game、flash-probe、flash-maint；检查 ELF 全部位于 OCRAM，保留末端 1 KiB 给 OpenOCD。 |
| `scripts/prepare_flash_ide.py`、`software/flash/Makefile` | 复用团队 Hard JTAG 配置，生成独立 game_flash IDE 工程和三套启动配置；路径迁移后重新生成。 |
| `scripts/check_project.py` | 核对 SoC 所有输入接线、SPI 启用状态、BSP 基址、唯一管脚及电平，与原图形寄存器检查一起运行。 |
| `scripts/run_flash_checks.py`、`sim/test_flash_store.c`、`sim/test_flash_spi.c`、`sim/flash_spi_model.py` | 用真实 RV32 编译与指令模拟执行存档和 SPI 驱动测试；同时跑原游戏和 UART 协议/输入回归。 |
| `scripts/test_flash_assets.py` | PNG→包→PNG→包逐字节一致性、损坏/截断、上传动作边界与保存区保留、导出分块合并测试。 |

参考了团队 `GAME_BUILD_REPORT.md`、`KEYBOARD_UART_INPUT.md`、`REGISTER_MAP.md`、`BOARD_VALIDATION_CHECKLIST.md` 的交付方式：接口不凭空新增图形寄存器；调试保留已有诊断结构和 DDR CPU 会话；验证结果与板卡待验收项分开记录。`basic_demo` 的已验收 M2 工程不参与本次改动。

接口细节：`flash_io_t` 的 `read(context, offset, buffer, bytes)`、`program(...)`、`erase(context, sector_offset)` 均返回错误码，0 为成功。`program` 不隐式擦除，单次不能跨 256 字节页；`erase` 是 4096 字节扇区。`flash_pack_open` 只验证头/目录，像素 CRC 由 `flash_asset_verify` 或游戏加载过程验证。`flash_crc32` 首次传 0，下一块传前一次返回值。`game_save_load/write` 通过 `game_save_info_t` 返回有效槽位与序号；写入相同值直接返回，不增加擦写。

包头按小端 u32 顺序为：magic `F2AS`、版本、头长 32、资源数 4、总长度、目录 CRC、保留 0、前 28 字节 CRC。每条目录 32 字节，依次为 ID、Flash 偏移、宽、高、行跨度、格式、像素字节数、像素 CRC。格式 1=XRGB、2=ARGB。读端固定验证四个 ID/尺寸/格式、4 KiB 对齐、互不重叠和不进入存档区；任何不符合的包都不会封存 DDR 素材。

`game_flash_begin` 初始化 SPI/包目录/存档；`game_flash_row(index,row,pixels[640])` 读取一行，索引为 0–3；`game_flash_expected_crc` 提供对应目录 CRC；`game_flash_update_score` 只有更高分才提交。游戏错误停在诊断入口，存档写失败只报告保存错误，不反复擦除；成功回写后才更新内存中的“已保存最高分”。

## 4. 前期准备、编译和 IDE 配置

下面 PowerShell 命令从 `D:/desktop/qiansai/2026FPGA/advanced_demo` 执行。示例 `python` 指可用的 Python 3。图片工具需要 Pillow；RV32 离线模拟测试另外需要 Unicorn 2.1+。正式固件编译不依赖这两个 Python 包。

1. 确认 Efinity 在 `D:/Efinity/2026.1`，RISC-V IDE 在 `C:/Efinity/efinity-riscv-ide-2026.1`。其他成员安装位置不同，用 `--ide-root` 指定。不要打开原参考工程后直接采用它的 DDR 链接脚本。
2. 已交付生成的 SPI SoC，无需每次重新生成。若重新配置 IP，在 Efinity 命令提示符执行：

   ```text
   python scripts/generate_flash_soc.py --efinity-home D:/Efinity/2026.1
   ```

   或先在 cmd 调用 `D:\Efinity\2026.1\bin\setup.bat`，再运行它。重新生成后检查 `HexFile_PathEnable=1`、`HexFile_Path="software/flash/jtag_wait.hex"`。生成器自带 `default.ld` 可能仍是 DDR 124 KiB，本项目**只使用 `ocram.ld`**。
3. 检查并编译三个 ELF：

   ```powershell
   python scripts/check_project.py
   python scripts/build_apb_software.py --program game --opt O2
   python scripts/build_apb_software.py --program flash-probe --opt O2
   python scripts/build_apb_software.py --program flash-maint --opt O2
   python scripts/prepare_apb_ide.py --debug-only
   python scripts/prepare_flash_ide.py
   ```

4. IDE：File → Import → Existing Projects into Workspace，选择 `advanced_demo/software/flash`，导入 `game_flash`。Build 默认为游戏；也可从命令行先编译。维护与导出使用已编译的 ELF，不要在每次切换启动配置时自动重建其他目标。
5. Debug Configurations 中选择 `game_ti` / `maintenance_ti` / `probe_ti`。它们分别下载游戏、维护、只读程序。均为 RAM 调试、PC `0xF9000000`、停在 `main`；确认下载和符号文件指向各自 ELF，不能继续引用其他成员电脑上的旧绝对路径。
6. 硬件：在 Efinity 的项目中先生成 Interface Designer 接口约束，再运行综合、布局布线和编程文件生成。在 Efinity 命令行对应：

   ```text
   efx_run.bat ti60f225_oob.xml --flow interface
   efx_run.bat ti60f225_oob.xml --flow compile
   ```

   必须确认实际存在新的下载文件；仅 `pgm : PASS` 而日志提示缺少 LPF 时并不代表已输出文件。通过 Programmer 的 **JTAG 下载到 FPGA**，不要选择将此配置烧入同一片素材 Flash。

## 5. 队友怎样制作和存入像素图

先提供可用示例，再替换为美术资源：

```powershell
python tools/flash_assets.py sample output/art
# 编辑 output/art 内的 4 张 PNG 和 manifest.json
python tools/flash_assets.py pack output/art/manifest.json output/assets.bin
python tools/flash_assets.py inspect output/assets.bin
python tools/flash_transfer.py upload output/assets.bin output/flash-upload
```

`manifest.json` 的最小结构如下，文件名可改，ID 必须完整：

```json
{"resources":[
  {"id":1,"file":"background0.png"},
  {"id":2,"file":"background1.png"},
  {"id":3,"file":"background2.png"},
  {"id":4,"file":"sprite_atlas.png"}
]}
```

所有 PNG 必须 640×480。打包程序转换为小端像素字：内存字节 B、G、R、A/X，CPU 读取为 `0xAARRGGBB`。背景的 X 固定为 0。不会把 PNG 压缩文件直接交给 FPGA 解码。

维护/导出的输出目录请使用纯英文数字、不含空格的路径。实测本版 IDE 的 GDB `restore/dump` 不接受带引号的文件名；工具会提前拒绝中文、空格或引号路径。当前 `D:/desktop/qiansai/2026FPGA/...` 可直接使用。

图集左上角固定布局：

| 图像 | 图集坐标 x/y | 大小 | 透明规则 |
|---|---|---|---|
| 光晕/爆炸效果 | 0/0 | 64×64 | Alpha，可半透明 |
| 玩家 | 64/0 | 32×32 | Color Key，RGB `FF00FF` 为透明 |
| 敌人 | 96/0 | 32×32 | 同上 |
| 子弹 | 128/0 | 16×16 | Alpha，可半透明 |

玩家/敌人的 PNG 全透明像素会转换成品红色键；这两个槽位的半透明边缘会被拒绝，因为现有调用使用 Color Key。其余 Alpha 槽位允许 0–255 透明度。更多动作帧、独立敌人形状和新特效需要同步扩展目录或图集坐标以及游戏调用，不能只在 PNG 任意位置画完就自动被引用。

**真实写入步骤：**

1. 接通 Type-C 和 HDMI，用本版配置通过 JTAG 下载 FPGA。先结束游戏调试会话，再启动 `maintenance_ti`，停在 `main`。
2. 关闭/禁用其他普通断点，打开此会话的 **GDB 命令控制台**，不是串口窗口或 OpenOCD 控制台。
3. 执行：

   ```text
   source D:/desktop/qiansai/2026FPGA/advanced_demo/output/flash-upload/upload.gdb
   ```

4. 脚本先等初始化完成，核对 JEDEC；仅擦除素材包占用的 4 KiB 扇区，按页写入，并逐块读回比对。资源数据先写、包头所在预留区最后写。存档 A/B 不擦除。出现 `FLASH STOP` 查看 `g_flash_maint.error`，修复后重新加载维护 ELF 并重新执行完整上传；不要从脚本中间猜测恢复位置。
5. 只有看到 `FLASH UPLOAD VERIFIED` 才算上传完成。GDB 逐块传输是方便调试的首版流程，整包较大，速度以实际 JTAG 传输为准；这期间不要断电。它没有实现素材包 A/B 原子更新，途中断电需要完整重传。
6. 结束维护调试，重新下载 FPGA 配置以清除旧 DDR 封存状态，再启动 `game_ti`、Resume。游戏检查包头、目录和每份资源 CRC，装入 DDR，HUD 显示 BEST 和难度；错误停在 `game_demo_done` 并保留诊断。

本方案使用 Flash 偏移 0 存放包头，因此不能同时保留从同一偏移启动的 FPGA 配置镜像。写入前若板上有需要保留的旧内容，先按第 7 节导出整片备份。后续每次上电仍按约定从电脑下载配置和应用。

## 6. 存档怎样使用、修改和恢复

游戏启动时读取两份记录，验证格式、CRC 与提交标记，选择序号较新的有效记录。没有有效记录时用最高分 0、普通难度 1。只有一份损坏则读取另一份；两份都无效时不会恢复旧分数。保存时擦除另一扇区、写正文并回读、最后写提交标记；旧有效记录始终保留。不在每帧写 Flash，游戏结束且超过已保存最高分时才写；失败会显示保存错误。[实现：`flash_store.c`、`game_flash.c`、`game_main.c`；模拟覆盖擦除/正文/提交阶段失败。]

记录共 36 字节，依次为 9 个小端 u32：`F2SV magic`、版本 1、序号、载荷长度 12、最高分、难度、保留 flags=0、前 28 字节 CRC32、`CMIT` 提交标记。序号采用 32 位环绕比较。A/B 是两份记录，不是 FAT 文件系统；不能用资源管理器双击打开。

队友若要明确设置初始存档，例如最高分 200、困难模式：

```powershell
python tools/flash_transfer.py settings output/settings --score 200 --difficulty 2
```

重新加载 `maintenance_ti` 停在 main，在 GDB 控制台 `source .../output/settings/settings.gdb`，看到 `SAVE COMMITTED` 后重新下载游戏。该命令会替换保存值；保留现有最高分时先读取记录，再把同一个分数传给 `--score`。难度只在启动时装载，不是在游戏运行中直接修改 Flash 后立即生效。

## 7. 从 Flash 读回、导出并还原图片

导出不使用维护程序，使用 **只读 `probe_ti`**。例如导出整个 8 MiB：

```powershell
python tools/flash_transfer.py dump output/flash-dump --offset 0 --length 0x800000
```

重新启动 probe_ti，停在 main、禁用其他断点，在 GDB 控制台执行：

```text
source D:/desktop/qiansai/2026FPGA/advanced_demo/output/flash-dump/dump.gdb
```

脚本每次请求一块，停在 `flash_dump_ready`，检查返回偏移、长度和错误后导出目标内存；直到提示 `FLASH DUMP COMPLETE`。然后回电脑执行：

```powershell
python tools/flash_transfer.py join output/flash-dump output/flash-readback.bin
python tools/flash_assets.py inspect output/flash-readback.bin
python tools/flash_assets.py unpack output/flash-readback.bin output/restored-png
python tools/flash_assets.py saves output/flash-readback.bin
```

`join` 检查块是否齐全和长度；`inspect/unpack` 再校验头、目录、每份像素 CRC。`restored-png` 内得到 4 张 PNG 和可再次打包的 manifest。这里还原的是转换后的像素图，不保证恢复原 PNG 文件的压缩字节或额外元数据。`saves` 打印两份记录有效性、序号、最高分和难度。只导出素材时长度可用 `0x4C0000`，但这个范围不包含存档。

## 8. 板卡接线与 SPI 参数

| 信号 | FPGA GPIO / 封装脚 | Flash 脚 | 方向 |
|---|---|---|---|
| CS# | GPIOL_P_01 / P1 | 1 | FPGA 输出 |
| CLK | GPIOL_N_01 / N1 | 6 | FPGA 输出 |
| MOSI / DI | GPIOL_P_03 / M1 | 5 | FPGA 输出 |
| MISO / DO | GPIOL_N_03 / L1 | 2 | FPGA 输入 |

资料依据：V4 手册 Flash 原理图及引脚对照，仓库板卡原理图。WP#（3）与 HOLD#（7）保留板上拉高。当前 Type-C 经 FT4232HL 提供现有电源/JTAG/UART 通路；Flash 已焊在板上并连到 FPGA，**不需要另加 SPI 杜邦线**。HDMI 接显示器，PC 键盘沿用团队 UART 工具。不要将新的外部 SPI 下载器与正在驱动 Flash 的 FPGA 并联。

软件发送 `9F` 读取 JEDEC，仅接受 `C8 60 17`；`03` 普通读取，`06` 写使能，`05` 状态，`02` 页写，`20` 4 KiB 擦除，`AB` 退出深度掉电。分频 19，在 100 MHz 外设时钟下 `100M/[2×(19+1)]=2.5 MHz`；SPI0 FIFO 深度 256。不同实物 ID、保护设置、工作模式或器件型号必须先核实，不能直接删除检查强行写入。命令与寄存器依据当前生成的厂商 `driver/spi.h`，实际器件响应仍需实测确认。

## 9. 诊断和验收

错误码：0 成功、1 空内容、2 传输/写使能错误、3 地址/长度越界、4 格式不支持、5 CRC/回读不符、6 超时、7 JEDEC 不匹配。游戏 `g_flash_result` 有 JEDEC、error、当前资源/行/CRC、save_status、save_slot、save_sequence、high_score、difficulty；`g_game_result` 继续保留原图形引擎、帧率和 UART 诊断。

| 检查 | 本次状态 | 能证明与不能证明 |
|---|---|---|
| 厂商 IP 生成、端口/BSP/管脚静态检查 | 已通过 | 配置一致，不代表板载 Flash 已应答 |
| RV32 存档、SPI 寄存器模型、游戏逻辑、UART 协议/输入 | 已通过 | 真实 RV32 指令执行；不是器件电气仿真 |
| PNG 打包/还原、损坏拒绝、维护脚本地址、导出合并、存档区保留 | 已通过 | 主机/命令级流程正确，GDB 与硬件联调仍待实测 |
| 综合、布局布线与接口/下载文件 | 结果见 `FLASH_VALIDATION.md` | 必须查看实际输出与约束，不能只看工具退出状态 |
| JEDEC 实物读取、图集显示、断电存档、JTAG 完整上传/导出 | 待上板 | 本次未进行擦除、烧写或板卡操作 |

上板验收顺序：

1. 只读探测 ID，确认与实际器件一致；必要时先导出原整片内容。
2. 上传示例包，读回、inspect、还原 PNG，与本机包逐字节比较。
3. 下载游戏，检查四个资源 CRC、DDR 回读、彩色键玩家/敌人、Alpha 光晕/子弹、背景轮换与 UART 键盘。
4. 连续运行并检查 `g_game_result`：无 reader/CPU DDR 错误、无 underflow/missed 增长，记录实际帧率；新增整屏背景 BLIT 有额外带宽，不能沿用旧版帧率结论。
5. 制造新最高分后退出/断电；重新 JTAG 下载 FPGA 和游戏，确认最高分与难度保留。只断电再上电不会自动启动游戏。
6. 更新图片后检查存档区未变；存档写入中断/损坏回退如需实物验证，使用可丢弃测试数据并保留导出备份。
7. 在记录中注明板卡版本、工具版本、JEDEC、资源包 CRC、配置文件摘要和照片，再签署硬件验收。

需要扩展时：更多图集帧先改坐标和调用；更多独立图片先扩展包目录/固定 4 个窗口校验/DDR 白名单；真正自动上电启动则另立 FPGA 镜像分区与应用 Bootloader 方案，不能直接套用当前 Flash 地址。
