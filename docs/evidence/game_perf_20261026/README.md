# 居中游戏满载 30 FPS 实板记录

用户于 2026-10-26 提供调试报告截图，截图报告时间为当日 20:31:03。
`centered_full_load_30fps.png` 是原始截图的本地副本；`results.json` 为人工摘录，
不是调试窗口的原始导出 JSON。

60,000 ms 区间平均/最低秒窗均为 30.00 FPS，显示 3,600 次，重复 1,800 次，
最慢绘制 27.134 ms，最大换帧间隔 33.333 ms，新增 underflow/missed 为 0/0。
raw_underflows=66 是累计历史值，不能当成本次新增。

报告有冻结完成标记；实时 runtime 处于部分发布，实时像素数/字形数只能作为单帧参考。
截图未完整展示所有错误字段及加载文件哈希，完整硬件错误验收和版本匹配需补原始导出。
本地候选 bit/ELF 已另存到被忽略的 `advanced_demo/output/performance_baseline_20261026_30fps/`，
它保留产物身份，不证明该哈希就是板上运行文件。

本记录属于旧居中飞机游戏的历史基线，不能代表现役 PixelForge 或压力测试。
统一性能口径见 [BENCHMARK](../../BENCHMARK.md)，原分析见
[性能交接报告](../../../starry_demo/advanced_demo/docs/PERFORMANCE_HANDOFF_20261026.md)。
