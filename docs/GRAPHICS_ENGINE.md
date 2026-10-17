# B：FILL / BLIT 统一执行入口

## 这一步完成什么

对应赛题二基础要求第1项：硬件根据操作类型执行 Solid Fill 或 Block Copy。`graphics_engine.v` 在 B 内部接收一条命令，保存参数，选择现有 `fill_rect_writer` 或 `blit_engine`，并提供一套公共状态和写接口。

当前 B 执行层已按 2026-10-17 用户提供的 A/C 反馈适配，经过独立仿真及与现有 `buffer_manager` 的合同测试。正式系统仍只接 FILL，尚未接入新增 APB 字段、C 的源窗口检查器/DDR 读仲裁/显示，也未加入 Efinity 工程、综合或上板。已确定的下一轮接口及各方实施状态见 [BLIT_INTEGRATION](BLIT_INTEGRATION.md)。

```text
仿真命令（未来由 A 提供）
          ↓
    graphics_engine
       ↙       ↘
 fill_rect    blit
       ↘       ↙
  相对 Back 的 AW/W/B；BLIT 另有绝对源地址的 AR/R
          ↓
模拟内存（未来由 C 提供 DDR 服务并加一次 Back base）
```

## 文件和复现

| 文件 | 用途 |
|---|---|
| `rtl/accelerator/graphics_engine.v` | 命令快照、选择、总线复用和公共结果 |
| `sim/tb_graphics_engine.v` | 混合场景、像素记分板、状态/错误/超时验证 |
| `sim/tb_graphics_contract.v` | 连接现有真实 manager，检查接收计数、Back 释放、错误换帧阻止和 FAULT；源检查结果和 DDR 由模型提供 |
| `sim/tb_blit_engine.v` | 复用其中的 `blit_test_memory`；新增可选 byte strobe 支持，BLIT 默认仍要求全 strobe |
| `scripts/run_graphics_checks.ps1` | 两组像素仿真、manager 合同测试、负对照、可选波形和 PNG |
| `scripts/render_blit_preview.py` | 共用 PPM→PNG 转换，新增可选 `--names`，原 BLIT 调用方式保留 |

需要 PATH 中的 `iverilog`、`vvp`。在仓库根目录执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_graphics_checks.ps1
```

使用 `-NoWave` 可跳过 VCD。Python 3 只用于 PNG，脚本探测 `py -3`、`python`、`python3`；未找到时仍执行 RTL 检查并导出 PPM。也可以明确指定解释器：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_graphics_checks.ps1 -PythonExe 'C:\实际安装位置\python.exe'
```

结果写入 `output/graphics/`，已忽略，不提交生成物。主要输出为：

| 输出 | 内容 |
|---|---|
| `graphics.log` | 完整运行记录 |
| `basic/graphics.vcd` | 默认配置的波形，可用 GTKWave 打开 |
| `basic/checker_source_6x.png` | 32×32 源棋盘 |
| `basic/01_fill_6x.png` | 64×48 画布填为深蓝色 |
| `basic/02_blit_6x.png` | 源棋盘复制至 `(8,5)`，大小32×32 |
| `basic/03_overlay_6x.png` | 再在 `(11,12)` 填13×5红色矩形，验证 FILL 非对齐边缘 |
| `scoreboard_expected_failure.log` | 故意写坏像素后，记分板应当拒绝的负对照 |

同名 PPM 和原尺寸 PNG 也会生成。图片来自仿真实际目标内存；6倍放大便于查看。它不是 HDMI 截图，正确性由逐像素比较决定。

## 命令和状态规则

端口同属 `clk` 域。`rst_n` 是平台复位，不能接成通过 CPU/debug reset 取消 DMA。

| 输入 | 含义 |
|---|---|
| `start` | 接 manager 最终产生的一拍 `command_accept`，不能直接接原始 APB 请求 |
| `enabled` | 平台接收使能，最终 accept 时必须为1；不用于中途取消 |
| `op[31:0]` | 团队编码0=FILL、1=BLIT；参数 `OP_FILL/OP_BLIT` 仅用于复用/测试配置 |
| `x/y/width/height[31:0]` | 目标位置和矩形大小，单位像素 |
| `color[31:0]` | FILL 的 XRGB8888 颜色，BLIT 不使用 |
| `src_addr[31:0]` | BLIT 绝对源字节地址，FILL 不使用 |
| `src_stride[31:0]` | BLIT 源行距，单位字节，FILL 不使用 |
| `src_range_valid` | C 用最终 accept 的参数/Front 检查后锁存的结果；B 在下一拍 `CHECK_SOURCE` 采样；FILL 忽略 |

`accept` 是 B 的组合输出，表示本拍 `rst_n && start && enabled && !busy`，不是另一根启动输入。集成时应让它与 manager 的 `command_accept` 一致，可用于观察/断言，不能回接参与生成同一个 manager accept 而形成组合环。忙时请求不排队，disabled 请求不清结果/计数。

接受命令当拍锁存参数和操作选择、清旧结果并增加公共计数。FILL 顺序为 `IDLE → LAUNCH → RUN → IDLE`，BLIT 为 `IDLE → CHECK_SOURCE → LAUNCH → RUN → IDLE`。`LAUNCH` 只启动一次子模块；`RUN` 才采集结果，隔离旧 sticky DONE。

### C 范围结果的时序

| core 上升沿 | 行为 |
|---|---|
| T：最终 accept | B 锁存 op/矩形/源参数并计数，C 锁存 Back base 和本条命令的源范围结果 |
| T+1：CHECK_SOURCE | B 读取并保存 C 在 T 生成的 `src_range_valid`；0则返回0x21并结束，不启动 BLIT |
| T+2：LAUNCH | 仅源范围有效的 BLIT 启动子模块；后续外部参数变化不影响本条命令 |

C 必须在 T+1 采样边沿前提供正确的结果，并在 B 采样前保持，不能多延迟一拍；按方案在 T 用寄存器锁存即可。B 不能在 T 读取该寄存输出，否则会误取上一条命令结果。测试中的 C 模型正是在 accept 边沿更新寄存结果，交替覆盖有效/无效命令。

集成端口示例：`.start(command_accept), .accept(b_accept), .op(cmd_op), .x(cmd_x), .src_addr(cmd_src_addr), .src_range_valid(c_src_range_valid)`。A/C 上层可保留 `cmd_*` 网络名，B 公开端口使用团队约定的无前缀名称。此示例不代表正式顶层已接线。

| 输出 | 规则 |
|---|---|
| `accept` | 本拍实际接收事件；非法 opcode/源范围也接收并计数 |
| `busy` | 从接受有效操作类型的命令起，覆盖启动、读、写、排空，直到子模块结束；FAULT 时保持 |
| `done` | 本条命令已结束，成功/失败都可能置1；保持到下一次接受或平台复位 |
| `error_code` | 运行时也透出当前单元的错误，包括排空期间的超时和 FAULT；结束后保持 |
| `command_count` | 每次公共入口接受加1，含非法操作/参数；子模块局部计数不用于此输出 |

非法操作类型计数并立即返回 `done=1/busy=0/error=0x26`，不启动子模块、不访问 AXI；优先于 BLIT 源范围错误。`src_range_valid=0` 的 BLIT 仍计数，在 CHECK_SOURCE 返回 `done=1/busy=0/error=0x21`，不启动子模块、不发 AR/AW。两类错误都让现有 manager 按普通结束释放 Back，不能简单压住 accept。非法 FILL 几何可能在子模块启动当拍就结束，入口仍正确采集结果。

错误保持到下一条**实际被接收**的命令或平台复位；普通寄存器参数改写、失败的 START、CPU/debug reset、CONTROL.bit1 都不能通过此入口清除它。软件当前遇错停止，下一条命令清除只是硬件语义。`enabled` 拉低或外部参数变化不会停止在途事务。成功条件仍为 `done=1 && busy=0 && error_code=0`，平台还需等待 `WRITER_OWNED=0`。

FILL 固定使用 `SETTLE_FRAMES=0`，与现有双缓冲正式模式一致：完成表示内存操作结束，呈现由后续显式 swap 决定，不等待两帧显示。

## AXI、地址和错误

一条命令内保持同一个执行单元占有公共 AW/W/B，并只向该单元交付 READY/BVALID。BLIT AR/R 也只在它执行时开放。选择不依赖外部 `cmd_op` 的后续变化；两个子模块的 DONE/ERROR 不直接 OR。

- 保留 XRGB8888、128bit数据、32bit字节地址、最多32beats且不跨4KiB、每次一笔在途 burst。
- `araddr` 是绝对源地址；`awaddr` 是相对 Back 偏移。C 将来在接收命令时锁存 Back，并只加一次 base，保持其4KiB对齐。
- sideband 沿用现有约定，由集成层补齐；需要保留 C 的写准入和显示保护。
- FILL 支持任意像素 x/width 与边缘 WSTRB；BLIT 仍要求源地址/stride16字节对齐、x/width为4像素倍数。
- Front 范围和首轮 `src_stride=7680` 的检查由 C 完成，并通过 `src_range_valid` 交付；B 不自行推断 Front，也不能在正式系统把该信号绑1绕过检查。B 子模块保留原有通用对齐/尺寸/stride/溢出检查。
- C 需限制源地址在锁存 Front 的有效 `0x7E9000` 字节内，按 offset/7680 推导源坐标，并检查源矩形不横向跨行、宽高非零且不越界，扩展位宽防溢出。8MiB 槽剩余空间不是有效图像。实际检查器不在本轮 B RTL 中。
- 入口不实现 DDR 读仲裁、swap、命令队列或资源加载。C 的读 owner 必须按预期拍数与 RLAST 双重检查；异常 RLAST 不得直接释放 owner。Back ownership 与读 burst owner 是两套状态。

按 A/C 本轮方案使用以下错误码，正式 APB 的 ERROR_CODE 映射仍待 A/C 集成：

| 错误码 | 含义 |
|---|---|
| `0x11/0x12/0x13` | FILL 参数/写响应/超时 |
| `0x21/0x22/0x23/0x24/0x25` | BLIT 参数/读响应/写响应/超时/协议故障 |
| `0x26` | 公共入口不认识操作类型；`ERR_OPCODE` 参数默认值已从原型0x31改为0x26 |

超时不撤销 VALID，保持公共 BUSY 和选择，服务恢复后排空当前事务再结束；永久不响应时不能安全报告完成。错误可能已部分更新目标，不提供回滚。BLIT RLAST 异常保持 FAULT/BUSY，阻止后续命令，等待平台复位。

默认 `WATCHDOG_BITS=27`，core100MHz 下约1.34秒连续无 AXI 握手会超时，任意本命令通道握手重置计时。C 的最大仲裁等待仍未实测，需确保不会因饥饿超过此限制。测试用9位watchdog验证排空，不构成实际 DDR 服务上限证明。共享读通道发生协议FAULT后，不能承诺HDMI继续正常供数。

## 已验证范围与后续

2026-10-17：默认32beat配置43用例、单拍缓存并改为操作编码7/9的配置42用例，加现有真实 manager 的7个合同用例，共92个用例通过；单拍burst不存在“提前末拍”，因此跳过早到RLAST用例。另有一次错误像素负对照，通过确认记分板确实能发现错误。

覆盖 FILL→BLIT→FILL、同类连续命令、非对齐FILL、参数/操作快照、enabled只控制接受、旧DONE/ERROR隔离、公共accept与计数一致、忙时拒绝请求、非法操作/参数、最后B前不完成、反压稳定、R/B响应错误、两种单元的超时排空及BLIT协议FAULT/平台复位。新增C在accept锁存结果的时序、源范围无效不启动/不发AXI、0x21/0x26计数/释放Back、真正接收才清错误、pending时拒绝请求及FAULT禁止swap提交。

回归：原BLIT42用例及负对照、原FILL测试通过；工程51个源清单和47个CSR的一致性检查通过。Icarus 对原 `fill_rect_writer` 未显式定义 timescale 给出继承提示，不影响仿真；本轮未改该执行单元。

下一步由 A 按方案接正式寄存器/软件命令，由 C 实现源范围检查和读仲裁，并接公共状态/Back写服务，再进行系统并发仿真、Efinity综合/时序检查和板级验收。合同测试使用真实 manager，但源检查结果、DDR与reader-safe仍是模型输入，未验证C的检查算法、实际读owner/响应路由/最大等待和显示连续性。当前测试不证明整机已完成这些步骤。
