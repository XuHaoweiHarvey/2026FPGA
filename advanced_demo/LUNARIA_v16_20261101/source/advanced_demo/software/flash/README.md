# 游戏 Flash 模块

完整操作与逐文件职责见 [Flash 交付说明](../../docs/FLASH_DELIVERY.md)，验证结果见 [验证记录](../../docs/FLASH_VALIDATION.md)。

本模块有三个独立应用：游戏通过现有 `interactive_demo/game_main.c` 运行；`flash_maint.c` 用于明确执行的素材上传/存档设置；`flash_probe.c` 只读导出。均由 IDE 下载到片内 RAM，不是 Bootloader。

`flash_store` 是独立于硬件的格式与 A/B 存档层，`flash_spi` 是 GD25LQ64 单线 SPI 传输层，`game_flash` 是游戏门面。只有维护 ELF 编译了 `FLASH_MAINTENANCE_BUILD`，游戏的写入/擦除不能进入素材区。

导入 IDE 前先从 `advanced_demo` 执行 `scripts/prepare_apb_ide.py --debug-only` 和 `scripts/prepare_flash_ide.py`，为当前仓库位置重建路径。链接显式使用 `ocram.ld`，不要换回生成器默认 DDR 链接脚本。
