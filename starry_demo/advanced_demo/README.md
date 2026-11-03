# 高级版：PixelForge 与 LUNARIA 压力测试

高级版只交付两个模式：

| 模式 | 上一级启动脚本 | 本目录交付包 |
|---|---|---|
| 正式游戏 PixelForge / 像素熔炉 | `start_PixelForge.cmd` | `delivery/PixelForge` |
| 8×8 敌弹压力测试 | `start_lunaria_stress.cmd` | `delivery/lunaria_stress` |

在 Efinity Programmer 加载对应交付目录的 `ti60f225_oob.bit`，退出 Programmer，
然后运行启动脚本，连接并加载 ELF 与素材。两个模式共用 v13 bit，ELF 与图集各自配套。
切换模式时重新配置 bit，以清除之前封存的素材。

正式游戏操作见 [PIXELFORGE](docs/PIXELFORGE.md)，压力测试见 [LUNARIA_STRESS](docs/LUNARIA_STRESS.md)。
本机工具路径由上一级 `paths.local.cmd` 设置；示例文件是 `paths.local.cmd.example`。

## 重新构建

在本目录执行，需 Python/Pillow、Windows 字体及 Efinity RISC-V 工具链：

```powershell
python -B scripts/build_pixelforge.py
python -B scripts/build_lunaria_stress.py
```

两个构建命令只使用 `design/game_assets` 中的基础素材和已保留的 v13 硬件交付记录，
不再依赖旧模式的交付包。`--ide-root` 可指定本机工具链，`--output` 可指定独立验证输出目录。
共享源码目录继续叫 `software/lunaria`，并由编译宏区分正式游戏和压力版。
其中的协议、渲染、图集工具及基准回归由两个模式共同使用。

如需重编硬件，运行上一级 `prepare_hardware.cmd`，在 Efinity 打开
`output/game_hardware_v13/ti60f225_oob.xml` 并完整 Compile，随后执行：

```powershell
python -B scripts/build_lunaria_stress.py --hardware package
```

默认根工程的参数不同于 v13；直接演示请使用交付包中的 bit。

## 验证

```powershell
python -B scripts/run_lunaria_loader_checks.py
# 在已初始化 MSVC 且提供 Icarus Verilog 的终端：
python -B scripts/run_pixelforge_checks.py
python -B scripts/run_lunaria_stress_checks.py
```

仿真、软件测试和加载器离线检查不会替代开发板验收。
`docs` 中其他开发记录包含历史版本信息，当前演示以两个最终版说明为准。
