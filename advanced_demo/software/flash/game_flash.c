#include "game_flash.h"
volatile game_flash_result_t g_flash_result;
static flash_io_t io;
static flash_pack_t pack;
static game_save_t save;
static game_save_info_t save_info;
static uint8_t line_bytes[2560];
int game_flash_begin(void) {
    int rc=flash_spi_open(&io);g_flash_result.jedec=flash_spi_jedec();
    if(rc){g_flash_result.error=(uint32_t)rc;return rc;}
    rc=flash_pack_open(&io,&pack);if(rc){g_flash_result.error=(uint32_t)rc;return rc;}
    rc=game_save_load(&io,&save,&save_info);g_flash_result.save_status=(uint32_t)rc;
    if(rc!=FLASH_OK && rc!=FLASH_EMPTY){g_flash_result.error=(uint32_t)rc;return rc;}
    g_flash_result.high_score=save.high_score;g_flash_result.difficulty=save.difficulty;
    g_flash_result.save_sequence=save_info.sequence;g_flash_result.save_slot=save_info.slot;
    return 0;
}
int game_flash_row(uint32_t index,uint32_t row,uint32_t pixels[640]) {
    uint32_t x;int rc;
    if(index>=4 || row>=480)return FLASH_RANGE;
    rc=io.read(io.context,pack.entries[index].offset+row*2560,line_bytes,2560);
    g_flash_result.asset_id=index+1;g_flash_result.row=row;
    if(rc){g_flash_result.error=(uint32_t)rc;return rc;}
    for(x=0;x<640;x++)pixels[x]=flash_get32(line_bytes+x*4);
    return 0;
}
uint32_t game_flash_expected_crc(uint32_t index) {return index<4?pack.entries[index].crc:0;}
int game_flash_update_score(uint32_t score) {
    int rc;game_save_t next=save;
    if(score<=save.high_score)return 0;
    next.high_score=score;
    rc=game_save_write(&io,&next,&save_info);g_flash_result.save_status=(uint32_t)rc;
    if(rc){g_flash_result.error=(uint32_t)rc;return rc;}
    save=next;g_flash_result.error=0;
    g_flash_result.high_score=save.high_score;g_flash_result.save_sequence=save_info.sequence;
    g_flash_result.save_slot=save_info.slot;return 0;
}
