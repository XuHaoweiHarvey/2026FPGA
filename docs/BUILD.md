# 构建与运行

当前保留三项演示：基础 CPU/FPGA 对比、PixelForge、LUNARIA 压力测试。旧 Mode 0～5、M1a/M1b 独立软件目录已不作为最终演示入口。所有命令以下表的目录为准，不再使用旧 `build_apb_software.py` 配置当前基础软件。

## 直接演示

| 演示 | FPGA 配置 | CPU 程序与素材 | 操作说明 |
|---|---|---|---|
| 基础版 | `basic_demo/delivery/ti60f225_oob.bit` | 同目录 `basic_demo.elf`，图片由程序生成 | [交付说明](../basic_demo/delivery/README.md) |
| PixelForge | `starry_demo/advanced_demo/delivery/PixelForge/ti60f225_oob.bit` | 同目录 `PixelForge.elf` 和完整素材 | [游戏说明](../starry_demo/advanced_demo/docs/PIXELFORGE.md) |
| 压力测试 | `starry_demo/advanced_demo/delivery/lunaria_stress/ti60f225_oob.bit` | 同目录 `lunaria.elf` 和完整素材 | [压力测试说明](../starry_demo/advanced_demo/docs/LUNARIA_STRESS.md) |

用 Efinity Programmer 加载对应 bit，完成后退出 Programmer，释放 JTAG/FTDI。基础版使用 RISC-V IDE 的 Titanium Hard JTAG；游戏双击 [start_PixelForge.cmd](../starry_demo/start_PixelForge.cmd) 或 [start_lunaria_stress.cmd](../starry_demo/start_lunaria_stress.cmd)，选择正确串口并连接/加载。

两款游戏共享 v13 硬件，但 ELF 和图集须配套；从一种游戏切换到另一种时重新配置 bit，清除旧的封存素材后完整上传。基础版与高级版不能混用 bit/ELF。

启动器需要 Python 3、Tkinter 和 Efinity RISC-V IDE 调试工具；从源码重建游戏还需要 Pillow。自动检测路径失败时，复制 [paths.local.cmd.example](../starry_demo/paths.local.cmd.example) 为同目录 `paths.local.cmd`，填写本机 Efinity、IDE、Python 路径。该本机配置被 Git 忽略。

## 基础软件重建与 IDE

在仓库根目录执行：

```powershell
Set-Location basic_demo/software/basic_demo
python -B build.py --ide-root 'D:\Efinity\efinity-riscv-ide-2026.1'
```

输出为本软件目录的 `build/basic_demo.elf`，同时生成 BIN、MAP 等；默认 24 个矩形。独立构建 50 个矩形可加 `--define RECT_COUNT=50 --output build/rect50`。CPU/FPGA 必须使用相同数量。IDE 固定加载默认 build 时，修改 `scene.h` 默认值后 Build，防止下次默认构建覆盖变体。

RISC-V IDE 导入 [software/basic_demo](../basic_demo/software/basic_demo/README.md)，不要勾选 Copy projects into workspace。核对 BSP/common 链接、include、Launch 和 OpenOCD 实际路径；现存配置中的 `D:/Github_repositories/2026FPGA` 需要随本机位置调整。Application、Image、Symbols 三处必须指向同一个 ELF；Startup PC 填 `f9000000`。

自行重编译时使用本项目 `build/basic_demo.elf` 并启用启动前 Build；直接使用 delivery ELF 时关闭自动 Build，避免加载另一份程序。程序在 `0xF9000000` 的 64 KiB OCRAM 内运行，末 1 KiB 留给 OpenOCD。完整导入、调试变量和检查入口见软件 README。

## 基础硬件重建

在 Efinity 2026.1 打开 [basic_demo/ti60f225_oob.xml](../basic_demo/ti60f225_oob.xml)，从 Synthesis 完整运行到 Bitstream，检查最终 timing/place 报告，下载该次生成的 `basic_demo/outflow/ti60f225_oob.bit`。

现有 Sapphire 配置、生成 RTL、ROM/BSP 和外围工程均已保留，正常检出不需要重新 Generate IP。不要重复注册 IP 生成源码或导入其他整板示例覆盖外围配置。修改 RTL 才需要重新编译 FPGA；只改软件参数通常只重建 ELF。

当前 delivery 基础 bit 沿用 2026-10-24 产物，软件已于 2026-11-03 重编译；具体来源和校验见 [build-info.json](../basic_demo/delivery/build-info.json) 与 [SHA256SUMS](../basic_demo/delivery/SHA256SUMS.txt)。这次文档整理不代表重编 FPGA 或完成新一轮实板测试。

## 游戏重建

从仓库根目录进入高级工程：

```powershell
Set-Location starry_demo/advanced_demo
python -B scripts/build_pixelforge.py
python -B scripts/build_lunaria_stress.py
```

默认输出各自 delivery 目录，读取 `design/game_assets` 共用源素材，复用已记录哈希的 v13 bit。需要独立输出时用 `--output <目录>`；工具链路径用 `--ide-root <目录>`。构建与验证参数以 [PixelForge](../starry_demo/advanced_demo/docs/PIXELFORGE.md) 和 [压力测试](../starry_demo/advanced_demo/docs/LUNARIA_STRESS.md) 为准。

完整游戏硬件重建先运行 [prepare_hardware.cmd](../starry_demo/prepare_hardware.cmd)，在 Efinity 打开生成的 `starry_demo/advanced_demo/output/game_hardware_v13/ti60f225_oob.xml` 完整 Compile，再在高级工程执行 `python -B scripts/build_lunaria_stress.py --hardware package` 校验并打包。共享工程默认参数不等于最终 v13 配置，不直接拿默认工程产物替换游戏交付。

## Git 与比赛打包

`build/`、`output/`、`outflow/`、`work_*/`、仿真缓存和本机 IDE workspace 都是可重建输出；保留忽略规则。随 Git 交付的可运行文件集中在 delivery，不能因为是编译产物就删除。源码重编不会自动更新所有 delivery，重新发布需同步 ELF/bit/素材、manifest 和校验记录。

比赛 ZIP 使用仓库根目录，排除 `.git` 历史和本地缓存，保留工程、IP/BSP、源码、素材、delivery、公共说明及验收证据。普通 ZIP 不读取 `.gitignore`，压缩前需确认内容。无板检查与实板条件见 [VALIDATION](VALIDATION.md)。
