# 项目文档导航

公共技术资料统一保存在本目录。构建和运行以当前交付目录为准；历史截图与数据集中在 `evidence/`，保留原始文件供复核。

| 文档 | 用途 |
|---|---|
| [构建与运行](BUILD.md) | 当前基础版、PixelForge、压力测试的入口和产物配对 |
| [系统架构与接口](ARCHITECTURE.md) | 时钟、像素格式、地址、CPU DDR 会话、双缓冲与复位 |
| [基础版寄存器表](REGISTER_MAP.md) | 基础版 APB 全部寄存器、错误码、清除规则 |
| [绘图与 DDR 协议](GRAPHICS_ENGINE.md) | FILL、BLIT、色键、源保护、读仲裁和显示写保护 |
| [性能口径与历史实测](BENCHMARK.md) | Render/Presented FPS 定义、v5/M2/旧游戏数据与适用范围 |
| [验证与验收](VALIDATION.md) | 当前检查入口、实板通过条件、历史验证和证据限制 |
| [故障排查](TROUBLESHOOTING.md) | 黑屏、换帧、JTAG、IDE 路径和启动问题 |

## 当前演示资料

- 基础版：[交付文件](../basic_demo/delivery/README.md)、[软件工程与 IDE](../basic_demo/software/basic_demo/README.md)。
- 高级版：[PixelForge](../starry_demo/advanced_demo/docs/PIXELFORGE.md)、[LUNARIA 压力测试](../starry_demo/advanced_demo/docs/LUNARIA_STRESS.md)、[高级版寄存器](../starry_demo/advanced_demo/docs/REGISTER_MAP.md)。
- Flash：[交付操作](../starry_demo/advanced_demo/docs/FLASH_DELIVERY.md)、[验证记录](../starry_demo/advanced_demo/docs/FLASH_VALIDATION.md)。
- 比赛与开发板原始资料：[docs_reference](../docs_reference/)。

本目录中的基础硬件合同对应 `basic_demo/` 的 v5/M2 接口；高级版的 v13、Alpha、命令队列及游戏专用寄存器以其独立文档为准。

## 精简后的资料归属

| 原资料类型 | 合并位置 |
|---|---|
| ARCHITECTURE、INTERFACES、M1A_CPU_DDR 的接口部分 | ARCHITECTURE；寄存器细节仍在 REGISTER_MAP |
| BLIT、COLOR_KEY、SYSTEM_BLIT、BLIT_SOURCE_GUARD、DDR_READ_ARBITER | GRAPHICS_ENGINE |
| BENCHMARK、V5_BOARD_BENCHMARK、M1B/M2 的性能部分 | BENCHMARK |
| VALIDATION、M1A/M1B/M2 验收、V5_TIMING_FIX、集成验收清单 | VALIDATION |
| 两份 evidence | 本目录 evidence，图片与 JSON 只保留一套 |

旧分工表、路线图、集成计划、CPU 接入草案、M1a 寄存器快照和早期 Flash 调研已移除；其有效合同已纳入上述文档，Flash 操作指向现役交付说明。历史版本仍可通过 Git 查阅。
