/* Read-only IDE probe/dump. Set request_offset/length then continue at done().
 * Export g_flash_dump.data[0..length), concatenate chunks by offset on host.
 * This firmware never calls erase or program.
 */
#include "flash_store.h"
typedef struct {
    uint32_t phase,error,jedec,request_offset,request_length,offset,length,crc;
    uint8_t data[2560];
} flash_dump_t;
volatile flash_dump_t g_flash_dump;
static flash_io_t io;
__attribute__((noinline)) void flash_dump_ready(void) {__asm__ volatile("nop");}
int main(void) {
    int rc;uint32_t off,n;
    g_flash_dump.phase=1;rc=flash_spi_open(&io);
    g_flash_dump.jedec=flash_spi_jedec();g_flash_dump.error=(uint32_t)rc;
    if(rc){g_flash_dump.phase=255;for(;;)__asm__ volatile("nop");}
    g_flash_dump.request_offset=0;g_flash_dump.request_length=160;
    for(;;) {
        off=g_flash_dump.request_offset;n=g_flash_dump.request_length;
        if(n>sizeof(g_flash_dump.data))rc=FLASH_RANGE;
        else rc=io.read(io.context,off,(void *)g_flash_dump.data,n);
        g_flash_dump.offset=off;g_flash_dump.length=rc?0:n;g_flash_dump.error=(uint32_t)rc;
        g_flash_dump.crc=rc?0:flash_crc32(0,(const void *)g_flash_dump.data,n);
        g_flash_dump.phase=rc?255:2;
        flash_dump_ready(); /* Set a breakpoint here; change next request then resume. */
    }
}
