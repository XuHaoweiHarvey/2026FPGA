# 验证与实板验收

本页区分当前复验步骤、既有本机检查和历史实板证据。仿真、ELF 构建、Efinity 时序、板上运行各证明不同范围；任何一项通过都不能代替其他项。当前启动和构建见 [BUILD](BUILD.md)，原始实测见 [BENCHMARK](BENCHMARK.md)。

## 当前基础版复验

使用 [基础交付目录](../basic_demo/delivery/README.md) 的匹配 bit/ELF，或记录新构建的 SHA256。导入唯一软件项目 `basic_demo/software/basic_demo`；应用不再靠 DEMO_MODE 选择。

1. 运行后观察矩形 CPU → 矩形 FPGA → 图片 CPU → 图片 FPGA 的四阶段循环，HUD 显示场景、模式和 Render FPS。阶段从首帧实际 Swap 起至少 5 秒；缺少对照样本时 WAIT 正常。
2. 完整一轮可在 `m2_cycle_boundary` 暂停：`g_m2_result.cycle>=1`、`error=reader_error=cpu_error=0`，四组稳态 `metric[scene][mode][0]` 有效，underflow/missed 增量为 0。首两帧清理的 class 1 单独检查。
3. 首次装载应写入并读回 1440 行，三组 asset hash 一致，ASSET_STATUS READY=1。只重启 CPU 时 READY 可保留，此时写入 0 行、校验 1440 行为预期。
4. 设置 `m2_error_stop` 故障断点；命中时记录 phase/error、CPU/reader/asset 状态、front/back、command/swap 增量和素材 expected/actual，不作为成功停止。
5. 移除周期断点连续运行多轮，确认运动和三图切换正确、绘制期间旧 Front 稳定、安全换帧、无明显花屏/撕裂/重新同步；记录实际持续时间及最终计数。再结束并重启 Debug 验证无旧软件依赖。

计时中不能暂停、单步或持续大量 JTAG 读取。调试取样时停止的结果与连续运行记录分别保存。完整 IDE 操作和变量见 [软件说明](../basic_demo/software/basic_demo/README.md)。

## 当前无开发板检查

在 `basic_demo/software/basic_demo` 执行：

```powershell
python -B tests/check_project.py
python -B tests/check_debug.py
# 可选：已有 Unicorn 2.1.4 时执行 RV32 软件场景回归
python -B tests/check_scene.py --unicorn-path build/test-deps
python -B tests/check_scene.py --unicorn-path build/test-deps --rect-count 50
```

project 检查活动 design entries、RTL/header/本文档的寄存器一致性、唯一 IDE 工程和加载文件；debug 检查真实 GDB/Jim 解析，硬件命令用 mock，不连接板。scene 执行真实 RV32 软件并模拟外设行为，覆盖任务一致性、双槽历史、图片复制、FPS 和阶段边界，不模拟真实 DDR/HDMI。检查依赖/工具配置见软件 README。

硬件模块回归从 `basic_demo` 运行，需 Icarus 或对应脚本要求的模拟器：

```powershell
python -B scripts/run_apb_checks.py
python -B scripts/run_m1a_checks.py
python -B scripts/run_c_checks.py --full-init
python -B scripts/run_d_checks.py --apb-waits 0 1 3 --graphics --color-key
python -B scripts/run_d_checks.py --apb-waits 1 --cpu-ddr
```

旧 `scripts/check_project.py`、软件构建/IDE 生成和部分软件 runner 仍引用已移除的 `software/apb_reg_test`；当前软件应使用上面的 `tests/` 入口，不能把旧入口失败当成新软件构建结论。以上命令是后续复验入口，本次文档整理没有重新执行全部历史回归。

## 已记录验证范围

| 范围 | 历史记录与边界 |
|---|---|
| RGB/APB/FILL | WAIT 0/1/3，字节/像素序、非对齐边缘、4 KiB、反压、错误、初始化最后 B 屏障；独立模型不执行加密 PHY |
| BLIT/色键 | 源窗口、地址跨度/4 GiB 边界、完整像素比较、透明 WSTRB、AW/AR 背压、错误排空、故障保持所有权 |
| 双缓冲/显示共享读 | 安全读帧/flush、VS 边界、owner 路由；v5 系统 WAIT 0/1/3 各 6 swaps、42 完整帧、1,407,777 次像素比较，稳定 underflow/missed 增量 0 |
| 显示保护压力 | 1920×1080、原 reader/FIFO/CVO，四组累计 248,832,000 最终像素；WAIT 0/1/3 及较严 R/B 延迟下 writer 进展、underflow/missed 增量 0 |
| M1a CPU DDR | 真实生成 upsizer 四 lane、CPU 桥独立 AW/W、背压/ID/响应/RLAST、reset 排空、会话排他、Front/越界拒绝与 Swap |
| M1b/M2 软件 | 相同任务 CPU/FPGA、读回、计时边界、指标 class、错误停止；后来迁入现役基础应用 |
| 2026-11-03 基础交付 | RV32IM GCC 13.4、O2 软件重建及 LOAD/栈检查；24/50 矩形 RV32 回归通过，未重编 FPGA/未上板 |

显示压力模型中约 130～52 MB/s 是模型握手得到的吞吐，最严 R 等待 422 core cycles；不属于板上性能或 DDR 最坏延迟保证。关闭写保护的负对照曾在 FIFO=0 时产生欠载，属于预期失败。详细原始板级性能保存在 [BENCHMARK](BENCHMARK.md)，不与模型数值混写。

## 历史时序修复与构建证据

2026-10-19 的 BLIT 源结束地址检查将乘法、加法和范围判断串在一拍，core 建立裕量为 -0.331 ns。拆成四拍检查后，启动增加 3 个 100 MHz 周期（30 ns），DMA burst、寄存器与完成合同不变。

| v5 Efinity 2026.1.132 指标 | 修复前 | 修复后 |
|---|---:|---:|
| core_clk 建立裕量 | -0.331 ns | +1.449 ns |
| core 分析最高频率 | 96.796 MHz | 116.945 MHz |
| 全部已分析关系最差建立裕量 | -0.331 ns | +0.417 ns |
| 最差保持裕量 | +0.027 ns | +0.026 ns |
| XLR / Memory / DSP | 27940 / 141 / 15 | 28001 / 141 / 12 |

实际 core 仍为 100 MHz，估算频率不等于改频后的实板验证。历史接口有未用 MIPI/JTAG/DDR 高地址等 Missing Interface Pins、`pll_inst4_RSTN` 未分配和外围/组合环告警；正裕量不能替代逐项审查或板测。这些是历史报告，当前交付结果以其配套报告为准。

M1a 独立 P3 工程曾报告 core 分析频率 111.907 MHz；2026-10-21 记录的产物身份：

| 历史产物 | SHA256 |
|---|---|
| M1a bit | `F333E1F4BED2074773535D24BBB80ADC4C69B07DFC3A13853CC0386002ADCDF1` |
| M1a smoke ELF | `E587FCB00855D7BE848F3F2CA8B3778ED59413D89C068C47C184AE39F3E16846` |

当时没有下载日志把这些哈希与确切 Git 提交及板上配置逐一关联；原个人盘备份也不是仓库可复现输入。保留身份记录，不将其误当当前基础版交付哈希。现役基础产物见 [build-info](../basic_demo/delivery/build-info.json) 与 [校验和](../basic_demo/delivery/SHA256SUMS.txt)。

## 历史实板验收与证据边界

| 版本 | 已有结论 / 证据 | 未由原始资料证明的范围 |
|---|---|---|
| 早期 A～E | 负责人确认基础显示、APB、FILL、显示保护、最终演示通过 | 完整逐阶段哈希/时长/CSR 未全部归档 |
| M1a（2026-10-21 反馈） | 负责人确认 CPU→DDR 烟测通过 | 不是 FPS 对比；原始诊断快照不足 |
| M1b | 负责人确认功能基线；软件对照与计时已实现 | 无独立完整性能数据包 |
| M2（2026-10-22 反馈） | 负责人反馈通过，5 张视频截图及 HUD 读数保留 | 本次加载哈希、错误增量、完整阶段时长缺失 |
| v5 固定工作量 | 3 轮全屏 case 截图；首轮有完整 summary | 后两轮总 pass 和其他 9 cases 数据未提供 |
| 旧居中游戏 | 60 秒 30 FPS 截图与人工摘录 | 不代表现役 PixelForge/压力版或完整错误验收 |

历史 M1a 烟测判据为 128×128 绿色块、16384 writes、257 reads、pass=1/phase=6/error=0；这些是原软件标准，当前应用不再包含该独立入口。恢复历史版本时通过 Git 检出配套源码和产物，不把旧 ELF 加到现役软件目录。

## 高级版验证

当前高级版只交付 PixelForge 与压力测试。各自的本地逻辑、RV32、加载器及 Alpha RTL 验证、上板条件和未测项目分别保留在 [PIXELFORGE](../starry_demo/advanced_demo/docs/PIXELFORGE.md) 和 [LUNARIA_STRESS](../starry_demo/advanced_demo/docs/LUNARIA_STRESS.md)。1024/2048 是容量；局部优化、历史参考成绩不证明本次构建稳定 60 FPS。

## 重新交付时保留的记录

记录源码提交、工具版本、最终资源/时序报告、bit/ELF/素材 SHA256、实际加载文件、场景/负载/预热/时长、初始/最终/增量诊断，以及截图或视频。故障时保存原始状态再恢复；不通过 CPU reset、清计数、强制 Swap 或取消在途 AXI 掩盖错误。RWX linker warning 和工具继承告警应按实际报告记录，仿真不能证明物理校准或时序。
