# BLIT 源图范围检查

`rtl/framebuffer/blit_source_guard.v` 实现首轮约定的 C 侧源窗口策略，已接入 manager 合同仿真和双缓冲闭环仿真。正式 `rgb_framebuffer.v`、APB 和 Efinity 工程源清单尚未接入；显示/BLIT 读仲裁仍待实现。

## 为什么需要

BLIT 不仅要判断目标矩形能不能放下，还要判断从哪里读取源像素。例如，1920 像素宽的图像，从源 x=1916 复制 32 个像素，会横跨到下一行。整个地址范围可能仍在 Front 内，但它不是合法的源矩形。

正式图像是1920×1080、XRGB8888，每像素4字节，行距7680字节；有效图像只有 `0x7E9000` 字节。两槽基址由现有 manager 提供，为 `0` / `0x00800000`，每槽预留8MiB。槽尾部空隙不属于源图。

## 接口和时序

| 信号 | 用法 |
|---|---|
| `clk / rst_n` | 与 B、manager 相同的 core 时钟和平台复位；CPU/debug reset 不取消本条命令 |
| `command_accept` | manager 的最终接收信号；与 B.start 共用，不能接原始软件 START |
| `front_base / back_base` | 本次接收前的两槽角色；Back 的锁存仍由 manager 完成 |
| `src_addr / src_stride` | 与 B 同一份命令快照，分别是绝对字节地址、字节行距 |
| `width / height` | 与 B 同一份矩形宽高，单位像素 |
| `src_range_valid` | 寄存结果，接 B 的同名输入；无 accept 时保持，平台复位清零 |

在时钟沿 T，manager 接收命令、B 保存参数、检查器保存源范围结果。T+1 的 `CHECK_SOURCE` 才由 B 读取该结果。接收后的外部参数或缓冲角色变化不重新计算当前结果。

检查失败仍正常接收和计数。B 返回 `0x21`，不启动子 BLIT、不发 AR/AW/W，并正常结束释放 Back。检查器不负责生成 DONE、错误码或控制 ownership，也不能用检查失败直接压住 manager 的 accept。

## 检查规则

检查器允许源矩形位于当前 Front 的任意有效像素位置，要求：

- Front 与 Back 基址不同，Front 和源地址按4字节像素对齐。
- 完整 Front 图像窗口不超过32位地址空间；源地址不低于 Front，也不落入有效图像后的空隙。
- `src_stride` 必须等于参数 `FRAME_STRIDE`，正式值7680；宽、高均非零。
- 用 `offset=src_addr-front_base` 推导 `source_y=offset/FRAME_STRIDE`、`source_x=(offset%FRAME_STRIDE)/4`。
- `source_x+width<=FRAME_WIDTH` 且 `source_y+height<=FRAME_HEIGHT`。加法先扩展至33位，窗口末地址用64位，避免非法大数回绕成合法小数。

参数默认1920/1080/7680，测试可缩为64/48/256；当前模块要求 packed XRGB8888，即 `FRAME_STRIDE=FRAME_WIDTH*4`。窗口采用半开区间，最后一个有效字节可以是 `0xFFFFFFFF`，末地址为 `0x100000000` 时仍合法。固定 Front/Back 槽的分配和不重叠布局沿用 manager 的平台配置。

B 的原型另有16字节源地址对齐、目标 x/width 为4像素倍数等限制。这些仍由 B 检查；本模块的“窗口有效”不等同于完整 BLIT 参数全部合法。FILL 和非法 opcode 按 B 原有路径处理，不受源窗口限制。

除数为综合时常量，正式7680并非2的幂。当前版本使用组合的常量除法/取余再寄存结果；Icarus 通过不证明100MHz时序或资源满足要求。正式接入时需要 Efinity 综合与时序检查，如需流水化，必须同步调整 B 的结果采样时序。

## 复现和结果

在仓库根目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/run_graphics_checks.ps1
```

Icarus 的 `iverilog`、`vvp` 需要在 PATH 中。`-NoWave` 跳过波形；Python3只用于原有图片转换，不影响 RTL 判定。检查器波形位于 `output/graphics/source_guard_1080p/graphics.vcd`；总日志是 `output/graphics/graphics.log`。

| 测试 | 结果 |
|---|---|
| 独立1080p检查，真实stride7680 | 426个矩形，其中400个固定种子的随机用例；另检查无accept保持、异步复位 |
| 独立64×48检查，stride256 | 同426个矩形及保持/复位检查 |
| 真实 manager＋检查器＋B 合同 | 17场景，拒绝越界后计数/0x21/Back释放、无AXI、连续合法/非法命令与参数快照、FILL兼容、FAULT和pending保护 |
| 两组双缓冲闭环 | 每组11场景、20条命令、8次换帧、178,176次像素比较；真实检查器跟随Front/Back交替 |
| `+BYPASS_SOURCE_GUARD` 负对照 | 故意把 B 的检查输入绑1，合同断言检测到被拒绝命令暴露AXI；runner要求此运行按预期失败 |

独立参考逐行检查源字节区间及行边界；期望值不读取 DUT 的内部坐标或判断结果。定向覆盖整图、精确右/下边界、横向跨行、底部越界、8MiB槽尾、Back/旧Front、错误stride、非像素对齐、巨大无符号尺寸及32位地址空间顶部。

现有85场景执行层回归保留，总入口合计852个源矩形用例＋124个执行/合同/双缓冲场景，4个故意错误的负对照。DDR内存、命令、显示边界与 reader-safe/FIFO-empty仍由模型/测试提供，尚无实际读仲裁、HDMI连续性、综合时序或实板验收结果。
