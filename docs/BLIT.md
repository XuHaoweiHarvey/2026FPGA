# BLIT 独立原型

## 当前状态

2026-10-19更新：本模块已由统一入口接入正式v5系统；将源结束地址检查分拍后通过100MHz静态时序，BLIT单元49场景及负对照通过。下面关于“独立原型/未集成”的描述保留首版开发背景；当前状态及保留告警见[V5_TIMING_FIX](V5_TIMING_FIX.md)。

`blit_engine.v` 是 Person B 的第一版图像块复制执行单元。它已经通过 Icarus Verilog 单元仿真，覆盖 32×32 棋盘复制、不同源 stride、长行分段、源/目标 4 KiB 边界、VALID/READY 停顿、响应错误、超时排空和参数快照。

这次提交是独立 RTL 原型。它还没有接入 APB 命令、正式 DDR 读服务、显示仲裁、换帧或 HDMI，因此不能把本次仿真结果当作实板 BLIT 已完成。

后续已增加 [FILL/BLIT 统一执行入口](GRAPHICS_ENGINE.md)，完成两类命令交替、统一状态和混合场景仿真；仍属于独立验证，正式系统连接待 A/C 对接。

## 仓库文件

| 文件 | 用途 |
|---|---|
| `rtl/accelerator/blit_engine.v` | BLIT 状态机、二维地址计算、分段读写和错误处理 |
| `sim/tb_blit_engine.v` | 模拟源/目标内存、AXI 激励、独立像素记分板 |
| `scripts/run_blit_checks.ps1` | 编译、运行三组仿真和负向记分板检查 |
| `scripts/render_blit_preview.py` | 将仿真导出的 P3 PPM 转成 PNG 预览 |

仿真输出位于 `output/blit/`，已加入 `.gitignore`，不提交生成的 VVP、VCD、日志和图片。

## 运行

需要把 Icarus Verilog 的 `iverilog` 和 `vvp` 加入 PATH。PNG 预览可选使用 Python 3，只依赖标准库；runner依次探测 `py -3`、`python`、`python3`，跳过无法启动的快捷方式。未找到可运行的 Python 时，RTL 检查和 PPM 导出仍会执行，PNG 转换会提示跳过。也可以通过 `-PythonExe` 指定实际的 Python 3 可执行文件。

在团队仓库根目录执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_blit_checks.ps1
```

只运行检查而不生成波形：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_blit_checks.ps1 -NoWave
```

成功时会看到四组 `PASS BLIT`、负向记分板检查通过以及 `PASS all BLIT unit simulations`。第四组为32位源地址空间顶部检查（7场景）。启用 Python 转换时，基础棋盘预览在 `output/blit/basic/checker_target_6x.png`。

输出由脚本重新生成：`output/blit/blit.log` 是完整运行日志，`output/blit/basic/blit.vcd` 是默认波形，`scoreboard_expected_failure.log` 保存负对照的预期错误。装有 GTKWave 时，可在仓库根目录用 `gtkwave .\output\blit\basic\blit.vcd` 查看波形。

2026-10-17 复验：basic 32用例、boundaries 5用例、single_beat_buffer 5用例，共42个用例通过；另通过一次故意改坏像素的负对照。

## 第一版约定

- XRGB8888，每像素 4 字节；128 位数据总线每拍 4 个像素。
- `src_addr` 为32位绝对源字节地址，`src_stride` 为源图相邻行首的字节距离；目标坐标使用 `dst_x`、`dst_y`，单位像素。
- 源地址和源 stride 为16字节对齐；目标 x 和宽度为4像素的倍数；源 stride 至少为 `width*4` 字节。
- 每次只执行一条命令；启动时快照参数；每段最多 32 beats，读写 burst 不跨 4 KiB。
- 本原型输出相对 Back 的写地址，Back 基地址由集成 wrapper 只加一次。
- 暂不支持透明、缩放、旋转、裁剪、重叠搬移、命令队列和正式源图加载。

源和目标必须位于有效、不重叠的内存区域；本原型不自行校验正式系统的资源窗口和物理重叠。模块默认画面参数为1920×1080、目标stride7680字节；测试脚本使用小画布加快验证。

## 命令、状态与地址

`start` 为单周期请求，仅在 `enabled=1` 且空闲时接收。模块锁存 `src_addr/src_stride/dst_x/dst_y/width/height`；忙时不接收第二条命令。`command_count` 每接收一次命令加一，包含非法参数命令。`done` 保持到下一条命令被接收或平台复位；成功需同时满足 `done=1`、`busy=0`、`error_code=0`，且最后一笔写响应已经成功。

```text
源地址 = src_addr + row*src_stride + col*4
目标相对地址 = (dst_y+row)*FRAME_STRIDE + (dst_x+col)*4
```

棋盘用例为32×32、源stride128、目标画布64×48、目标stride256、位置(8,5)。首个AR地址为 `0x01000000`，首个相对AW地址为 `0x520`；testbench在接线层加模拟Back base `0x00800000`，得到 `0x00800520`。源地址只是仿真窗口，并非团队正式源图分区。

AXI端口沿用简化形式；ID0、SIZE4、INCR、CACHE3、PROT2、LOCK0、QOS0等固定sideband由集成层补齐。读完一段后再写出，最多一笔在途burst。缓存为32×128位，`WR_LOAD`按时钟读出缓存后进入`WR_DATA`，第一版未做连续逐拍写入或读写重叠优化。

| 原型错误码 | 含义 |
|---|---|
| `0x00` | 无错误 |
| `0x21` | 参数非法 |
| `0x22` | RRESP/RID错误 |
| `0x23` | BRESP/BID错误 |
| `0x24` | 无进展超时 |
| `0x25` | RLAST/内部状态异常，进入FAULT |

以上错误码尚未加入团队寄存器表。超时不撤回已经提出的VALID，BUSY持续到事务排空；永久不响应的从设备可能使BUSY持续保持。错误不保证目标内容回滚。早到或缺失RLAST进入FAULT，保持BUSY并等待平台复位；CPU/debug reset不能用于取消在途平台事务。

## 集成前必须共同确认

下一轮的参数表、DDR读写服务建议、Front→Back最小Demo和A/B/C确认事项见 [BLIT第一轮集成对接草案](BLIT_INTEGRATION.md)。该文件是待讨论方案，尚未改变正式寄存器或接线。

A 负责确定新增命令字段、软件 API、源图资源加载和错误码；C 负责 BLIT 读服务与 Display Reader 的 AR/R 仲裁、响应路由、Back ownership 和显示保护。当前不能把本模块的读端口直接并接到正式 DDR，也不能单方面修改寄存器表或顶层工程源清单。集成后需要保留 FILL_RECT 回归，并补做 Efinity 综合、资源/时序检查和实板显示验证。
