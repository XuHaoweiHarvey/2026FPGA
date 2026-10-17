# C 端 BLIT 集成交付包

日期：2026-10-17。仓库目录：`contrib/c_ddr_blit/`。

本包提供 C 侧可编译 RTL、独立与 C+B 并发仿真、接口说明和待确认清单。**它是供集成的 C 侧增量包，不是已经完成 APB→HDMI 系统集成的整套工程。** 本分支仅添加独立增量包及文档入口，不改变正式工程接线。

当前结果：9 个仿真顶层全部通过；运行测试会生成 `test_results/simulation.log`（不纳入版本控制），覆盖范围与限制见 `docs/VALIDATION.md`。尚未进行 Efinity 综合/布局布线、真实 DDR/HDMI 验证或整机软件联调。

## 从哪里开始

1. 阅读 `docs/INTERFACE_CONTRACT.md`：接口、时序、错误及 A 最新反馈。
2. 阅读 `docs/INTEGRATION.md`：替换 manager、接入读仲裁、保持显示统计隔离。
3. 将 `docs/QUESTIONS_AB.md` 发给 A/B 确认剩余事项。
4. 用 `scripts/run_tests.ps1` 复验，确认后由集成人接入正式工程。

## 文件用途

| 文件/目录 | 内容 |
|---|---|
| `rtl/c_front_range_guard.v` | accept 时锁存 Front 源范围、stride 校验结果 |
| `rtl/c_axi_read_arbiter.v` | 显示/BLIT 两路读请求，共享一笔 outstanding，异常锁定 |
| `rtl/c_display_read_priority.v` | FIFO 384/512 水位滞回生成显示优先信号 |
| `rtl/c_buffer_manager.v` | 保留原 manager 语义，增加平台故障阻止接收/释放/换帧 |
| `rtl/c_command_service.v` | 上述 manager 与源检查封装，命令快照、Back 偏移、sticky fault |
| `rtl/files.f` | 仅 C 新增 RTL 源清单，不包含参考工程和 testbench |
| `sim/` | 新增测试及新版 manager 兼容性回归 |
| `reference/` | 来自团队工程的原始参考 RTL/testbench，仅供本包仿真 |
| `docs/` | 接口合同、接线指南、验证记录、待确认问题、工作记录 |
| `scripts/` | Python/PowerShell 仿真入口 |
| `test_results/simulation.log` | 本地运行时生成的仿真输出，不等于实板验收 |
| `SHA256SUMS.txt` | 文件完整性清单 |

## 复验

安装 Python 3 和 Icarus Verilog 后，在本包目录运行以下命令；工具不在 PATH 时将参数替换为实际路径：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_tests.ps1 -Python 'python' -Iverilog 'iverilog' -Vvp 'vvp'
```

脚本按非零退出码判定失败，日志保存在 `test_results/`；不会连接板卡或改写原工程。便携工具不随本源码包分发。

## 当前必须遵守的边界

- 命令端口固定为 `op x y width height color src_addr src_stride start accept`。前八项 32 位，最后两项单周期控制信号。
- B 在 accept 当拍采样命令；C 的 `src_range_valid` 在该拍之后更新，B 在后续 CHECK 阶段使用，不得在 accept 当拍读取旧值。
- 所有新模块使用 core 时钟和平台复位；不能用 CPU reset 或显示 FIFO flush 重置仲裁器。
- A 新寄存器与版本提议已记录，但本包不擅自修改 A 的 CSR、API 或版本宣告。
- B 公共执行层尚未提供，本包不会用测试适配器冒充正式公共执行层。
- 低水位持续不恢复或 DDR 永久无响应时，本仲裁器不承诺 BLIT 的绝对等待上界。

参考来源：基础工作树 `5822a94` 的 framebuffer/显示框架，以及 `origin/main` 提交 `da941bd5f3ea36433dada6bf6c452244c4abb6fd` 中的 B BLIT 原型；本上传分支已 fetch 并基于该远端 main 创建。A 的接口补充截图已作为本轮对接口径记录，三方尚未正式签收。
