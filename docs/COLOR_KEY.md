# B：Color Keying 独立模块与统一命令入口

2026-10-18：赛题二高阶 Color Keying 已完成独立复制执行层，并接入 B 的 `graphics_engine` 可选命令路径；独立及统一入口混合场景仿真通过。统一入口的 `COLOR_KEY_ENABLE` 默认关闭，正式 v4 APB、Framebuffer、工程源清单和软件 API 尚未开启色键功能；没有色键综合时序或实板验收，v4 VERSION/CAPABILITIES 保持原值。

## 功能与用途

普通 BLIT 会复制整个矩形，包括小图的背景色。色键复制指定一种 RGB 颜色，例如紫色 `0xFF00FF`：源像素 RGB 等于该颜色时，保留目标 Back 原有的完整 32 位像素；其他像素按普通 BLIT 复制。这可以用于有不规则轮廓的图标、人物和游戏精灵。

这里的“透明”是跳过写入，不是半透明混合。目标背景必须事先存在于 Back；本模块不会自动复制 Front 的背景，也不会加载 PNG、解释图片 Alpha 或做缩放。

## 文件

| 文件 | 用途 |
|---|---|
| `rtl/accelerator/color_key_blit_engine.v` | 包装现有 blit_engine，接收并锁存色键参数，对四个像素分别生成写掩码 |
| `sim/tb_color_key_blit.v` | 基于原始源图与坐标的独立像素参考检查、协议检查与结果图导出 |
| `scripts/run_color_key_checks.ps1` | 编译、运行三组测试、像素负对照、可选 PNG 转换 |
| `rtl/accelerator/graphics_engine.v` | 可选色键命令接收/锁存、源检查、同一 BLIT DMA 与公共写掩码 |
| `sim/tb_graphics_engine.v` | FILL/普通复制/色键复制交替、混合场景和错误/排空/兼容性检查 |
| `scripts/run_graphics_checks.ps1` | 运行关闭/开启色键的四组执行入口配置及既有合同、双缓冲、读仲裁测试 |

复用 `rtl/accelerator/blit_engine.v` 和 `sim/tb_blit_engine.v` 内的 byte-strobe-aware 内存模型，不修改它们。

## 独立执行模块接口与规则

原 BLIT 的参数、状态、AXI AR/R/AW/W/B 接口和错误码不变；增加以下两个独立模块输入，尚不分配共享 APB offset 或 opcode：

| 输入 | 含义 |
|---|---|
| `color_key_enable` | 0：普通复制；1：开启精确 RGB 色键比较 |
| `color_key_rgb[23:0]` | 比较值，按 `0xRRGGBB` 表示 |

在 `start && enabled && !busy` 的接受沿锁存色键开关和值，与底层 BLIT 接收命令同拍。忙时 START、执行中修改实时参数或 enabled 均不改变当前命令的掩码。`rst_n` 继承底层 DMA 的平台复位语义，不能接 CPU/debug reset 来取消在途事务。

- XRGB8888：低地址为 B/G/R/X。比较仅使用 RGB[23:0]，忽略 X；X 不是 Alpha。
- 每拍四个 32 位像素。透明像素对应四个 byte strobe 全为 0；不透明像素保持原 BLIT 的写入许可，完整复制 XRGB。
- 即使整拍或整个 burst 都透明，也保留 AW、全部 W、WLAST 和 B 握手。不能因 WSTRB=0 丢弃 WVALID，否则会使已接受的 burst 无法结束。
- 因为通过写掩码保留 Back，不增加目的背景读取通道，也不减少当前版本的读写 beat 数。不能据此宣称透明图像减少了 DDR 流量。
- 地址语义继承 BLIT：源为绝对 byte 地址，AW 为相对锁存 Back 的 byte 偏移；外层只加一次物理 Back base。
- 继续要求源地址/stride 为 16-byte 对齐、目的 x/width 为四像素倍数；矩形非零且在画面内，不支持重叠搬移。
- 独立模块不代替正式源窗口检查器、读仲裁、写准入或换帧管理。未来接入仍必须使用这些保护。
- DONE、超时排空和错误沿用原 BLIT：最后成功 B 前不能成功完成；错误后可能已部分更新 Back，不提供回滚。

## B 统一入口的可选色键命令

统一入口保持现有端口，增加配置参数 `COLOR_KEY_ENABLE=0`、`OP_COLOR_KEY=2`。只有显式开启前者才识别第三种命令；默认仍仅支持 FILL/BLIT，实验色键 opcode 按未知操作返回 0x26、计数一次且不访问 AXI。实验编码 2 不是已发布的正式 APB 命令。

开启后，色键命令使用既有 `src_addr/src_stride/x/y/width/height`，`color[23:0]` 表示色键 RGB，`color[31:24]` 忽略。命令接收沿锁存“本条是否色键”和颜色；普通 BLIT 不使用 color，FILL 仍按完整 XRGB 颜色绘制。后续的参数写入、enabled 改变和忙时 START 不改变本条选择或掩码。

普通 BLIT 和色键复制共享同一 `blit_engine`、缓存和读写/错误状态机，没有多实例化一套 DMA。掩码在 B 的公共写出口生成，FILL 的边缘 WSTRB 不受影响。两种复制均经过原来的 `CHECK_SOURCE`，在接收后的下一拍采样 C 寄存的结果；源范围不通过则报 0x21，不启动读写。

正式系统要使用色键，还需完成后文的寄存器/软件/Framebuffer 接入。仅在 APB 的 COMMAND_OP 写入 2 不会使当前 v4 开始透明复制。

### 运行统一入口混合场景

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_graphics_checks.ps1
```

有可用 Python 3 时自动生成 PNG；也可用该脚本的 `-PythonExe` 指定解释器。结果位于 `output/graphics/color_key_dispatch/`，数据来自统一入口实际写入的模型内存：

| 图像 | 命令流程与结果 |
|---|---|
| `ck_01_background_6x.png` | 两条 FILL 绘制上方深蓝、下方绿色背景 |
| `ck_02_blit_6x.png` | 普通 BLIT 把 32×32 紫底机器人复制到左侧 |
| `ck_03_color_key_6x.png` | 色键命令把同一源图复制到右侧，保留蓝/绿背景；源 X 非零仍正确透明 |
| `ck_04_overlay_6x.png` | 再用非四像素对齐 FILL 画红条，检查命令切换与边缘写入 |

仿真画布为 64×48；源图、DDR 和 C 源范围结果是模型，没有执行 CPU 指令、真实显示扫描或换帧。它证明 B 的三类命令共享入口正确，不代表色键系统/HDMI 已验收。

## 在本机运行

在仓库根目录执行。需要已有 Icarus Verilog 的 `iverilog`、`vvp`，不需要 Efinity 或板卡：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_color_key_checks.ps1
```

默认输出到已被 Git 忽略的 `output/graphics/color_key/`。basic 子目录生成 `color_key.vcd` 波形和四份 PPM 图像。可用 `-NoWave` 省略波形；生成 PPM 不需要 Python。

脚本自动寻找 Python 3，把实际 RTL 内存像素转换为 PNG；若启动器不能工作，可显式提供可运行的解释器完整路径：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_color_key_checks.ps1 -PythonExe 'C:/path/to/python.exe'
```

已有 PPM 可以单独转换，不必重跑仿真：

```powershell
python scripts/render_blit_preview.py output/graphics/color_key/basic --names sprite_source background opaque_copy color_key_copy
```

| 图像名 | 含义 |
|---|---|
| `sprite_source_6x.png` | 32×32 紫底机器人源图 |
| `background_6x.png` | 复制前 Back 的棋盘背景 |
| `opaque_copy_6x.png` | 关闭色键，紫色矩形背景也被复制 |
| `color_key_copy_6x.png` | 开启紫色色键，机器人周围保留棋盘背景 |

图像来自执行后的仿真内存，完整像素比较通过后才导出。PNG 转换只负责格式转换与最近邻放大。

## 本轮验证

| 组 | 结果 |
|---|---|
| basic：64×48，最多 32 beats | 17 场景通过 |
| boundaries：1088×48，最多 32 beats | 19 场景通过，增加长行分段与源/目标不同位置的 4KiB 切分 |
| single_beat：64×48，缓存 1 beat | 17 场景通过 |
| 故意损坏内存写入 | 独立像素参考检查按预期报错，runner 要求检测到错误才通过 |
| 原 BLIT 回归 | 原 32+5+5 场景及原像素负对照通过 |

共 53 个色键场景，覆盖四像素全部 16 种透明组合、全透明/全不透明、关闭色键、变化的 X、精确 RGB 比较、黑/白色键、跨命令更新、stride padding、边缘、AR/W 反压、busy START、锁存参数、全透明等待 B、参数错误、R/B 响应错误及 W 超时后保持掩码并排空。每次检查整个目标缓冲的完整 32 位像素（含矩形外和透明位置）及源图未变，不依据 DUT 内部状态构造期望像素。

统一入口本轮结果：

| 配置 | 通过场景 |
|---|---|
| 色键关闭、最多 32 beats、FILL/BLIT=0/1 | 44，含实验色键命令仍返回 0x26 |
| 色键关闭、单拍缓存、FILL/BLIT=7/9 | 43 |
| 色键开启、最多 32 beats、FILL/BLIT/KEY=0/1/2 | 76，含原功能兼容及 33 个新增色键场景 |
| 色键开启、单拍缓存、FILL/BLIT/KEY=7/9/11 | 74，含原功能兼容及 32 个新增色键场景 |
| 色键负对照 | 仅在 bench 强制绕过色键掩码，第三步独立像素检查按预期拒绝被覆盖的背景 |

统一入口仍检查完整目标缓冲和源图，覆盖全 16 种掩码、黑白色键、普通复制/FILL 清除上一条色键模式、参数快照、源范围拒绝、disabled/busy、最后 B、R/B 响应与 ID 错误、五通道超时排空、RLAST 故障锁定和平台复位恢复。单拍缓存不具备“提前末拍”场景，因此两种配置场景数不同。原真实 manager/源检查器 17 个合同场景、两组各 11 个双缓冲场景及原负对照也通过；这些旧系统测试使用默认关闭的色键配置。

## 后续接入

1. 正式发布色键命令编码、颜色传递方法、能力标识和软件 API；本页实验 op/color 用法先用于 B 开发，不能直接当正式软件兼容合同。
2. 在 Framebuffer 正式配置中启用 B 能力，核对 APB 参数快照、Front 源窗口检查、Back 锁存、读仲裁和写准入；准备 Back 背景后再画精灵，完成后显式换帧。
3. 加入色键系统并发/换帧演示与测试，随后综合布局布线，检查比较/掩码路径时序；在真实 DDR 上验收部分/全零 WSTRB 与 B 响应。

当前交付已完成独立执行层和 B 统一入口的可选色键能力，结果图属于 RTL 仿真，不是 HDMI 实测。
