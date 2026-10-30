#ifndef GAME_FLASH_STORE_H
#define GAME_FLASH_STORE_H
#include <stdint.h>
#define FLASH_BYTES 0x800000u
#define FLASH_ASSET_END 0x7e0000u
#define FLASH_SAVE_A 0x7e0000u
#define FLASH_SAVE_B 0x7f0000u
#define FLASH_SECTOR 4096u
#define FLASH_PAGE 256u
#define FLASH_PACK_MAGIC 0x53413246u /* F2AS */
#define FLASH_PACK_VERSION 1u
#define FLASH_ASSET_COUNT 4u
#define FLASH_FORMAT_XRGB 1u
#define FLASH_FORMAT_ARGB 2u
enum { FLASH_OK=0, FLASH_EMPTY=1, FLASH_IO=2, FLASH_RANGE=3,
       FLASH_FORMAT=4, FLASH_CRC=5, FLASH_TIMEOUT=6, FLASH_ID=7 };
typedef struct {
    void *context;
    int (*read)(void *,uint32_t,void *,uint32_t);
    int (*program)(void *,uint32_t,const void *,uint32_t);
    int (*erase)(void *,uint32_t);
} flash_io_t;
typedef struct { uint32_t id,offset,width,height,stride,format,length,crc; } flash_asset_t;
typedef struct { uint32_t total; flash_asset_t entries[FLASH_ASSET_COUNT]; } flash_pack_t;
typedef struct { uint32_t high_score,difficulty,flags; } game_save_t;
typedef struct { uint32_t slot,sequence; int valid; } game_save_info_t;
uint32_t flash_crc32(uint32_t crc,const void *data,uint32_t size);
uint32_t flash_get32(const uint8_t *p);
void flash_put32(uint8_t *p,uint32_t value);
int flash_pack_open(const flash_io_t *io,flash_pack_t *pack);
int flash_asset_verify(const flash_io_t *io,const flash_asset_t *entry);
int game_save_load(const flash_io_t *io,game_save_t *save,game_save_info_t *info);
int game_save_write(const flash_io_t *io,const game_save_t *save,game_save_info_t *info);
/* Real RV32 SPI transport. No bootloader, filesystem or chip erase. */
int flash_spi_open(flash_io_t *io);
uint32_t flash_spi_jedec(void);
#endif
