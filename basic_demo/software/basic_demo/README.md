# basic_demo 软件工程

这是 `basic_demo` FPGA 工程的唯一 RISC-V IDE 应用，保留原 M2 的矩形运动、三张
640×480 图片切换、CPU/FPGA 渲染比较和 FPS HUD。应用直接编译本目录 `main.c`，
不再通过旧软件入口或 `DEMO_MODE` 切换。

## 目录与配置

- `main.c`、`scene.h`、`assets.h`、`metrics.h`、`render.h`：原 M2 应用。
- `accel_api.h`、`accel_regs.h`、`benchmark_clock.h`、`hud.h`：已迁入的必要依赖。
- `.project`、`.cproject`、`makefile`：IDE 工程和构建入口。
- `basic_demo_ti.launch`、`openocd/`：Titanium Hard JTAG 调试配置。
- `build.py`：直接构建本应用；默认 `-O2 -g3`，输出 `build/basic_demo.elf`。
- `tests/`：迁入的软件场景回归、项目合同和无硬件调试配置检查。

正式 BSP、启动汇编和链接脚本继续使用 `../../embedded_sw/soc_control/`。
源文件内的 `m2_*`、`g_m2_result`、HUD 内部的 `m1b_*` 名称保留，方便使用原调试变量，
不表示依赖任何旧软件目录。默认矩形数保持为 24；可修改 `scene.h` 的 `RECT_COUNT`
默认值，再在 IDE 中 Build；取值范围为 1～64。

本次改动仅限 `basic_demo/software/`。外部 `scripts/`、`sim/` 和根目录文档均保持原样，
其中仍有旧软件路径；旧软件构建、IDE 配置生成、软件测试和总检查入口可能失效。
本软件请使用下列新入口，尤其不要运行旧 `prepare_apb_ide.py` 或
`build_apb_software.py` 来配置、构建本工程。

清理过程中，旧软件源码已移除；由于自动审批拒绝磁盘删除命令，旧编译产物及空目录
集中移入本项目忽略的 `build/legacy_outputs/`，没有重新注册为 IDE 项目，构建和调试
均不依赖它们。软件根目录只有本 `basic_demo` 目录。需要彻底释放这部分磁盘空间时，
可在文件管理器中删除 `build/legacy_outputs/`。

2026-10-28 本地验证：旧入口和新独立入口以相同默认 24 矩形、`-O2` 参数重新构建，
生成 BIN 的 SHA256 完全一致：
`C558D8D5F398339D71593FCCD186A03B141BEBE55AE5B469F75699770814A56A`。
24/50 矩形 RV32 场景回归、项目/寄存器/IDE 一致性检查、实际 GDB 和无硬件 OpenOCD
解析检查均通过；旧目录迁出后，通过 Make 重新生成了全部应用产物。尚未操作 IDE
界面或连接开发板验收。

## 1. 命令行构建

在仓库根目录的 PowerShell 执行：

```powershell
Set-Location D:\Github_repositories\2026FPGA\basic_demo\software\basic_demo
python -B build.py
```

成功时显示 `PASS basic_demo`，输出 `build/basic_demo.elf` 以及 bin、hex、map、disasm。
脚本检查生成 SoC 的 ISA、DDR/APB 配置、全部 ELF LOAD 段和栈位置：
OCRAM 为 `0xF9000000` 起 64 KiB，程序和栈必须低于末尾 OpenOCD 工作区
`0xF900FC00`。继承的统一 RAM 链接脚本仍会产生 LOAD 段 RWX warning。

也可验证 IDE 实际调用的 Make 入口：

```powershell
& 'D:\Efinity\efinity-riscv-ide-2026.1\build_tools\bin\make.exe' all
```

如果 IDE 中找不到 Python，可在 C/C++ Build → Environment 中给 PATH 加入 Python
所在目录，或设置 `PYTHON` 环境变量为本机 `python.exe` 完整路径。
其他 IDE 安装位置可通过 `build.py --ide-root <目录>` 指定。
IDE 元数据和 OpenOCD 路径当前对应上述本机工程目录及 Efinity RISC-V IDE 2026.1；
移动仓库或 IDE 后，还需同步核对 `.project`、`.cproject`、Launch 和 `openocd/sapphire.cfg`。

仅用于单独构建负载变体的示例（不改变 IDE 默认 ELF）：

```powershell
python -B build.py --define RECT_COUNT=50 --output build/rect50
```

IDE 默认 Debug 固定加载 `build/basic_demo.elf`。如果希望 IDE 也使用 50 个矩形，
应修改 `scene.h` 中的默认值后 Build，避免下一次默认 Build 又覆盖命令行宏配置。

## 2. 无开发板检查

在本软件目录执行：

```powershell
python -B tests/check_project.py
python -B tests/check_debug.py
```

第一项检查现役硬件源条目、RTL/软件/文档寄存器合同、本地头文件依赖、唯一 IDE
工程，以及 Build/下载镜像/符号是否一致。第二项使用实际 GDB 和 OpenOCD 的 Tcl
解析器检查 PC、FTDI 配置和正式 `cpu0.yaml` 路径；硬件命令被替换，不连接开发板。
这两项不代表已完成 IDE 界面或实板验证。

可选：运行已迁入的原 M2 RV32 软件行为回归（需要 Unicorn 2.1.4）：

```powershell
python -m pip install --target build/test-deps unicorn==2.1.4
python -B tests/check_scene.py --unicorn-path build/test-deps
python -B tests/check_scene.py --unicorn-path build/test-deps --rect-count 50
```

检查 CPU/FPGA 任务一致性、双缓冲历史、运动边界、三张完整图片的软件复制、FPS、
五秒阶段边界和加速比。该回归没有真实 DDR、HDMI 或板级模型。

`python -B build.py --clean` 或 Make 的 `clean` 会清理整个本项目 `build/`，
包括其中的可选测试依赖；随后先重新 Build，需要时重新安装测试依赖。

## 3. RISC-V IDE 导入与调试

1. 结束已有调试会话。从旧 workspace 移除已失效的旧应用条目时，不勾选删除磁盘内容；
   也可新建一个 IDE workspace。
2. File → Import → General → Existing Projects into Workspace，选择
   `D:\Github_repositories\2026FPGA\basic_demo\software\basic_demo`。
   导入项目应显示为 `basic_demo`，不勾选 Copy projects into workspace。
3. 检查链接的 `bsp`、`common` 指向本 `basic_demo` 下的正式 `embedded_sw/soc_control`。
4. 右键 `basic_demo` → Build Project，确认 Console 运行 `build.py`、出现
   `PASS basic_demo`，并更新本目录 `build/basic_demo.elf`。
5. 打开 `basic_demo_ti.launch` 对应的 GDB OpenOCD Debugging 配置；如未自动出现，
   可右键该 Launch 文件，通过 Debug As 启动。核对：

   | 配置 | 应有值 |
   |---|---|
   | Project | `basic_demo` |
   | Application | `build/basic_demo.elf` |
   | Image / Symbols | 均为本工程 `build/basic_demo.elf` |
   | Build before launch | 已显式启用 |
   | Startup PC | `f9000000`，不额外加 `0x` |
   | Stop at | `main` |
   | OpenOCD 配置 | 本目录 `openocd/ftdi_ti.cfg`、`openocd/debug_ti.cfg` |

6. 确保 FPGA 已加载本 `basic_demo` 的 M2 硬件配置。已有匹配配置时，无需因软件改名
   重新 Generate IP；若重新上电需要下载，使用本工程的匹配 bit，不能使用其他 demo 的 bit。
   关闭占用 FTDI 的 Programmer 或旧 OpenOCD/GDB，再启动 `basic_demo_ti`。
7. 在 `main` 停住，确认源文件为本目录 `main.c`，然后 Resume。计时期间不要暂停或单步。

## 4. 实板验收

1. HDMI 应先完成素材初始化，随后不断循环：矩形 CPU → 矩形 FPGA → 图片 CPU →
   图片 FPGA。每阶段从首帧安全呈现后至少运行五秒，CPU 渲染慢时实际等待会更长。
2. 观察移动矩形、三张图片切换、CPU Render FPS、FPGA Render FPS 和 Hardware Speedup。
   默认 24 个矩形；图片区域保持 640×480。初始缺少样本时 HUD 显示 WAIT 属正常行为。
3. 设置 `m2_error_stop` 故障断点；如命中，记录 `g_m2_result`，不要把停在这里视作成功。
   如需一次完整四阶段后的数值，在启动前设置 `m2_cycle_boundary` 断点。
4. 完整一轮后检查 `g_m2_result.cycle >= 1`、`error == 0`、`reader_error == 0`、
   `cpu_error == 0`、`underflow_delta == 0`、`missed_delta == 0`。
   四组 `metric[scene][mode][0]` 应取得有效 FPS；矩形最初两帧的过渡成本另在 class 1。
5. 首次装载时 `asset_rows_written == asset_rows_verified == 1440`，三组
   `asset_hash[i] == asset_verify_hash[i]`，`asset_status` 的 READY 位为 1。
   仅重新启动 CPU Debug、未复位 FPGA 时，READY 可保留；此时只校验已封存图片，
   `asset_rows_written` 为 0、`asset_rows_verified` 为 1440 属预期行为。
6. 再次结束并启动同一个 `basic_demo_ti`，确认无需先运行任何旧软件，仍可完成四阶段循环。
   继续观察多轮时移除周期断点，检查显示稳定和错误增量为零。

后续故障定位可继续使用 `g_m2_result`、`m2_error_stop` 和 `m2_cycle_boundary`。
Render FPS 与 HDMI 刷新率、实际换帧速率分别计量，不应混用。
