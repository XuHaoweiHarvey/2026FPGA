# 2026FPGA 最终交付工程

基于 Efinix Ti60F225、Sapphire RISC-V 和 FPGA 二维图形加速器，保留基础演示、PixelForge 正式游戏和 LUNARIA 压力测试。

## 目录

| 目录 | 内容 |
|---|---|
| `basic_demo/` | CPU/FPGA 渲染对比的硬件工程、软件源码和基础版交付文件 |
| `starry_demo/` | PixelForge 与 LUNARIA 压力测试、共享硬件/软件源码及素材 |
| [docs/](docs/README.md) | 集中维护的架构、寄存器、构建、性能、验收和实板证据 |
| `docs_reference/` | 比赛要求和开发板参考资料 |

## 可以直接取得的运行文件

| 演示 | FPGA 配置 | RISC-V 程序与素材 |
|---|---|---|
| 基础版 | `basic_demo/delivery/ti60f225_oob.bit` | `basic_demo/delivery/basic_demo.elf`，图片编入程序 |
| PixelForge | `starry_demo/advanced_demo/delivery/PixelForge/ti60f225_oob.bit` | 同目录 `PixelForge.elf`、`assets.json`、`atlas.argb`、`background.argb` |
| LUNARIA 压力测试 | `starry_demo/advanced_demo/delivery/lunaria_stress/ti60f225_oob.bit` | 同目录 `lunaria.elf`、`assets.json`、`atlas.argb`、`background.argb` |

以上交付文件随 Git 提交。`build/`、`outflow/` 和 `work_*` 仍作为本地编译输出，
不需要取消它们的忽略规则。请使用对应目录的一整套文件，基础版和游戏版不能混用。

### 基础版

详见 [交付说明](basic_demo/delivery/README.md) 和 [软件工程说明](basic_demo/software/basic_demo/README.md)。

1. 使用 Efinity Programmer 加载基础版交付目录中的 bit，完成后退出 Programmer。
2. RISC-V IDE 导入 `basic_demo/software/basic_demo`。现有 IDE/OpenOCD 元数据使用
   `D:/Github_repositories/2026FPGA` 和 `D:/Efinity/efinity-riscv-ide-2026.1`；
   如果克隆目录或工具位置不同，按软件说明调整路径。
3. 可直接选择 `basic_demo/delivery/basic_demo.elf` 调试，或从源码 Build 后使用
   `basic_demo/software/basic_demo/build/basic_demo.elf`。Application、Image、Symbols
   必须选择同一个 ELF；直接使用交付文件时关闭启动前自动 Build。
4. Resume 后观察矩形运动、三张图片切换、CPU/FPGA Render FPS 和加速比。

本次重新编译的软件通过 LOAD 段/栈范围检查及 24/50 矩形 RV32 场景回归，
BIN 与原等效 M2 构建的归档 SHA256 一致。基础版 bit 沿用 2026-10-24 的现有产物；
本次没有重新执行 FPGA 编译或连接开发板复验。详细输入、工具版本和校验和见交付目录。

### PixelForge 与压力测试

1. 使用 Efinity Programmer 加载对应交付目录的 bit，然后退出 Programmer。
2. 双击 `starry_demo/start_PixelForge.cmd` 或 `starry_demo/start_lunaria_stress.cmd`。
3. 选择正确串口，连接并加载，等待 ELF 与素材上传/校验完成。

需要 Python 3 + Tkinter，以及 Efinity RISC-V IDE 的调试工具。
启动器会检测 Python；路径检测失败时，将 `starry_demo/paths.local.cmd.example`
复制为 `paths.local.cmd` 并设置本机路径。该本机配置不随 Git 提交。

玩法、操作和验证范围以 [PixelForge 说明](starry_demo/advanced_demo/docs/PIXELFORGE.md)
及 [压力测试说明](starry_demo/advanced_demo/docs/LUNARIA_STRESS.md) 为准。
同名说明也在各交付目录内。高级版只保留 PixelForge 和压力测试两个交付模式，
共用构建素材位于 `starry_demo/advanced_demo/design/game_assets`。

## 从源码构建

- 基础软件：在 `basic_demo/software/basic_demo` 中执行
  `python -B build.py --ide-root <本机Efinity-RISC-V-IDE目录>`。
- 基础硬件：在 Efinity 中打开 `basic_demo/ti60f225_oob.xml`。
- PixelForge 软件：构建入口是 `starry_demo/advanced_demo/scripts/build_pixelforge.py`，
  使用 `design/game_assets` 的共用素材和压力版 v13 bit；工具链位置见该脚本及游戏说明。
- 压力版软件：在 `starry_demo/advanced_demo` 中执行
  `python -B scripts/build_lunaria_stress.py`，默认复用已记录的 v13 bit。
- 游戏 v13 硬件：`starry_demo/prepare_hardware.cmd` 准备
  `starry_demo/advanced_demo/output/game_hardware_v13` 工程，随后可在 Efinity 完整 Compile，
  再用 `scripts/build_lunaria_stress.py --hardware package` 校验时序和打包。
  直接演示使用随包保留的 v13 bit；共享工程的默认参数不代表最终 v13 配置。

## Git 同步与比赛打包

队友首次下载使用 `git clone`；已有仓库在自己的改动处理完后使用 `git pull --ff-only`。
克隆后应能直接找到上表的 bit、ELF 和素材。源码更新后，本地重新编译不会自动更新
`delivery/`，需要同步更新交付文件及其校验记录。

比赛压缩包使用本仓库根目录，排除隐藏的 `.git` 版本历史目录。
普通 ZIP 打包不读取 `.gitignore`；保留各级工程配置、素材、交付文件和文档。
公共说明统一从 [docs/README.md](docs/README.md) 查阅；`starry_demo/docs/` 只保留导航。
历史实板证据集中在 `docs/evidence/`，适用版本与计量范围见性能和验收说明。
