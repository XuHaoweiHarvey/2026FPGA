# LUNARIA 星空版：队友运行与修改工程

版本固定为 GitHub 提交 **6f021a8（星空版低配）**。本文件夹包含该版完整的高级 FPGA 工程、RISC-V 游戏源码、BSP/IP、原始素材、脚本，以及配套 v10/v11 bit、ELF 和素材数据。此版本默认敌弹上限 256，可调范围 64–512。

## 第一次使用

1. 克隆或拉取本 GitHub 仓库，然后进入 **starry_demo/**。保留目录结构；建议把整个仓库放在短的英文路径。
2. 安装 Efinity 2026.1.132、Efinity RISC-V IDE 2026.1 及对应板卡 USB 驱动。程序用于 Ti60F225 开发板，需要 JTAG、UART 和 HDMI。Python 3 需要 Tkinter；可用 Efinity 自带 Python。
3. 双击 **check_package.cmd** 检查文件完整性。启动脚本会寻找 Python；工具安装在其他位置时，将 **paths.local.cmd.example** 复制为 **paths.local.cmd**，按本机安装位置填写。只需在这个配置文件里设置路径。
4. 打开 Efinity Programmer，通过 JTAG 临时配置 **advanced_demo/delivery/lunaria/hardware/v11/ti60f225_oob.bit**，然后退出 Programmer。v11 将 640×480 游戏放大到 1280×960；想保留居中 640×480 显示可选同目录下的 v10。两者均输出 1920×1080 HDMI。
5. 双击根目录 **start_lunaria.cmd**。确认窗口中的“RISC-V IDE”是本机安装目录，点击“连接 / 读取”，再点击“加载并运行 ELF”。它会下载程序并校验、上传约 2.46 MB 背景和图集；首次上传需要等待几分钟。
6. 在窗口中选择板卡 UART 对应的 COM 口，点击“开始发送”。WASD / 方向键移动，空格 / Ctrl 射击，P 暂停。标题页按射击开始。COM 口由队友电脑分配，不需要修改源代码。

更换素材或从其他游戏切换到本版时，先重新配置匹配的 bit，再加载 ELF 和素材。只通过 IDE 下载 ELF 不会完成图片上传，需使用本包的星空调试窗口。

## 修改代码与重新编译

在编辑器中打开整个文件夹。RISC-V IDE 也可以通过 Import > Existing Projects into Workspace 导入 **advanced_demo/software/lunaria**，项目名为 lunaria，不要勾选把项目复制到 workspace。该项目使用本包的统一构建入口。

| 内容 | 路径 |
|---|---|
| 游戏入口、主循环、板端调试接口 | advanced_demo/software/lunaria/main.c |
| 弹幕、碰撞、阶段、数量与参数 | advanced_demo/software/lunaria/lunaria.c、lunaria.h |
| 绘制逻辑 | advanced_demo/software/lunaria/lunaria_render.c |
| 原始 PNG 素材 | advanced_demo/design/lunaria_preview/assets/ |
| 素材打包 | advanced_demo/scripts/prepare_lunaria_assets.py |
| 调试窗口、素材加载器 | advanced_demo/tools/lunaria_debug_window.py、lunaria_debug_bridge.py |
| RTL 与约束 | advanced_demo/rtl/、advanced_demo/constraints/ |
| SoC IP 与 BSP | advanced_demo/ip/、advanced_demo/embedded_sw/ |
| 配套可运行文件 | advanced_demo/delivery/lunaria/ |

只改 C 代码后，双击根目录 **rebuild_lunaria.cmd**。它会根据本机 RISC-V IDE 工具链重新构建，并把新的 ELF 和配套素材更新到 delivery/lunaria/。之后重新打开 start_lunaria.cmd，加载新 ELF。普通软件修改不需要重编 FPGA。

修改 PNG 后，在本文件夹中打开终端运行：

    rebuild_lunaria.cmd --prepare-assets

重新生成素材需要当前 Python 安装 Pillow，并有 Windows 自带字体。直接运行或只修改 C 时不需要 Pillow。更改精灵位置/尺寸需要同时更新素材布局和 lunaria_render.c，然后重新配置 bit、加载新 ELF 和素材。

## 修改 FPGA 硬件

advanced_demo/ti60f225_oob.xml 是保留的通用基线，顶层默认没有开启星空版所用的窗口/缓存参数。为避免编译出错误的基线 bit，修改 advanced_demo/rtl/、约束或 IP 后，双击根目录 **prepare_hardware.cmd**，再在 Efinity 中打开：

    advanced_demo/output/lunaria_hardware_v11/ti60f225_oob.xml

准备命令会复制本包内的硬件源码并启用 v11 的窗口、两倍显示、Alpha 流水与缓存参数。v10 可运行 prepare_hardware.cmd --variant v10。随后由 Efinity Compile 产生新的 bit，手动下载该项目的 outflow/ti60f225_oob.bit。重新准备会刷新生成目录，因此长期修改请写在 advanced_demo/rtl/ 等源目录中。

## 版本与验证

本包已重新生成与 6f021a8 源码一致的素材，并在独立目录中重新编译 RISC-V ELF。工程依赖、ELF/素材匹配、加载器离线检查及文件 SHA-256 结果见 **SHARE_VERIFICATION.json** 和 **SHA256SUMS.txt**。实际板卡运行与 FPS 尚需上板验证。

docs/ 和 advanced_demo/docs/ 保留了历史说明；涉及本次共享包的路径与操作以此文件为准。advanced_demo/delivery/lunaria/hardware/ 下的 original_manifest.json 是已有 bit 的历史构建记录，其中的飞机版 ELF 名称属于硬件来源记录。星空版实际加载的是 advanced_demo/delivery/lunaria/lunaria.elf。

## GitHub 共同开发

此目录已经位于现有 Git 仓库中。你们共同修改 **starry_demo/advanced_demo/** 内的源码，不需要下载 ZIP，也不要与仓库外层 advanced_demo 的其他版本混用。

每人创建自己的功能分支。在仓库根目录执行，分支名按实际功能替换：

    git switch -c feature/your-change
    git add -- starry_demo
    git commit -m "修改星空版功能"
    git push -u origin feature/your-change

然后在 GitHub 创建 Pull Request，检查后合并到 main；其他成员先保存自己的改动，再执行 git pull --ff-only 同步 main。不要用强制推送覆盖队友提交。

本目录自带 .gitignore，继续排除 output/、编译缓存和本机 paths.local.cmd。**advanced_demo/delivery/lunaria/ 不被忽略**，必要的 bit、ELF 和素材可以随源码一起提交。修改代码后运行 rebuild_lunaria.cmd 会更新这个目录的 ELF 和配套素材；把修改的源码与同次构建文件一起提交。

每个人只在自己的 paths.local.cmd 中设置工具安装路径，这个文件不会提交。串口 COM 号在窗口选择；项目内部路径由脚本定位，不需要改成各自电脑的绝对路径。不要提交工具安装目录、IDE workspace、work_syn/、work_pnr/。
