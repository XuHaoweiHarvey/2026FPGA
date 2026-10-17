# 待 A/B 确认清单

以下问题不阻止本包独立 RTL/仿真生成，但会影响正式系统接入。没有向 A/B 自动发送消息。

## 发给 A

1. 请确认截图中的 0xBC COMMAND_OP、0xC0 SRC_ADDR、0xC4 SRC_STRIDE，以及 op=0/1 和 0x26 sticky 错误语义，是否已获得三方正式确认；请提供对应分支/提交。C 已按 32 位字段和该语义编写接口及测试，但未修改 CSR。
2. 请确认 A 对外能提供团队固定的十个端口名，以及八参数在 START 时快照、accept 前保持稳定的实现。C 沿用单周期 start，不额外插入会吞掉正常请求的显示刷新禁收窗口。
3. 共享读仲裁器发现协议错误、且当时没有 B 命令执行时，A 通过哪个现有状态/诊断字段读取 sticky 平台 fault？不得只让软件永远等待 owned/pending；如需新状态位，请由 A 提议，不擅自占用 offset。
4. VERSION=0x00040000、CAPABILITIES=0x7B 何时启用？建议正式接入并通过联合验收时与 accel_api.h 同步更新；当前源码包不应提前宣告整机能力。

## 发给 B

1. 请提供正式 FILL/BLIT 公共执行层端口和分支/提交，确认支持 `src_range_valid`。约定：accept 当拍锁存原始八字段，下一周期 CHECK 使用 C 注册后的结果；非法源范围仍计数一次、0x21、无 AR/AW。
2. 请确认公共执行层有共享读故障输入，接 arbiter.fault 后进入 sticky 0x25/FAULT，保持 busy，不能只看自身 RLAST。若 C 在显示 owner 期间发现协议错误，也必须阻止随后 BLIT 被误报成功。具体无活动命令时的状态归属需与 A 一起确定。
3. 请确认正常 0x21/0x26 使用 DONE=1、BUSY=0 完成，下一次真正 accept 才清旧错误；不因写参数/CPU reset/CONTROL.bit1 清错。C 已测试所有权正常释放，正式公共计数仍由 B 实现。
4. 原型 WATCHDOG_BITS=27，在 100 MHz 下无进展阈值约 1.34 s；请确认公共层是否沿用，以及仲裁等待是否计入。C 采用低水位显示优先、健康水位轮转，尚无实测最坏等待周期。持续低水位不能保证 BLIT 有界进展，需要联合验证或调整策略。

## 三方联合确认

1. 谁负责修改共享 `rgb_framebuffer.v`、顶层和 Efinity XML，使用哪个正式基线提交？本包以本地可见基础工程和缓存的 B 原型构建，上传准备已 fetch 并基于远端 main 创建 C 分支，尚未合并。
2. 平台复位具体覆盖哪些 master、arbiter、DDR/互联和 FIFO？必须保证不会在清除 owner 后接收到旧事务响应，CPU reset 不算平台恢复。
3. 首轮 Front→Back、1920×1080、stride7680、源目标分槽不重叠、BLIT 四像素对齐限制是否作为首轮正式合同；后续资源区和可变 stride 另开版本。

## C 已作出的明确决定，无需重新询问

- C 检查源 Front 范围和固定 stride，并输出逐命令锁存结果。
- 全局一笔 outstanding；正常末拍必须握手且长度匹配；异常保持 owner。
- AW 由 B 给相对 Back 偏移，C 加一次锁存 base；AR 已是绝对地址。
- 0x25 sticky fault 禁止新命令和 swap，平台复位才清除；0x21/0x26 正常释放。
- 所有新模块保留显示统计隔离、CPU reset 隔离，不修改生成 IP。
