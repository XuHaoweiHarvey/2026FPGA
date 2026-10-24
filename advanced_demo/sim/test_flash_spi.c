#include "../software/flash/flash_store.h"
volatile unsigned test_result;
#define CHECK(x) do {if(!(x)){test_result=__LINE__;return 1;}}while(0)
int main(void) {
    flash_io_t io;uint8_t data[4]={0x12,0x34,0x56,0x78},back[4];
    volatile uint32_t *control=(volatile uint32_t *)0x20000000;
    *control=0;CHECK(!flash_spi_open(&io));CHECK(flash_spi_jedec()==0xc86017);
    CHECK(io.read(0,0x800000,back,1)==FLASH_RANGE);
    CHECK(io.program(0,FLASH_SAVE_A+255,data,4)==FLASH_RANGE);
    CHECK(io.erase(0,FLASH_SAVE_A+4096)==FLASH_RANGE);
    CHECK(!io.erase(0,FLASH_SAVE_A));CHECK(!io.program(0,FLASH_SAVE_A,data,4));
    CHECK(!io.read(0,FLASH_SAVE_A,back,4));CHECK(flash_get32(data)==flash_get32(back));
    CHECK(!io.erase(0,FLASH_SAVE_A));CHECK(!io.read(0,FLASH_SAVE_A,back,4));CHECK(flash_get32(back)==0xffffffff);
    CHECK(io.program(0,0,data,4)==FLASH_RANGE && io.erase(0,0)==FLASH_RANGE);
    *control=4;CHECK(!flash_spi_open(&io)); /* stale FIFO after debugger halt */
    *control=1;CHECK(flash_spi_open(&io)==FLASH_ID);
    *control=2;CHECK(flash_spi_open(&io)==FLASH_TIMEOUT);
    *control=3;CHECK(flash_spi_open(&io)==FLASH_TIMEOUT);
    test_result=0;return 0;
}
