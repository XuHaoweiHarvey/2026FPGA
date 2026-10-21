# M1a CPU→DDR 接入与验收

> 目录整理后，P3 的 M1a 工程副本位于 `advanced_demo/`。在该目录运行脚本并打开 `advanced_demo/ti60f225_oob.xml`；历史 P3 bit/ELF 是验收证据，迁移后的重新编译与上板结果需另行记录。本次迁移复验的独立软件构建位于 `advanced_demo/output/board_revalidation/m1a/m1a_ddr_smoke.elf`，本地 M1a Launch 已指向它，搬来的旧 ELF 保留原样。

## 状态与边界

本页描述 M1a 的实现和验收。项目负责人于 2026-10-21 确认 P3 工作树中的 M1a 已通过 FPGA 实板验收。M1a 烟测验证最小 CPU→DDR 读写、Front/Back 会话与事务排空、旧 FILL/BLIT/Color Key 回归及 DDR/HDMI 显示稳定性；它不是 CPU/FPGA FPS 对比。v5 的独立基线归档保存在 `D:/Github_repositories/_phase3_baselines/v5-20261020-200945-bcc39b40/manifest.json`。

用户在独立工程中 Generate 了 `soc_control`（efx_soc 3.4.0）：External Memory 与 AXI4 Full-Duplex 开启，128-bit 数据、8-bit ID、Cache 禁用；APB、Hard JTAG 和 OCRAM 64 KB 保留。正式生成 `soc.h` 给 CPU 的 DDR 窗口基址 `0x00001000`，大小 `0xE0000000`；`default.ld` 仍把程序、数据、栈放在 `0xF9000000` 的 64 KB OCRAM。GUI 中 124 KB Application Region 是调试设置，不改变这份 linker 的 OCRAM 长度。

## 实际接线

- 生成 RTL 的 BMB→AXI 桥保持原 CPU 字节地址，未减 `0x1000`。本工程桥将其减去 `0x1000`，再向下对齐到 16 字节。CPU `0x00001000` 映射 DDR 物理 `0x00000000`；`0x00801000` 映射 `0x00800000`。
- 生成 SoC 的 `BmbUpSizerBridge` 把 32-bit store 的数据放进相应 128-bit lane，并产生 16-bit WSTRB；read 从相同 lane 取回 32-bit。四个 lane 已用生成 RTL 模块仿真验证。SoC AXI 发出 SIZE=4、LEN=0，桥仅接受此单拍 INCR、无 lock 的形式。
- 桥只允许当前锁定 Back 的有效 `1920×1080×4 = 0x7E9000` 字节写；Front 和 Back 有效区可读。Padding、窗口外地址、跨界或错误 lane 都返回 DECERR，不发 DDR AW/AR。
- CPU 桥只保留一个事务；AW 和 W 各自接收，完整 W 被缓存后才发 DDR AW，DDR 接收 AW 后再发 W。下游固定 ID0，B/R 校验 ID0，上游恢复保存的 8-bit 原 ID。CPU reset/debug 只取消上游未完成响应，已经发出的 DDR 写继续到 B，读继续到 RLAST；平台会话锁保留到显式释放。
- APB 会话锁由平台复位，不随 Sapphire CPU reset 清除。会话取得前要求 Front 有效、无图形命令、无待换帧、桥空闲。期间拒绝新 START/Swap；释放前要求桥空闲。显示读仍通过原读仲裁器享有低水位优先级；CPU 写沿用原写准入与节流。DDR Controller、VBlank Swap、Writer Throttling、FILL/BLIT/Color Key 执行单元未修改。
- 生成 IP 中原 AXI Slave 0 出现 `io_ddrMasters_0_*` 32-bit 输入端口。当前无外部 master，全部请求输入明确绑低，时钟接 core_clk；未修改厂商生成文件。

## 新寄存器

旧 `0x00..0xC4` 契约保留，`0xC8` 仍未映射。`0xCC CPU_DDR_CONTROL` 为写脉冲：bit0 申请、bit1 释放、bit2 清错误。`0xD0 CPU_DDR_STATUS`：bit0 会话有效、bit1 桥忙、bit2 会话错误、bit4 功能存在。`0xD4 CPU_DDR_ERROR` 报桥首个错误；1 权限/协议，3 下游 ID，4 下游响应，5 RLAST，6 CPU reset 中止。失败后不自动解除平台会话；CPU DDR 错误或会话错误未清除时禁止发布 Back。

## 已运行验证

| 检查 | 结果 | 范围 |
|---|---|---|
| `python scripts/run_m1a_checks.py` | 通过 | 真实生成 SoC upsizer 的地址/四 lane/读选择；桥的 AW/W 独立握手、背压、Front/越界拒绝、ID恢复与错 ID、RLAST 异常、reset 排空 |
| `python scripts/run_d_checks.py --apb-waits 1 --cpu-ddr` | 通过 | 会话排他、共用显示读/写准入、DDR 模型、故障后拒绝发布 Back、CPU 侧复位保持平台所有权、Swap 后像素扫描 |
| `python scripts/run_d_checks.py --apb-waits 1 --graphics --color-key` | 通过 | 既有 FILL/BLIT/Color Key、显示读优先、VBlank、HDMI 模型像素、无新增 underflow/missed |
| `python scripts/run_apb_checks.py` | 通过 | 旧 APB WAIT0/1/3 与 v4/v5 命令契约 |
| `python scripts/run_rgb_checks.py --quick` | 通过 | 旧 RGB/顶层端口展开 |
| `python scripts/build_apb_software.py --program m1a --opt O2 --output software/m1a_ddr_smoke/build` | 通过 | ELF PT_LOAD 全在 64 KB OCRAM，`_start=0xF9000000` |

表内是提交前已经运行的软件/仿真检查，不能单独替代实板结果。Icarus 无法运行包含厂商加密单元的完整 CPU 指令系统；upsizer 测试只抽取生成 RTL 中未修改的 `BmbUpSizerBridge` 模块。完整 CPU 指令到 DDR 的板级结果由负责人另行确认。

## Efinity 与产物证据

P3 的 Efinity 2026.1.132 `outflow/ti60f225_oob.info.log` 显示 `cpu_ddr_bridge`、`sapphire_control(CPU_DDR_ENABLE=1)` 和 `rgb_framebuffer(CPU_DDR_ENABLE=1)` 参与综合。`outflow/ti60f225_oob.timing.rpt` 的 core_clk 目标为 100 MHz，最大分析频率为 111.907 MHz；`outflow/ti60f225_oob.pgm.out` 记录了 bit 生成。下列哈希来自 2026-10-21 对现存 P3 文件的 SHA256 检查：

| P3 产物 | SHA256 |
|---|---|
| `outflow/ti60f225_oob.bit` | `F333E1F4BED2074773535D24BBB80ADC4C69B07DFC3A13853CC0386002ADCDF1` |
| `software/m1a_ddr_smoke/build/m1a_ddr_smoke.elf` | `E587FCB00855D7BE848F3F2CA8B3778ED59413D89C068C47C184AE39F3E16846` |

这些产物与相关源码、IP 配置及报告已独立复制到 `D:/Github_repositories/_phase3_baselines/m1a-precommit-20261021-f208dcc6/`，副本逐文件哈希相符。bit 和 ELF 都被 `.gitignore` 排除，不随提交迁移。bit 的文件时间为 2026-10-20 21:29，当前工程 XML 的最后修改时间为当日 23:28；目前也没有 M1a Git commit 或 Programmer 下载日志把此哈希与确切提交、板上配置逐一关联。因此不能把当前哈希写成已证明的提交产物；合并后须重新构建并记录新哈希。负责人确认验收通过，但完整运行时 CSR 读数、运行时长及所有显示计数原始记录尚未进入仓库。

## 已由负责人确认通过的板级验收与复验步骤

1. 在 **Efinity 2026.1** 打开目标检出目录的 `ti60f225_oob.xml`。确认 top `ti60f225_oob_top`、当前 `soc_control` 设置与 56 个设计源条目，特别是 `rtl/framebuffer/cpu_ddr_bridge.v`。GUI 曾自动把 XML 保存回 55 个条目；若再次发生，先停止 Compile 并恢复工程清单。执行完整 Compile，保存资源、时序和告警报告。
2. 在 Programmer 中仅下载本次 Compile 于目标检出目录生成的 `outflow/ti60f225_oob.bit`，记录路径、时间和 SHA256，不复用 P3 或 v5 旧 bit。确认 HDMI 首先持续显示初始化画面。
3. 关闭 Programmer 和旧 OpenOCD/GDB 后，在 RISC-V IDE 中复制现有 Titanium Hard JTAG Debug 配置，把 `bsp_loc`、两个 `-f`、寄存器描述、SVD、Main/Application、image 和 symbols 全部指向**目标检出目录**。使用本次生成的 `software/m1a_ddr_smoke/build/m1a_ddr_smoke.elf`，Startup PC 为 `f9000000`，禁用自动重建原 `apb_reg_test`。停在 `main`，然后连续运行至 `m1a_test_done`。本地绝对路径配置不属于通用 Git 提交。
4. 复验时查看 `g_m1a_result`：目标为 `pass=1`、`phase=6`、`error=0`、`writes=16384`、`reads=257`、`cpu_error=0`、`cpu_status` bit0/bit1 清零；Front/Back 先不同，Swap 后新 Front 等于原 Back。画面目标为深色 `0x102030` 背景，在 `(256,256)` 起出现 128×128 的绿色 `0x00E060` 方块。上述具体数值是软件验收判据；当前仓库没有这些值的原始板级截图。
5. 复验时记录 `underflow_before/after`、`missed_before/after`，稳定测试区间增量目标均为 0；同时检查 `ACCEL_READER_ERROR`、`ACCEL_ERROR_CODE`、`ACCEL_READER_AR_MAX_STALL`、`ACCEL_READER_R_MAX_STALL`、`ACCEL_WRITER_THROTTLE_CYCLES` 和 HDMI 连续性。重复运行与 CPU Debug/Reset 后检查 CPU 会话状态，并保存变量、bit/ELF 哈希和报告。

软件只使用有效 Front/Back 窗口。M1a 不加载独立 Sprite atlas、不声明 FPS，正式 CPU/FPGA 比较留待 M1b。
