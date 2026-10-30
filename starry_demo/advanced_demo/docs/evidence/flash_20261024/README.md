# Flash 交付证据（2026-10-24）

本目录随 Flash 实现提交，记录交付时的实际离线构建和测试结果。

- [完整交付说明](../../FLASH_DELIVERY.md)：模块职责、地址、IDE、素材写入/导出、接线和板卡验收步骤。
- [验证记录](../../FLASH_VALIDATION.md)：测试范围、工具版本、资源/时序、警告和待验收项。
- [摘要清单](manifest.json)：实现基线、源文件与构建产物的 SHA-256、产物大小；`board_tested=false`。

## 日志对应关系

| 日志 | 记录 |
|---|---|
| `game-build.log` / `flash-probe-build.log` / `flash-maint-build.log` | 实际 VSCode 仓库中重新构建的三个应用、OCRAM 地址与符号 |
| `flash-generation.log` | 厂商 IP Manager 生成 SPI0 SoC/BSP |
| `flash-interface.log` / `flash-fpga-build.log` | 接口生成与 FPGA 综合、布局布线、编程文件生成 |
| `flash-checks.log` | 真实 RV32 指令模拟的存档、SPI、游戏逻辑、UART 协议和输入回归 |
| `flash-assets-tests.log` | PNG 往返、损坏检查、3162 个上传动作边界、存档区保留和导出合并 |
| `flash-gdb-tests.log` | 实际 IDE GDB 连接本机假 RAM，执行缓冲区 restore/dump |
| `flash-fallback-build.log` / `flash-m2-build.log` | 无 Flash 游戏模式及原 M2 应用兼容构建 |
| `project-check.log` / `delivery-check.log` / `jtag-check.log` | 工程接口一致、实际下载文件存在、Hard JTAG 输入未被优化删除 |

`.bit/.hex/.elf` 和生成的示例素材保存在本机 `advanced_demo/output/flash-release/`、`output/flash-example/`，遵循仓库已有构建产物忽略规则；本目录提交记录和摘要，其他成员可按交付说明重新生成。

日志保留当时的本地构建路径。源文件摘要按交付时工作树字节计算，Git 的换行转换或其他成员重建 IDE 路径后可能改变原始字节摘要。

**这些是构建和模拟证据，不是实物板卡验收结果。未在本次工作中连接、擦除或烧写板卡。**
