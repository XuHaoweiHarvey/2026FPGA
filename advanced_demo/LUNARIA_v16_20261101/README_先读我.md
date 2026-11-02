# LUNARIA v16 队友交接包

整理日期：2026-11-01。版本：v16-tile-compositor，硬件版本 0x00100000。

上传整个文件夹，或上传同名 ZIP。队友先完整解压，再运行程序。

## 文件位置

- runtime/：原 v16 运行交付包，含 FPGA bit、lunaria.elf、素材、PC 预览 DLL、调试工具、使用说明和验证记录。
- source/advanced_demo/：开发工程源码，含 RTL、软件、IP、BSP、约束、素材、脚本和仿真。
- source/v16_hardware/：生成本版 bit 时使用的硬件工程快照，已启用 v16 参数。重建本版硬件请打开此目录的 ti60f225_oob.xml。
- checks/：原交付检查结果与本次复制校验结果。
- SHA256SUMS.txt：本次交接包全部文件的 SHA-256 清单。

## 运行

电脑预览：进入 runtime，双击 start_preview.cmd。

上板：先在 Efinity Programmer 配置 runtime/hardware/v16/ti60f225_oob.bit，退出 Programmer，然后运行 runtime/start_debug.cmd，连接并加载本包 lunaria.elf 和 assets.json。详细操作见 runtime/使用说明.md。

环境为 Windows x64、Efinity 2026.1.132 和 Efinity RISC-V IDE 2026.1。预览使用带 Tk 的 64 位 Python 3.11 与随包 DLL。

原启动脚本的 Python 路径为 D:\Efinity\python311；队友安装位置不同时，请修改 runtime/start_debug.cmd 和 runtime/start_preview.cmd 中的 PYTHONHOME。调试窗口中的“RISC-V IDE”目录也要改为队友本机目录。启动脚本按原交付版本保留，修改后对应的校验值会变化。

已有可用 64 位 Python/Tk 时，也可在 runtime 目录执行：

```powershell
py -3 -B tools/lunaria_pc.py --folder .
py -3 -B tools/lunaria_debug_window.py --elf lunaria.elf --assets assets.json
```

## 源码与重建

阅读游戏逻辑可从 source/advanced_demo/software/lunaria/ 开始；分块合成 RTL 位于 rtl/accelerator/tiled_graphics_engine.v。版本设计与验证边界见 docs/LUNARIA_DDR_V16.md。

source/advanced_demo 的顶层工程保留开发基线默认参数。需要直接重建已启用 v16 的硬件时，使用 source/v16_hardware/ti60f225_oob.xml；其 source_manifest.json 保留原编译输入的哈希。

Efinity 编译时会去掉工程 XML 末尾换行。本包硬件快照恢复了该换行，使工程 XML 与原编译输入的哈希一致；其余硬件输入按原样复制。

重建固件可在 source/advanced_demo 目录运行以下命令，将 IDE 路径改成本机实际位置：

```powershell
py -3 -B scripts/build_lunaria.py --ide-root D:/Efinity/efinity-riscv-ide-2026.1
```

固件构建需要的原始二进制素材已放入 source/advanced_demo/output/lunaria/。重新生成素材需要 Pillow 和所需字体；重建 PC DLL 需要 MSVC；仿真需要相应编译器及 Icarus Verilog。重建硬件需已安装并授权的 Efinity。

本包保留 v16 编译输入、运行产物和验证记录，清除了大型综合/布局布线工作目录和 Python 缓存。历史版本交付目录、历史测试输出和板端测量数据未重复复制，因此依赖这些历史产物的全量打包/回归脚本需要另外准备相应数据。

## 已有验证状态

原版编译、时序与仿真记录随包提供。本次核对原交付包全部 139 个文件、复制后的软件/硬件源码哈希、工程文件引用，并完成复制位置的 ELF/素材/DLL 离线检查。

v16 尚未完成真实板卡 FPS、长期运行和 EA05 故障恢复验收。完整结果及限制见 runtime/使用说明.md。本次整理未连接板卡。
