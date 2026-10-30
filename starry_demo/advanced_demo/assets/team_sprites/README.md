# 游戏小图素材

这些文件由队伍提供的参考图处理得到，原图文件名与 SHA256 记录在 `sources.json`。
海岛背景已单独接入，见 [背景目录](../team_background/README.md)。

| 文件 | 尺寸 | 图集坐标 | 绘制方式 |
| --- | --- | --- | --- |
| player.png | 32×32 | (64, 0) | Color Key |
| enemy.png | 32×32 | (96, 0) | Color Key |
| player_bullet.png | 16×16 | (128, 0) | Alpha |
| enemy_bullet.png | 16×16 | (144, 0) | Alpha |
| explosion_0.png 至 explosion_5.png | 每张 32×32 | (帧号×32, 64) | Alpha |

表中为源小图坐标；默认全屏版在同一 640×480 DDR 图集中放大两倍，
上述坐标、尺寸均乘 2。小区域模式保留表中的原尺寸，生成文件共用同一份。

处理后的 PNG 都有真实 Alpha 通道。飞机背景使用透明洋红 `(255,0,255,0)`，
运行时通过硬件 Color Key 比较 RGB 去除；黑色轮廓保留。敌机提亮并旋转朝下。
子弹只取原图上方的主体，排除下方色块；爆炸从原图按 3 列×2 行拆分并去除蓝底。
子弹和烟雾保留分级 Alpha；爆炸再叠加随时间下降的全局 Alpha。

每张最多 16 色，以每像素 4 位索引和 ARGB 调色板保存在生成的
`software/interactive_demo/game_sprite_assets.h` 中。目前像素和调色板合计 4,864 字节，
另有描述表。启动时展开到原有 640×480 DDR 图集，校验后封存；游戏不读取 PNG，
运行时也不由 CPU 做 Alpha 混合。原有 64×64 玩家光晕仍由代码生成。

`manifest.json` 记录位置、色数和解码后小端 ARGB 字节的 FNV-1a；`preview.png`
是四倍放大的素材预览，`explosion_preview.gif` 是动画示意，均不代表板上测量结果。

在 `advanced_demo` 下，用安装了 Pillow 的 Python 运行：

```powershell
python -B tools/prepare_team_sprites.py
python -B tools/prepare_team_sprites.py --check
```

不需要原图即可从本目录 PNG 重建头文件和预览。要重新导入队伍的五张原图，使用
`--source-dir '原图目录'`；原图文件名见 `sources.json`。修改素材后需重新生成头文件，
有意改变的像素哈希也应同步到 `sim/test_game_debug_control.c` 的参考值。
仅构建游戏不需要 Pillow。加载与验证见 [素材版操作说明](../../docs/TEAM_SPRITES.md)。
