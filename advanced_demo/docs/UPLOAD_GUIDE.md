# 本次 GitHub 上传说明

> 后续合并说明：本页原来的 20 文件清单对应本地提交 `4b12941`，已完成提交。
> 随后拉取了远端 Flash 功能提交 `1496f8b`，产生 3 个游戏源码冲突。
> 合并应保留两边功能及远端已跟踪的源码、IP/BSP、Flash 文档和验证记录；
> 不要再按旧清单把这些合并内容取消暂存，也不要重新执行 pull。
> `docs/evidence/flash_20261024/` 的日志是远端有意保存的验证材料，属于本次合并内容，
> 与本机临时日志不同。4 个 `basic_demo` 未提交配置改动仍保留在本机，不纳入合并提交。
> 完成合并后刷新 GitHub Desktop，按 Push origin 上传合并后的本地提交即可。

本说明对应 2026-10-24 的常驻调试与弹幕扩展，建议作为阶段性开发版本提交。
实际仓库根目录是 `C:\Users\Xuhaowei\Desktop\2026FPGA\2026FPGA`，当前分支为 `main`。
以下步骤保留为首次上传时的操作记录；后续合并应按上面的说明处理。

## 可直接复制的提交说明

标题：

```text
advanced_demo：增加常驻调试与弹幕扩展，修复背景跳变
```

正文（可用于 GitHub Desktop 的 Description、PR 或版本说明）：

```text
在现有高级工程上增加常驻游戏调试功能，首次加载 ELF 后可重开、暂停、调参，
并提供 FILL / Color Key / Alpha 自测及独立 60 秒性能测量入口。

增加敌方瞄准弹、扇形弹、波次和自动重开；启动时统一初始化两个完整显示缓冲，
修复局部游戏区域外背景随双缓冲交换反复跳变的问题。

改进桌面串口选择：自动枚举有效 COM、发送期间锁定端口，分别显示电脑发送状态
与板端接收快照，避免误以为切换下拉选项就切换了实际发送端口。

本版没有修改硬件 RTL。主机游戏逻辑、UART 协议、固件 mock 回归已通过；
桌面调试检查 18 项及 OpenOCD 配置离线检查通过。
用户已反馈游戏正常显示、背景跳变已解决。键盘实际接收、板上自测结果和
持续 60 FPS 尚未完成验证，本提交为阶段性版本。
```

## 本次可以上传什么

| 类型 | 本次纳入的内容 |
|---|---|
| 游戏源码 | `game_main.c`、`game_logic.c/.h`、`game_debug_abi.h` |
| 桌面调试工具 | `game_debug_bridge.py`、`game_debug_window.py`、`start_game_debug.cmd` |
| 构建与回归 | 构建脚本、游戏逻辑/调试检查脚本、C mock 与测试用例、回归入口 |
| 上板准备工具 | `prepare_board_package.py`、`refresh_board_debug.py`；它们是工具源码，不是编译产物 |
| 使用文档 | README、常驻调试说明、上板操作说明、本上传说明 |

这些文件需要一起提交。只传 ELF 或只传 `game_main.c`，不能完整复现这一版。
已有并受版本管理的 RTL、约束、IP 配置和 BSP 继续保留；不要因它们由工具生成就从仓库删除。
本次没有对这些高级硬件文件作修改，无需人为加入新的改动。

## 本次不纳入什么

| 文件或目录 | 处理方式与原因 |
|---|---|
| `basic_demo/software/apb_reg_test/.cproject` | 暂不纳入；属于基础工程 IDE 配置的独立改动 |
| `basic_demo/software/apb_reg_test/.project` | 暂不纳入；属于基础工程项目链接的独立改动 |
| `basic_demo/software/apb_reg_test/apb_reg_test_ti.launch` | 暂不纳入；属于基础工程调试配置的独立改动 |
| `basic_demo/ti60f225_oob.xml` | 暂不纳入；基础工程项目文件变化需另行核对 |
| `advanced_demo/outflow/`、`work_syn/`、`work_pnr/`、`work_pt/`、`work_dbg/`、`ooc/` | 编译输出、缓存和工作目录，正常 Git 提交不包含 |
| `advanced_demo/software/*/build/` | ELF、BIN、HEX、目标文件和反汇编等构建产物，不强制加入源码提交 |
| `advanced_demo/output/` | 本机封存包、ZIP、测试临时文件，正常 Git 提交不包含 |
| IDE workspace 的 `.metadata/`、Python `__pycache__/`、临时日志 | 留在本机；有价值的验证结果可整理成文档再上传 |
| 工具安装目录、驱动安装包、个人凭据、原始聊天截图 | 不属于这次源码提交；公开图片或日志前检查其中的个人信息 |

“暂不纳入基础工程改动”不等于删除或撤销它们；这些变化继续保留在本机，后续可以单独提交。
`.project`、`.cproject`、`.launch` 和 `.xml` 也不是一概禁止上传，只是上面这四个改动不属于本次范围。
不要用 `git add .` 或 `git add -f` 把它们和本地构建输出混入此次提交。

## 按清单提交到 GitHub

在 PowerShell 中先执行下面这段。它只选择这次相关的 20 个文件，包括本说明：

```powershell
Set-Location 'C:\Users\Xuhaowei\Desktop\2026FPGA\2026FPGA'

git status --short
git diff --cached --name-only

$uploadFiles = @(
    'advanced_demo/README.md'
    'advanced_demo/docs/BOARD_READY_GUIDE.md'
    'advanced_demo/docs/RESIDENT_GAME_DEBUG.md'
    'advanced_demo/docs/UPLOAD_GUIDE.md'
    'advanced_demo/scripts/build_apb_software.py'
    'advanced_demo/scripts/prepare_board_package.py'
    'advanced_demo/scripts/refresh_board_debug.py'
    'advanced_demo/scripts/run_game_debug_checks.py'
    'advanced_demo/scripts/run_game_logic_checks.py'
    'advanced_demo/scripts/run_interactive_checks.cmd'
    'advanced_demo/sim/mock_game/accel_api.h'
    'advanced_demo/sim/test_game_debug_control.c'
    'advanced_demo/sim/test_survival_game.c'
    'advanced_demo/software/interactive_demo/game_debug_abi.h'
    'advanced_demo/software/interactive_demo/game_logic.c'
    'advanced_demo/software/interactive_demo/game_logic.h'
    'advanced_demo/software/interactive_demo/game_main.c'
    'advanced_demo/start_game_debug.cmd'
    'advanced_demo/tools/game_debug_bridge.py'
    'advanced_demo/tools/game_debug_window.py'
)

git add -- $uploadFiles
git diff --cached --stat
git diff --cached --name-only
git diff --cached --check
```

当前检查时暂存区为空。若执行时第一条 `git diff --cached --name-only` 已显示其他文件，
先核对它们，避免一次提交带上之前暂存的内容。暂存后的清单应只有上面的文件。
如果基础工程文件已被暂存，可按实际路径执行 `git restore --staged -- 文件路径`，
只取消暂存，保留本机修改。

核对清单与检查结果后，再执行提交和推送：

```powershell
git commit -m 'advanced_demo：增加常驻调试与弹幕扩展，修复背景跳变'
git push origin main
```

每条命令成功后再执行下一条。推送若提示远端有新提交，应先获取并检查差异，
不要强制推送。使用 GitHub Desktop 时同样按上面的清单勾选，填写标题与正文，
点击 Commit，再 Push origin；四个基础工程文件保持未勾选。

## 如果还要给队友可直接运行的文件

Git 源码提交不会上传被忽略的 bit/ELF。需要免编译演示时，另行制作经过核对的
ZIP，作为 GitHub Release 附件或队内共享文件，而不是把整个输出目录强制加入 Git。

包内至少需要兼容的 advanced UART/Alpha/Color Key v6 bit、最新游戏 ELF、
当前调试窗口/桥接工具/键盘发送工具、相应配置和使用说明，并记录源码提交号、
硬件版本、软件版本与 SHA-256。电脑工具安装路径也需要接收方核对。

旧 `output/board_ready/advanced_uart_20261023_e99e4e6/` 属于历史版本，
不会随源码修改自动更新，不能当作本次常驻调试版发送。
现有 `prepare_board_package.py` 主要生成 IDE 加载用的包，当前复制清单尚未包含
`game_debug_window.py`、`game_debug_bridge.py` 和 `start_game_debug.cmd`；
单独运行它不能得到完整的新版常驻调试工具包。

本次可立即上传源码阶段版本；最终验收包应在实际 UART、板上自测和持续性能数据
确认后，再保存对应的程序、说明与验证记录。
