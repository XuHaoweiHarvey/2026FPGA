# Color Keying：v5系统、软件与独立模块

2026-10-18：赛题二高阶 Color Keying 已从独立复制/统一入口接入正式v5 APB、Framebuffer、顶层与软件API。顶层同一`COLOR_KEY_ENABLE=1`同时开启控制和执行路径，VERSION=0x00050000、CAPABILITIES=0xFB；独立模块参数默认0，保留旧v4配置。共享显示系统RTL检查和当前软件构建通过；CPU指令行为检查因已有Unicorn依赖目录受权限限制未执行，不以旧v4结果代替。2026-10-19修复共用BLIT参数检查长路径后，Efinity完整编译及当前约束下静态时序通过，接口告警与实板仍待核对，见[V5_TIMING_FIX](V5_TIMING_FIX.md)。

## v5正式命令与软件接口

| 项目 | 合同 |
|---|---|
| 识别 | VERSION 0x00050000，CAPABILITIES bit7=1；完整值0xFB |
| 操作 | COMMAND_OP=2；0和1仍分别为FILL与普通BLIT |
| 色键 | 复用RECT_COLOR[23:0]，按0xRRGGBB精确比较，[31:24]忽略 |
| 参数快照 | APB成功START保存op、色键、几何、源地址/stride；engine accept再次保存执行参数 |
| 源/目标 | 当前Front内的绝对源byte地址、stride7680、16byte对齐；目标x/width为四像素倍数，写锁存Back |
| 透明像素 | 保留Back完整32bit值；不读取目的背景，不把X当Alpha |
| 完成/错误 | 与BLIT共用DMA及0x21..0x25错误规则；最后B完成后才能成功DONE并释放Back |
| API | accel_color_key_blit(src_addr,src_stride,x,y,width,height,key_rgb) |

API屏蔽key_rgb高8位，每条命令显式写op和参数。返回0只代表COMMAND_COUNT确认接收，随后必须`accel_wait_done()`；准备好全部Back内容后再显式swap/wait。任何错误均停止提交，不把失败Back呈现。完整寄存器及复位语义见[REGISTER_MAP](REGISTER_MAP.md)。新软件严格要求v5/0xFB，硬件和ELF须同时重建，旧v3/v4软件不能直接配套当前配置。

## 软件左右对比演示

设置`software/apb_reg_test/demo_config.h`的`DEMO_MODE=3`后Build；或在仓库根目录执行：

```powershell
python scripts/build_apb_software.py --define DEMO_MODE=3 --output output/graphics/color-key-demo-v5
```

每轮9条FILL构建128×128紫底机器人，源背景为`0x80FF00FF`，然后swap把它置为Front。再在新的Back画深蓝背景及y=448起的绿色地面，普通BLIT将机器人复制到`(384,384)`，色键BLIT将同一源图复制到`(1152,384)`，key=0xFF00FF。左右机器人都跨过蓝绿分界，右侧透明位置应分别保留两种背景。完成后第二次swap显示对比结果，保持`g_hold_frames`个边界周期。

CPU仍只写寄存器，图片由FILL生成，没有添加CPU DDR端口或PNG加载。源图换帧期间也会短暂可见；不保证“源图永不上屏”。可以在main断点设置`g_frame_limit=2`：预期26条完成命令，其中普通BLIT和色键BLIT各2条、4次swap、source_swaps_completed=2、iterations=2、pass=1、errors=0，underflow/missed增量应为0。它是板级验收预期，本轮仅确认软件成功构建，未执行其CPU指令。

调试观察`g_apb_test_result.color_key_commands_issued/completed`、`color_key_rgb`以及原诊断。模式0/1/2继续保留，模式3每轮13命令和2次swap；两次swap后恢复该轮初始物理槽角色。

## 共享DDR与显示系统检查

```powershell
python scripts/run_d_checks.py --color-key --apb-waits 0 1 3 --output output/graphics/color_key_system
python scripts/run_d_checks.py --color-key --apb-waits 1 --negative-control color-key-mask
python scripts/run_apb_checks.py
python scripts/run_rgb_checks.py --quick
```

`--color-key`隐含`--graphics`，连接真实APB、源检查器、B执行层、DDR读仲裁、显示Reader/FIFO、写准入、manager、CVO和串行器。DDR为双槽内存模型，分辨率缩小为512×64、stride2048、FIFO256，APB由testbench驱动，不执行Sapphire指令或加密PHY/HDMI IP。

系统场景先保留原FILL/普通BLIT，再通过FILL构造32×32紫底机器人并swap；在新Back画蓝绿背景，左侧普通复制、右侧色键复制。整帧XRGB参考逐像素检查目标及源未被修改，显示端也检查完整RGB帧。另覆盖Back源拒绝、全透明命令等待B、普通BLIT/FILL清除旧色键模式、APB色键改写/CPU reset不改变在途命令、最后B前保持Back并阻止swap，以及共享故障0x2004保护。原故意延迟最后R用例仍单独保留。

本轮WAIT0/1/3每组均通过6次swap、42完整帧及1,407,777次显示像素比较；正常绘制underflow/missed增量0。每组另有98,304个完整XRGB内存像素受检，160个全零和20个部分WSTRB拍。故意绕过色键掩码的负对照被系统检查拒绝；RGB quick/正式v5顶层端口展开、APB兼容测试通过。精确证据见[VALIDATION](VALIDATION.md)。

结果图由实际RTL写入的模型内存导出，不是Python重新绘图：`output/graphics/color_key_system/wait1/color_key_source_6x.png`、`color_key_scene_6x.png`。对比图中红条检查非对齐FILL，底部紫条检查普通BLIT在色键之后仍复制背景。软件128×128演示和这个32×32系统场景使用对应缩放坐标，两者不混作CPU/RTL联合仿真。

CPU/MMIO脚本`run_e_software_checks.py`已增加v5/色键用例、完整1080p模型像素检查、高8位屏蔽、错误后不换帧、计数回绕与另一初始Front；本轮该入口未运行。拥有可读Unicorn 2.1.4依赖和工具链时，先构建默认模式ELF，再按[SYSTEM_BLIT](SYSTEM_BLIT.md)的软件检查命令指定该ELF和依赖路径。

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

原 BLIT 的参数、状态、AXI AR/R/AW/W/B 接口和错误码不变；以下两个输入属于独立包装原型。正式v5复用统一入口，不实例化这个包装器：

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

统一入口保持现有端口，配置参数为 `COLOR_KEY_ENABLE=0`、`OP_COLOR_KEY=2`。只有显式开启前者才识别第三种命令；默认关闭配置仍仅支持FILL/BLIT，op2返回0x26、计数一次且不访问AXI。正式v5在顶层开启此配置并发布op2。

开启后，色键命令使用既有 `src_addr/src_stride/x/y/width/height`，`color[23:0]` 表示色键 RGB，`color[31:24]` 忽略。命令接收沿锁存“本条是否色键”和颜色；普通 BLIT 不使用 color，FILL 仍按完整 XRGB 颜色绘制。后续的参数写入、enabled 改变和忙时 START 不改变本条选择或掩码。

普通 BLIT 和色键复制共享同一 `blit_engine`、缓存和读写/错误状态机，没有多实例化一套 DMA。掩码在 B 的公共写出口生成，FILL 的边缘 WSTRB 不受影响。两种复制均经过原来的 `CHECK_SOURCE`，在接收后的下一拍采样 C 寄存的结果；源范围不通过则报 0x21，不启动读写。

正式v5的寄存器/软件/Framebuffer已接通；旧v4默认关闭配置仍不会因写入COMMAND_OP=2而启动透明复制。

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

## 独立模块及统一入口历史验证

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

## 剩余验收

1. 在依赖可读的环境执行当前v5 ELF的CPU/MMIO行为检查；本轮受权限限制跳过。
2. 当前源码已完成Efinity2026.1.132综合布局布线和当前约束下静态时序；A核对保留的接口/工具告警，并在下载前确认本次bit与软件版本配套。若重新构建，需再次核对资源和时序。
3. A/C在真实DDR验收部分/全零WSTRB与B响应、1080p显示并发、模式3左右对比、underflow/missed与诊断；保留旧FILL回归。

源码已完成系统接线/API/演示，图像和并发检查属于RTL仿真，尚无v5 HDMI实测或板级性能数据。
