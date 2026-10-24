/* Explicitly loaded maintenance ELF; never part of the game/boot path.
 * Debugger sets action and cookie at flash_maint_ready(), then resumes.
 * 1 read, 2 erase asset sector, 3 program/verify asset chunk, 4 save settings.
 */
#include "flash_store.h"
typedef struct {
    uint32_t phase,error,jedec,action,cookie,address,length,crc,high_score,difficulty;
    uint8_t data[4096];
} flash_maint_t;
volatile flash_maint_t g_flash_maint;
static flash_io_t io;
static uint8_t verify[256];
__attribute__((noinline)) void flash_maint_ready(void) {__asm__ volatile("nop");}
static int operate(uint32_t action) {
    uint32_t a=g_flash_maint.address,n=g_flash_maint.length,off,k,part;
    const uint8_t *p=(const uint8_t *)g_flash_maint.data;
    int rc;
    if(action==1) {
        if(n>sizeof(g_flash_maint.data))return FLASH_RANGE;
        rc=io.read(io.context,a,(void *)g_flash_maint.data,n);
        if(!rc)g_flash_maint.crc=flash_crc32(0,p,n);
        return rc;
    }
    if(g_flash_maint.cookie!=0x464c5348u)return FLASH_FORMAT;
    if(action==4) {
        game_save_t save={g_flash_maint.high_score,g_flash_maint.difficulty,0};
        game_save_info_t info;
        return game_save_write(&io,&save,&info);
    }
    if(a>=FLASH_ASSET_END || n>FLASH_ASSET_END-a)return FLASH_RANGE;
    if(action==2) {
        if(n!=4096 || (a&4095u))return FLASH_RANGE;
        return io.erase(io.context,a);
    }
    if(action!=3 || !n || n>sizeof(g_flash_maint.data))return FLASH_FORMAT;
    if(flash_crc32(0,p,n)!=g_flash_maint.crc)return FLASH_CRC;
    for(off=0;off<n;off+=part) {
        part=256u-((a+off)&255u);if(part>n-off)part=n-off;
        rc=io.program(io.context,a+off,p+off,part);if(rc)return rc;
        rc=io.read(io.context,a+off,verify,part);if(rc)return rc;
        for(k=0;k<part;k++)if(verify[k]!=p[off+k])return FLASH_CRC;
    }
    return FLASH_OK;
}
int main(void) {
    int rc;
    g_flash_maint.phase=1;rc=flash_spi_open(&io);
    g_flash_maint.jedec=flash_spi_jedec();g_flash_maint.error=(uint32_t)rc;
    g_flash_maint.action=0;g_flash_maint.cookie=0;
    for(;;) {
        g_flash_maint.phase=rc?255u:2u;
        flash_maint_ready();
        if(!g_flash_maint.action)continue;
        if(g_flash_maint.jedec!=0xc86017u)rc=FLASH_ID;
        else rc=operate(g_flash_maint.action);
        g_flash_maint.action=0;g_flash_maint.cookie=0;
        g_flash_maint.error=(uint32_t)rc;
    }
}
