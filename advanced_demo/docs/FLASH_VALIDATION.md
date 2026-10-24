# Flash 交付验证记录

日期：2026-10-24。基线提交 `8765c08185a0975ceac1729a4cbc7651621eb282`。验证在独立工作副本进行，再按文件摘要核对同步到 VSCode 仓库。未操作板卡、未擦除或烧写实物 Flash。

## 工具与验证范围

- Efinity 2026.1.132，Sapphire SoC IP 3.4.0，Ti60F225 / I3。
- Efinity RISC-V IDE 2026.1，GNU RV32 GCC 13.4.0，`rv32im_zicsr_zifencei` / `ilp32`。
- Python、Pillow、Unicorn 2.1.4；SPI FIFO/Flash 命令模型和本机 GDB 假 RAM 目标均不连接板卡。

## 已通过

| 项目 | 结果与证据 |
|---|---|
| 正式 IP 生成 | SPI0 启用、UART0 保留；生成的 RAM 四个字节通道复位首字合成 `6F000000`，即 `jal x0,0`，没有从素材地址读取应用的启动程序。 |
| 工程静态检查 | 58 个唯一设计文件，57 项 RTL/头文件/文档寄存器一致；四个 SPI 管脚、1.8 V 电平、BSP 基址一致，全部生成的 SoC 输入都有连接。 |
| 游戏、只读导出、维护 ELF | `-Wall -Wextra -Werror` 编译成功；全部 LOAD 段与栈在 `0xF9000000` 起 64 KiB OCRAM，避开末端 OpenOCD 1 KiB。最终仓库构建的游戏栈顶 `0xF9008010`，包含 8 KiB 静态栈预留。 |
| 原模式兼容 | `GAME_FLASH_ENABLE=0` 的游戏构建和 `m2` 应用构建通过。`basic_demo` 未改动。 |
| RV32 存档 | 标准 CRC、增量 CRC、A/B 新旧选择、不变值不重复擦写、半擦除/半正文写入/半提交中断后旧记录恢复、损坏新记录回退、非法难度和资源越界检查通过。 |
| RV32 SPI 传输 | 使用真实 `flash_spi.c` MMIO，命令级模型验证读取、页写、擦除、回读、运行期素材区写保护、跨页拒绝、错误 JEDEC、BUSY 和 FIFO 超时。模型不覆盖真实电气时序。 |
| 原游戏/UART 回归 | 游戏逻辑、三档难度生成间隔、UART 协议和输入处理均在真实 RV32 编译后的指令模拟中通过。 |
| 资源工具 | 4,980,736 字节素材包 PNG 往返逐字节相同；Color Key 透明转换、损坏/截断拒绝、上传 3162 个动作地址检查、存档区保留、导出分块合并通过。 |
| 实际 IDE GDB | 用 IDE 自带 GDB 连接本机假 RAM 目标，实际执行 `restore ... &g_flash_maint.data[0]` 与 `dump binary memory ...`，2560 字节往返完全一致；不连接 OpenOCD/板卡。发现该 GDB 的文件名不支持引号和空格，工具已提前拒绝此类路径。 |
| Interface Designer | 最终正式流程已生成 LPF 和接口 CSV，四个 Flash 端口均存在，无新增接口错误。 |
| FPGA 全流程 | 综合、接口生成、布局布线、编程文件生成通过；实际输出 `.bit` 2,985,183 字节、`.hex` 2,985,243 字节。不是仅根据退出码判断成功。 |
| Hard JTAG | 最终综合网表检查通过：`jtag_inst1_TDI` 实际参与逻辑，没有被删掉。 |

资源报告：XLR 51,546 / 60,800（84.78%），Memory Blocks 169 / 256（66.02%），DSP 46 / 160（28.75%）。最终报告 core_clk 100 MHz、最大分析频率 106.349 MHz、core→core setup slack +0.597 ns。此项是 FPGA 已约束路径的静态分析，不代表 Flash 外部引脚电气裕量或整机实测性能。

## 构建警告与排查结果

- 首次编程阶段虽然显示 PASS，但实际日志说明缺少 LPF、没有输出文件；已排除这一无效产物，最终重新生成接口约束并确认真实 `.bit/.hex`。
- 此会话环境没有 `PROCESSOR_ARCHITECTURE`，厂商 Python 的架构识别返回空，导致接口模块导入失败。当前进程补充 `AMD64` 后成功生成。未修改 Efinity 安装文件、未改系统级环境变量。普通安装环境一般已有该变量。
- 链接器有 OCRAM LOAD 段 RWX 提示，这是当前裸机统一 RAM 布局；构建仍检查所有段的真实地址/大小。
- 保留的参考设计/旧自动调试 SDC 存在未匹配端口提示；接口报告保留 HDMI LVDS 与 `GPIOR_P_09` 间距警告，及原工程未使用复位等警告。本次未改无关显示设计。需要板卡画面及长时间稳定性验证。
- 不将前期没有 LPF 的时序报告作为最终证据；上述资源和时序数据来自最后带正式接口约束的构建。

## 可复现命令

在 `advanced_demo`：

```text
python scripts/check_project.py
python scripts/build_apb_software.py --program game --opt O2
python scripts/build_apb_software.py --program flash-probe --opt O2
python scripts/build_apb_software.py --program flash-maint --opt O2
python scripts/run_flash_checks.py
python scripts/test_flash_assets.py
python scripts/test_flash_gdb.py
python scripts/check_flash_delivery.py --require-bitstream
python scripts/check_jtag_interface.py
```

`run_flash_checks.py` 需要可导入 Unicorn；若安装在单独目录，使用 `--unicorn-path 路径`。Pillow 仅用于图片工具测试。硬件命令需要 Efinity 命令行环境；`check_flash_delivery --require-bitstream` 在本地已编译的 `outflow` 下运行，其他电脑需先重建硬件。

本机整理的下载文件、三份 ELF、资源示例、脚本和构建证据放在仓库 `advanced_demo/output/flash-release/`、`output/flash-example/`；这些属于本地构建产物，未纳入 Git。交付来源和文件摘要见 release 中的 manifest。随源码提交的 [交付证据目录](evidence/flash_20261024/README.md) 另保存关键编译/测试日志及摘要清单，供 GitHub 上直接查阅。

## 待板卡验收

JEDEC 实物识别、GD25LQ64 实际保护位状态、2.5 MHz SPI 波形、维护脚本整包上传/整片读回、游戏显示与帧率、最高分/难度断电保持都未在硬件确认。操作步骤与验收清单见 `FLASH_DELIVERY.md` 第 5–9 节。当前不宣称已烧录成功或游戏上板验收通过。
