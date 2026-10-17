# C 端 DDR / BLIT 集成增量包

C 端独立源码、测试和交接文档位于 [contrib/c_ddr_blit](../contrib/c_ddr_blit/README.md)。

包含 Front 源窗口校验、单 outstanding 共享读仲裁、显示优先水位、平台故障锁定及命令管理封装。命令端口采用团队确定的 op/x/y/width/height/color/src_addr/src_stride/start/accept。

九个仿真顶层通过，包括与 B 原型并发读取时的 1024 像素复制验证。此包尚未接入正式 APB/公共执行层/HDMI 顶层，也未完成 Efinity 时序或实板验收；不会提前修改 VERSION/CAPABILITIES。

- [接口与 A 最新补充](../contrib/c_ddr_blit/docs/INTERFACE_CONTRACT.md)
- [正式工程接线指南](../contrib/c_ddr_blit/docs/INTEGRATION.md)
- [待 A/B 确认的问题](../contrib/c_ddr_blit/docs/QUESTIONS_AB.md)
- [验证范围](../contrib/c_ddr_blit/docs/VALIDATION.md)

在包目录执行 `python scripts/run_tests.py --iverilog <iverilog路径> --vvp <vvp路径>`；测试产物不纳入版本控制。
