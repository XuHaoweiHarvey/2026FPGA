# v6 Alpha 高级演示上板验证表

本表用于第一次在 Ti60F225 板卡上验证 v6 Alpha 演示。当前 FPGA 工程和 ELF 已完成仿真、软件构建及 Efinity 完整编译，但尚无实体板卡结果。测试时只使用下面配套的构建产物，不要和 M2 或其他版本混搭。

## 配套文件

- FPGA 配置文件：`advanced_demo/output/efinity_alpha/ti60f225_oob.bit`
- CPU 程序：`advanced_demo/output/toolchain/advanced/advanced_demo.elf`
- 板卡目标：Efinix Titanium Ti60F225
- 画面时序：工程输出 1920×1080；显示器可自行缩放
- 当前演示无需按键、拨码或串口输入

## 开始前记录

| 项目 | 记录 |
|---|---|
| 日期 / 操作者 | |
| 板卡完整型号与 PCB 修订号 | |
| Efinity Programmer / RISC-V IDE 版本 | |
| HDMI 显示器型号及输入口 | |
| 实际加载的 bit 路径 | |
| 实际加载的 ELF 路径 | |

检查板卡型号与 `.bit` 目标一致，板卡供电稳定，JTAG 连接正常，HDMI 接到正确的显示器输入。保留可回退的 M2 版本文件，不要覆盖 `basic_demo`。

## 加载顺序

1. 打开 Efinity Programmer，连接 Ti60F225 JTAG，加载上面的 `ti60f225_oob.bit` 并执行 FPGA 配置。首次测试用 JTAG 临时配置，不写 SPI Flash。
2. 配置完成后关闭 Programmer，避免它与调试器同时占用 JTAG。
3. 在 Efinity RISC-V IDE 中导入 `advanced_demo/software/apb_reg_test` 工程，并创建/复制 Ti60F225 的 OpenOCD Debug Configuration。将 image 和 symbols 都指向上面的 `advanced_demo.elf`，保留该工程配套的 OpenOCD/JTAG 参数，并启用 Load image。
4. 启动调试。若 CPU 停在 `main`，按 **Resume / F8** 继续执行。该 ELF 通过 JTAG 下载到 CPU OCRAM；不要把它交给 FPGA Programmer。
5. 等待初始化和素材生成完成，再连续观察至少 30 秒。程序每约 4 秒切换一次 CPU 与 FPGA 渲染阶段，因此 30 秒足以看到多轮交替。

注意：仓库里的 `apb_reg_test_ti.launch` 是 APB/M2 调试配置模板，检查它最终加载的 image 路径，确认已改为高级版 ELF；不要因为配置名字相似就直接运行旧 M2 ELF。

## 通过标准

- HDMI 出现稳定、完整的演示画面，能看出复制、洋红色 Color Key 和渐变 Alpha 光斑效果；光斑透明度自动变化。
- 画面阶段标签在 `CPU REFERENCE RENDER` 与 `FPGA BLIT AND ALPHA` 间交替，HUD 中 CPU/FPGA Render FPS 均出现有效非零值。
- 在调试器 Expressions/Watch 中观察 `g_advanced_result`：`error == 0`、`phase == 7`（RUNNING）、`mode` 在 0 与 1 间变化。
- `underflow_delta == 0`、`missed_delta == 0`；`swap_delta` 和 `stage_presents[0/1]` 随运行增加。
- `render_fps_x100[]` 与 `present_fps_x100[]` 按百分之一 FPS 记录。例如 `1234` 表示 `12.34 FPS`。记录 CPU、FPGA 两种 Render FPS，以及画面显示的 Presented FPS。

调试器查看变量时若需要暂停 CPU，先暂停读取，再 Resume；暂停期间画面可能停在当前帧，不要把这个人为暂停记成运行故障。FPS 字段分别对应 CPU 与 FPGA 模式，`mode=0` 是 CPU 参考渲染，`mode=1` 是 FPGA 加速渲染。

| 观测项 | CPU 阶段 | FPGA 阶段 / 总体 |
|---|---:|---:|
| Render FPS | | |
| Presented FPS | | |
| `error` / `phase` | | |
| `underflow_delta` / `missed_delta` | | |
| `swap_delta` / `stage_presents` | | |
| 视觉效果 / 连续性 | | |

## 异常时记录与初步定位

发生问题先记录现象，不要马上改 RTL 或反复重刷不同版本。保存屏幕照片（若方便）、调试器截图、Programmer/OpenOCD 报错原文，并填写：症状首次出现时间、`phase`、`mode`、`error`、`last_error_code`、`asset_status`、`sprite_status`、`cpu_ddr_status/error`、`underflow_delta`、`missed_delta`、`reader_error`、`swap_delta`。

| 现象 | 优先检查 |
|---|---|
| Programmer 找不到板卡/JTAG | 确认供电、USB-JTAG 线和 Ti60F225 目标；关闭占用 JTAG 的 IDE/OpenOCD 会话后重试连接。 |
| `.bit` 配置失败 | 确认选的是 `advanced_demo/output/efinity_alpha/ti60f225_oob.bit`，器件为 Ti60F225，并使用 JTAG 配置流程；保存 Programmer 原始日志。 |
| ELF 启动后无画面 | 检查显示器输入和 HDMI 线、是否加载了配套 bit、是否按 F8 Resume；记录 `phase/error/last_error_code`。 |
| `phase` 停在 1–3 | 初始化或素材阶段尚未完成/失败；记录 asset/sprite/CPU DDR 状态及 `error`。首次填充素材需一些时间。 |
| `phase == 255` 或 `error != 0` | 记录 `last_error_code` 与所有状态字段；对照 [寄存器错误码说明](REGISTER_MAP.md#diagnostics-and-software-observation)，不要仅清错误后继续当作通过。 |
| 画面撕裂、闪烁或间歇黑屏 | 查看 underflow/missed 增量、`reader_error`、`swap_delta`；同时确认运行中没有暂停 CPU。 |
| 看不到 CPU/FPGA 阶段切换 | 连续运行超过 10 秒，确认 `mode` 和 `cycle` 是否变化；检查调试器是否仍停在断点。 |
| 画面正常但 FPS 为 0 | 继续观察至少数秒，让统计窗口更新；随后记录 `render_metric[0/1].valid/frames` 及 FPS 字段。 |

**结论：** ☐ 通过，可进入互动功能设计　☐ 有问题，按上表附记录回归　☐ 暂停，板卡/连接条件未具备

