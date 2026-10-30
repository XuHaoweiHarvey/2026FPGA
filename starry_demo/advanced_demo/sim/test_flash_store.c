#include <stdint.h>
#include "../software/flash/flash_store.h"
volatile uint32_t test_result;
static int fail_operation=-1,operation;
static volatile uint8_t *const memory=(volatile uint8_t *)0x20000000u;
#define CHECK(x) do { if(!(x)) {test_result=__LINE__;return 1;} } while(0)
static int read_mock(void *c,uint32_t a,void *b,uint32_t n) {
    uint32_t i;(void)c;if(a>FLASH_BYTES || n>FLASH_BYTES-a)return FLASH_RANGE;
    for(i=0;i<n;i++)((uint8_t *)b)[i]=memory[a+i];return 0;
}
static int program_mock(void *c,uint32_t a,const void *b,uint32_t n) {
    uint32_t i;int interrupted=operation++==fail_operation;(void)c;
    if((a!=FLASH_SAVE_A && a!=FLASH_SAVE_B && a!=FLASH_SAVE_A+32 && a!=FLASH_SAVE_B+32)||
       !n || n>256-(a&255))return FLASH_RANGE;
    for(i=0;i<n;i++) {
        if(interrupted && i==n/2u)return FLASH_IO;
        if((memory[a+i]&((const uint8_t *)b)[i])!=((const uint8_t *)b)[i])return FLASH_IO;
        memory[a+i]&=((const uint8_t *)b)[i];
    }
    return 0;
}
static int erase_mock(void *c,uint32_t a) {
    uint32_t i;int interrupted=operation++==fail_operation;(void)c;
    if(a!=FLASH_SAVE_A && a!=FLASH_SAVE_B)return FLASH_RANGE;
    for(i=0;i<FLASH_SECTOR;i++) {
        if(interrupted && i==FLASH_SECTOR/2u)return FLASH_IO;
        memory[a+i]=255;
    }
    return 0;
}
int main(void) {
    flash_io_t io={0,read_mock,program_mock,erase_mock};
    game_save_t s,t;game_save_info_t info;uint8_t buf[160];flash_pack_t pack;
    uint32_t i,j;int rc;
    CHECK(flash_crc32(0,"123456789",9)==0xcbf43926u);
    CHECK(flash_crc32(flash_crc32(0,"1234",4),"56789",5)==0xcbf43926u);
    CHECK(game_save_load(&io,&s,&info)==FLASH_EMPTY && !info.valid && s.difficulty==1);
    s.high_score=100;CHECK(!game_save_write(&io,&s,&info));CHECK(info.slot==FLASH_SAVE_A && info.sequence==1);
    CHECK(!game_save_load(&io,&t,&info) && t.high_score==100);
    i=(uint32_t)operation;CHECK(!game_save_write(&io,&s,&info));CHECK(i==(uint32_t)operation);
    s.high_score=200;CHECK(!game_save_write(&io,&s,&info));CHECK(info.slot==FLASH_SAVE_B);
    /* Each failed erase/body/commit must preserve the previous valid slot. */
    for(i=0;i<3;i++) {
        fail_operation=operation+(int)i;s.high_score=300;
        CHECK(game_save_write(&io,&s,&info)!=FLASH_OK);fail_operation=-1;
        CHECK(!game_save_load(&io,&t,&info) && t.high_score==200);
    }
    CHECK(!game_save_write(&io,&s,&info));CHECK(info.slot==FLASH_SAVE_A);
    memory[FLASH_SAVE_A+16]^=1;CHECK(!game_save_load(&io,&t,&info) && t.high_score==200);
    s.difficulty=3;CHECK(game_save_write(&io,&s,&info)==FLASH_FORMAT);
    /* Header, table and overflow checks use the same bytes as the host tool. */
    for(i=0;i<sizeof(buf);i++)buf[i]=0;
    flash_put32(buf,FLASH_PACK_MAGIC);flash_put32(buf+4,1);flash_put32(buf+8,32);flash_put32(buf+12,4);
    flash_put32(buf+16,0x4c0000);
    for(i=0;i<4;i++) {
        uint32_t values[8]={i+1,0x10000+i*0x12c000,640,480,2560,i==3?2:1,0x12c000,0};
        for(j=0;j<8;j++)flash_put32(buf+32+i*32+j*4,values[j]);
    }
    flash_put32(buf+20,flash_crc32(0,buf+32,128));flash_put32(buf+28,flash_crc32(0,buf,28));
    for(i=0;i<160;i++)memory[i]=buf[i];
    CHECK(flash_pack_open(&io,&pack)==FLASH_OK);
    memory[28]^=1;CHECK(flash_pack_open(&io,&pack)==FLASH_CRC);memory[28]^=1;
    memory[44]^=1;CHECK(flash_pack_open(&io,&pack)==FLASH_CRC);memory[44]^=1;
    flash_put32(buf+32+4,0xfffff000u);
    flash_put32(buf+20,flash_crc32(0,buf+32,128));flash_put32(buf+28,flash_crc32(0,buf,28));
    for(i=0;i<160;i++)memory[i]=buf[i];rc=flash_pack_open(&io,&pack);CHECK(rc==FLASH_RANGE);
    test_result=0;return 0;
}
