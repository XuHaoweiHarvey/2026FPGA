# 两个最终模式共用的构建素材

本目录只包含基础图集、背景和资源清单，供 PixelForge、压力版构建和渲染检查使用。
它不是可运行的第三种游戏模式，不包含旧版 ELF、bit 或启动入口。

`atlas.argb`、`background.argb` 是 640×480 的 little-endian ARGB8888。
`assets.json` 保存尺寸、布局和校验和。素材从原交付包迁入，内容逐字节不变。
PixelForge 构建在副本上生成正式圆弹、激光和标题，压力版生成 8×8 弹图集。
不要直接把这里的基础图集与最终版 ELF 混用；运行时使用各自 `delivery` 下的完整资源包。
