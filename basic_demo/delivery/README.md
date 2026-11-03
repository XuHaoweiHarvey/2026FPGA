# 基础演示交付文件

本目录随 Git 提交，供队友直接取得基础版的 FPGA 配置和 RISC-V 软件。
`software/basic_demo/build/` 继续作为本地编译目录，不提交中间产物。

| 文件 | 用途 |
|---|---|
| `ti60f225_oob.bit` | 基础版现有 FPGA 配置，沿用 2026-10-24 的构建产物 |
| `basic_demo.elf` | 2026-11-03 从当前基础版源码重新编译的 RISC-V 程序 |
| `basic_demo.bin` | 同次编译的纯二进制，用于核对程序内容 |
| `basic_demo.map` | 同次编译的链接地址和内存占用记录 |
| `ti60f225_oob.timing.rpt`、`ti60f225_oob.place.rpt`、`ti60f225_oob.pgm.out` | 与现有 bit 一起归档的硬件构建报告 |
| `build-info.json`、`SHA256SUMS.txt` | 本次构建说明、输入及交付文件的 SHA256 |

## 使用

1. 在 Efinity Programmer 加载本目录的 `ti60f225_oob.bit`，完成后退出 Programmer。
2. RISC-V IDE 导入 `../software/basic_demo`。该项目现有元数据仍使用
   `D:/Github_repositories/2026FPGA` 和 `D:/Efinity/efinity-riscv-ide-2026.1`；
   如果本机目录不同，按 [软件说明](../software/basic_demo/README.md) 调整
   `.project`、`.cproject`、Launch 和 OpenOCD 路径。
3. 直接使用交付 ELF 时，在调试配置中把 Application、Image、Symbols 指向本目录
   同一个 `basic_demo.elf`，关闭启动前自动 Build。自行重编译时，使用
   `../software/basic_demo/build/basic_demo.elf`，并保持三个位置一致。
4. Resume 后观察矩形、三张图片的 CPU/FPGA 渲染比较和 FPS HUD。
   游戏版的 bit 和 ELF 与基础版不可混用。

## 本次验证范围

- Efinix RISC-V GCC 13.4.0，RV32IM，`-O2 -g3`；ELF LOAD 段和栈均通过 OCRAM 边界检查。
- 默认 24 矩形和 50 矩形的 RV32 场景回归通过，覆盖 CPU/FPGA 任务、运动、图片复制和 FPS 计算。
- `basic_demo.bin` 的 SHA256 与软件说明归档的旧 M2 等效构建一致：
  `c558d8d5f398339d71593fccd186a03b141bebe55ae5b469f75699770814a56a`。
- 这次只重新编译软件，没有重新编译 FPGA，也没有连接开发板复验。
  原链接脚本产生的 LOAD 段 RWX warning 仍存在。

## 重新编译

在 `basic_demo/software/basic_demo` 内执行：

```powershell
python -B build.py --ide-root 'D:\Efinity\efinity-riscv-ide-2026.1'
```

若修改源码后需要重新发布，应更新本目录的 ELF、BIN、MAP 和校验记录。
