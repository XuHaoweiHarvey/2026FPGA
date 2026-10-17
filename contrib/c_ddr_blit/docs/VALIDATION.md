# 验证记录

执行日期：2026-10-17。工具为便携 Icarus Verilog 12 开发版 Windows 构建，使用 `-g2012 -Wall` 编译；Python 运行器检查每条命令退出码。本地执行日志生成于 `test_results/simulation.log`，不提交包含机器路径的运行产物。

## 已执行，全部通过

| 仿真顶层 | 验证内容 |
|---|---|
| tb_c_priority | 384/512 滞回、reader inactive、重新启动 |
| tb_c_range | 18 个边界用例及快照稳定性；跨行、帧尾、槽尾、零尺寸、对齐、错误 stride、溢出、op 隔离 |
| tb_c_arbiter | AR 锁定、R 末拍反压、owner 路由、128/32 beats、RRESP/RID 透传、早到/缺失 RLAST、外部 fault、无归属 R |
| tb_c_command | 命令快照、Back 加一次、0x21/0x26 释放、忙时不交换、正常 flush 接收 START、0x25 保持、迟到故障取消 swap |
| tb_c_blit_integration | 真实 B 原型+C 服务+模拟 DDR+并发显示；32×32 共 1024 像素逐拍比较，AR/AW/W 停顿；源跨行不发 BLIT AR/AW |
| tb_buffer_manager | 原始 manager 对照回归：64 个异步边界事件、11 次 swap、busy/pending/旧 R/FIFO empty/基址 |
| tb_c_manager_regression | 将同一基线测试接到 C 新版 manager，验证保留原行为 |
| tb_read_frame_guard | 完整 518400 R beats / 4050 bursts；末拍停顿、流水线 idle、错误和重启 |
| tb_fill_rect_writer | 既有 FILL 像素记分板、WSTRB/4KiB/几何/参数快照/反压/B 错误/超时排空/显示 settle |

原始参考文件存在 timescale 继承警告，日志已保留；新增 RTL 已显式声明 timescale。无编译错误或仿真断言失败。

## 验证边界

- C+B 联合测试使用原型适配器，不是正式 A/B 公共执行层；非法 opcode 的公共计数及 CSR sticky 清除规则尚需 B/A 实现后做系统验证。
- 模拟 DDR 根据地址生成可预测数据，用独立目标地址和像素预期进行比较；没有模拟 DDR PHY、刷新开销、真实时延或缓存一致性。
- 联合测试没有接入真实显示 FIFO 和 `ddr_write_admission`，因此不能据此宣称整机不会 underflow。原 guard/manager/FILL 的独立回归也不等于完整 RGB 系统回归。
- 没有进行完整 APB 软件提交→BLIT→HDMI 实板显示；没有综合资源、100 MHz 时序或上板数据。
- 未证明持续低水位时 BLIT 有界等待，未对所有故障交织进行形式验证。下一步验收见 INTEGRATION.md。

## 工具复现注意

便携 Windows vvp 在本机沙箱短路径查询下失败，运行器通过官方 `-M -` 关闭默认模块路径，再显式传入 `lib/ivl`；编译器显式 `-B` 指定同一路径。没有修改工具二进制或系统 PATH。运行时通过脚本参数指定 Python、iverilog 和 vvp，不提交个人机器路径。
