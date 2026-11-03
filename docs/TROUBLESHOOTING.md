# 故障排查

当前运行入口见 [BUILD](BUILD.md)，协议与恢复条件见 [REGISTER_MAP](REGISTER_MAP.md)。先核对实际 bit/ELF、素材和本机路径，再保存诊断，不凭单个 LED 或历史文件名判断版本。

## 找不到 ELF、路径失效或加载旧程序

基础应用的源码构建结果是 `basic_demo/software/basic_demo/build/basic_demo.elf`；直接演示的归档文件是 `basic_demo/delivery/basic_demo.elf`。build 被忽略，Git 检出后没有本地 ELF 属正常情况：从源码 Build，或选择 delivery ELF。

IDE 的 Application、Image、Symbols 要使用同一个文件。直接加载 delivery 时关闭启动前 Build，自行重编译时使用默认 build 并启用 Build。迁移机器后核对 .project/.cproject、BSP/common、Launch、两个 OpenOCD -f、SVD 和寄存器描述的绝对路径。

游戏启动器找不到工具时按 [paths.local.cmd.example](../starry_demo/paths.local.cmd.example) 配置本机路径。切换 PixelForge/压力版后素材校验失败，先重新配置对应 v13 bit，清除旧封存素材，再用配套 ELF/assets 完整加载。

## GDB 连接后立刻退出

历史实际错误为：

```text
set $pc=0x0xf9000000
Invalid number "0x0xf9000000".
```

IDE Startup 的 Set PC hex 字段会自动补 `0x`，填写 `f9000000`。Target Description disabled、Prefer extended-remote 等 warning 不是这次错误的原因。

关闭占用 FTDI 的 Programmer、旧 OpenOCD/GDB，再启动当前项目的 Titanium Hard JTAG。已验证 FTDI 参数为：

```tcl
ftdi device_desc "Quad RS232-HS"
ftdi vid_pid 0x0403 0x6011
ftdi channel 1
```

实际配置入口在 [基础软件 openocd](../basic_demo/software/basic_demo/openocd/)，不要编辑另一个旧 Demo 中的同名文件。OpenOCD 工作区位于 OCRAM 末 1 KiB，不能覆盖程序入口。Efinix Jim Tcl 曾不支持包装脚本的 `info script`，当前配置通过 Launch 传入 `bsp_loc`，无需恢复旧自定位脚本。

## 连续绘制时黑屏或欠载增长

历史症状是 writer 活跃时黑屏、CPU 暂停或 writer 空闲后旧 Front 恢复；reader_error=0 仍可能是显示饥饿。合法 AXI 响应不保证返回足够及时，不能只看 RRESP。

当前正式设计保留显示写准入：每笔写 B 后等待 128 个真实显示 R 握手，FIFO LOW/HIGH=384/512，下一笔写最多 32 beats；准入保持到 B，不能撤回已暴露的 AW/W。详见 [显示保护合同](GRAPHICS_ENGINE.md#显示写保护)。

排查时依次记录：

1. bit/ELF 配对、VERSION/CAPABILITIES、SERVICE_STATUS、QUOTA=128、WATERMARKS=0x02000180；版本号不足以区分历史时序修复前后。
2. PLL/cal_done、INIT_DONE、初始化 beats/bursts、FRONT_VALID，确认启动画面先稳定。
3. BUSY、ERROR_CODE、WRITER_OWNED、CPU 会话/错误，区分仍在等待 B 与提交已完成。
4. underflow/missed 相对稳定 baseline 的增量、FIFO 水位、AR/R 最大等待、writer 最大等待及 throttle 是否进展。

UNDERFLOW_COUNT 统计 video 欠载周期，不是黑屏次数；启动历史值可非零。AR/R max 反映外部等待，不能直接推断加密 DDR scheduler 内部原因。历史写保护修复后，负责人确认连续显示稳定；重新交付仍按 [VALIDATION](VALIDATION.md) 复验。

## pending 不清或画面不更新

检查 BOUNDARY_COUNT 是否前进、旧显示 R/RLAST 是否排空、READER_OUTSTANDING/ERROR、FIFO/流水线 idle、blank 与 flush 条件，以及 writer/CPU 会话是否释放。最后 AR 不等于完整帧读完，SWAP_DONE 也不表示画面已经扫描输出。

CLEAR_DONE 只清 sticky DONE，不取消 pending。当前没有 CANCEL_SWAP；pending 会阻止新绘图命令。INIT/reader 协议故障需要平台复位，CPU Debug reset 不清平台 owner、素材 READY 或已发事务。保存状态后按设计恢复，不能强制交换或释放在途命令。

## RGB 色条错位或出现周期性横带

历史 TPG 的组合 frame_start 曾在 h/v 同时更新时产生毛刺，误清写 FIFO。当前使用寄存器产生 20 ns 脉冲，保留原同步与初始化屏障；不要恢复旧组合译码。

当前是 XRGB8888、128-bit beat 低 pixel 先输出，活动链不使用 Bayer/Debayer。历史 Bayer 相位和 R/B 交换设置不适用于当前颜色问题。按 [像素格式](ARCHITECTURE.md#时钟与像素格式) 核对 P0～P3、B/G/R/X、unpack 与双像素输出。

## Packer 报 jtag_inst1_TDI 缺失

早期无 CPU 显示工程曾因 JTAG 输入被优化删除，临时用 TDI→TDO 透传解决 required pin。当前 Sapphire 已唯一驱动 TDO，不能恢复该占位透传、叠加 EDB 或修改生成 debug_top。核对所开的工程、IP 注册和顶层接线。

## 基础版 LED 含义

| LED | 逻辑信号 |
|---|---|
| 0 | cal_done 后心跳 cnt[24] |
| 1 | INIT_DONE |
| 2 | 初始化 write FIFO full sticky |
| 3 | CVO 实时 underflow |
| 4 / 5 | AXI 写 / 读 beat counter bit22 |
| 6 | vid_rst_n |
| 7 | AXI response error sticky |

亮灭极性按板卡电路判断，当前顶层见 [ti60f225_oob_top.v](../basic_demo/rtl/ti60f225_oob_top.v)。LED3 是实时信号，累计欠载查看 CSR；闪烁现象本身不能证明具体根因。外围名含 Camera/MIPI 的时钟可能仍为 core/video 提供服务，不按名称删除。
