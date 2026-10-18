# B：Color Keying 独立执行模块

2026-10-18：实现赛题二高阶 Color Keying 的第一步——带色键的图像复制执行层。已通过独立 RTL 仿真，尚未接入正式 v4 APB、graphics_engine、Framebuffer 或 Efinity 工程；没有综合时序或实板验收。原正式 FILL/BLIT 源码和寄存器合同保持原样。

## 功能与用途

普通 BLIT 会复制整个矩形，包括小图的背景色。色键复制指定一种 RGB 颜色，例如紫色 `0xFF00FF`：源像素 RGB 等于该颜色时，保留目标 Back 原有的完整 32 位像素；其他像素按普通 BLIT 复制。这可以用于有不规则轮廓的图标、人物和游戏精灵。

这里的“透明”是跳过写入，不是半透明混合。目标背景必须事先存在于 Back；本模块不会自动复制 Front 的背景，也不会加载 PNG、解释图片 Alpha 或做缩放。

## 文件

| 文件 | 用途 |
|---|---|
| `rtl/accelerator/color_key_blit_engine.v` | 包装现有 blit_engine，接收并锁存色键参数，对四个像素分别生成写掩码 |
| `sim/tb_color_key_blit.v` | 基于原始源图与坐标的独立像素参考检查、协议检查与结果图导出 |
| `scripts/run_color_key_checks.ps1` | 编译、运行三组测试、像素负对照、可选 PNG 转换 |

复用 `rtl/accelerator/blit_engine.v` 和 `sim/tb_blit_engine.v` 内的 byte-strobe-aware 内存模型，不修改它们。

## 执行层接口与规则

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

## 后续接入

1. 共同确定正式命令的色键开关/颜色传递方法、能力标识和软件 API，保持普通 FILL/BLIT 默认行为。
2. 在公共执行入口选择色键能力，沿用 Front 源窗口检查、Back 锁存、显示读仲裁和写准入；先准备 Back 背景，再提交精灵复制，完成后显式换帧。
3. 系统测试验证参数快照、显示并发和换帧，随后综合布局布线，检查比较/掩码路径时序；在真实 DDR 上验收部分/全零 WSTRB 与 B 响应。

当前交付只完成第一个高阶功能的独立执行层，不能把独立结果图称为 HDMI 实测，也不更新 v4 的 VERSION/CAPABILITIES。
