# 海岛背景

`island.png` 是队伍提供的海岛图处理结果；原图文件名与 SHA256 记录在 `source.json`。
原图按 16:9 裁切到 160×90，最近邻取样、亮度乘 0.55，再无抖动量化为最多 128 色。
图像作为不透明背景使用，游戏精灵的透明处理仍由 Color Key/Alpha 完成。

生成的 `software/interactive_demo/game_background_asset.h` 用 8 位索引与 XRGB 调色板
保存背景，合计 14,912 字节。CPU 启动时按 12 倍最近邻展开到封存的 1920×1080 DDR
窗口，绘制时由硬件复制背景区域。游戏不直接读取 PNG，也不需要把原图放到板卡文件系统。

`preview.png` 为 960×540 背景预览。它由同一份小图放大得到，不是上板截图。

在 `advanced_demo` 下使用带 Pillow 的 Python：

```powershell
python -B tools/prepare_game_background.py
python -B tools/prepare_game_background.py --check
```

可直接从本目录 PNG 重建头文件，无需原图；仅构建 ELF 不需要 Pillow。
重新导入原图使用 `--source '原图路径'`。有意修改图片后，应同步 C 回归中的独立
参考像素哈希；部署步骤见 [全屏版说明](../../docs/FULLSCREEN_GAME.md)。
