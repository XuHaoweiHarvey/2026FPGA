/* Bounded SPI0 transport using the generated RV32 FIFO register contract.
 * External GD25LQ64: 24-bit addresses, single data line, mode 0, no QE changes.
 * Runtime erase/program are restricted to the two save sectors, never assets.
 */
#include "flash_store.h"
#include "soc.h"
#ifndef SYSTEM_SPI_0_IO_CTRL
#error "Generate Sapphire with SPI0 enabled before building Flash firmware"
#endif
#define SPI_BASE SYSTEM_SPI_0_IO_CTRL
#define SPI_DEPTH SYSTEM_SPI_0_IO_PARAMETER_CMD_FIFO_DEPTH
static uint32_t jedec_id;
static int transport_fault;
static uint32_t rd(uintptr_t a) {return *(volatile uint32_t *)a;}
static void wr(uintptr_t a,uint32_t v) {*(volatile uint32_t *)a=v;}
static uint64_t clock_ticks(void) {
    uint32_t h,l,h2;
    do {h=rd(SYSTEM_CLINT_CTRL+0xbffcu);l=rd(SYSTEM_CLINT_CTRL+0xbff8u);
        h2=rd(SYSTEM_CLINT_CTRL+0xbffcu);}while(h!=h2);
    return ((uint64_t)h<<32)|l;
}
static int expired(uint64_t start,uint32_t ms) {
    return clock_ticks()-start>(uint64_t)SYSTEM_CLINT_HZ*ms/1000u;
}
static void delay_us(uint32_t us) {
    uint64_t start=clock_ticks();while(clock_ticks()-start<(uint64_t)SYSTEM_CLINT_HZ*us/1000000u){}
}
static int command(uint32_t value) {
    uint64_t start=clock_ticks();uint32_t polls=0;
    if(transport_fault)return FLASH_IO;
    while(!(rd(SPI_BASE+4)&0xffffu)) {
        if(++polls==1000000u || expired(start,50)) {transport_fault=1;return FLASH_TIMEOUT;}
    }
    wr(SPI_BASE,value);return FLASH_OK;
}
static int receive(uint8_t *out) {
    uint64_t start;uint32_t polls=0;int rc=command(1u<<9);if(rc)return rc;
    start=clock_ticks();
    while(!(rd(SPI_BASE+4)>>16)) {
        if(++polls==1000000u || expired(start,50)) {transport_fault=1;return FLASH_TIMEOUT;}
    }
    *out=(uint8_t)rd(SPI_BASE);return FLASH_OK;
}
static int begin(uint8_t opcode) {
    int rc=command((1u<<11)|0x80u);if(rc)return rc;
    return command((1u<<8)|opcode);
}
static int end(void) {
    uint64_t start;uint32_t polls=0;int rc=command(1u<<11);if(rc)return rc;
    start=clock_ticks();
    while((rd(SPI_BASE+4)&0xffffu)!=SPI_DEPTH) {
        if(++polls==1000000u || expired(start,50)) {transport_fault=1;return FLASH_TIMEOUT;}
    }
    /* FIFO empty can precede the last physical SS hold/disable clocks. */
    delay_us(10);return FLASH_OK;
}
static int finish(int rc) {int e;if(transport_fault)return rc; e=end();return rc?rc:e;}
static int address(uint32_t a) {
    int rc=command((1u<<8)|((a>>16)&255u));if(rc)return rc;
    rc=command((1u<<8)|((a>>8)&255u));if(rc)return rc;
    return command((1u<<8)|(a&255u));
}
static int status(uint8_t *s) {
    int rc=begin(0x05);if(rc)return rc;rc=receive(s);return finish(rc);
}
static int ready(void) {
    uint64_t start=clock_ticks();uint8_t s;int rc;
    do {rc=status(&s);if(rc)return rc;if(!(s&1u))return FLASH_OK;
        if(expired(start,3000))return FLASH_TIMEOUT;
    }while(1);
}
static int write_enable(void) {
    uint8_t s;int rc=ready();if(rc)return rc;
    rc=begin(0x06);if(rc)return rc;rc=end();if(rc)return rc;
    rc=status(&s);if(rc)return rc;return (s&2u)?FLASH_OK:FLASH_IO;
}
static int read_bytes(void *context,uint32_t a,void *buf,uint32_t n) {
    uint8_t *p=(uint8_t *)buf;uint32_t i;int rc;(void)context;
    if(a>FLASH_BYTES || n>FLASH_BYTES-a)return FLASH_RANGE;
    if(!n)return FLASH_OK;
    rc=ready();if(rc)return rc;rc=begin(0x03);if(rc)return rc;
    rc=address(a);if(rc)return finish(rc);
    for(i=0;i<n;i++) {rc=receive(&p[i]);if(rc)break;}
    return finish(rc);
}
static int save_range(uint32_t a,uint32_t n) {
#if defined(FLASH_MAINTENANCE_BUILD)
    /* Only the separate, explicitly loaded maintenance ELF has this capability. */
    if(a<FLASH_ASSET_END && n<=FLASH_ASSET_END-a)return 1;
#endif
    if(a>=FLASH_SAVE_A && a<FLASH_SAVE_A+FLASH_SECTOR)
        return n<=FLASH_SAVE_A+FLASH_SECTOR-a;
    if(a>=FLASH_SAVE_B && a<FLASH_SAVE_B+FLASH_SECTOR)
        return n<=FLASH_SAVE_B+FLASH_SECTOR-a;
    return 0;
}
static int program_bytes(void *context,uint32_t a,const void *buf,uint32_t n) {
    const uint8_t *p=(const uint8_t *)buf;uint32_t i;int rc;(void)context;
    if(!n || n>256u-(a&255u) || !save_range(a,n))return FLASH_RANGE;
    rc=write_enable();if(rc)return rc;rc=begin(0x02);if(rc)return rc;
    rc=address(a);if(rc)return finish(rc);
    for(i=0;i<n;i++) {rc=command((1u<<8)|p[i]);if(rc)break;}
    rc=finish(rc);return rc?rc:ready();
}
static int erase_sector(void *context,uint32_t a) {
    int rc;(void)context;
    if((a&4095u) || !save_range(a,FLASH_SECTOR))return FLASH_RANGE;
    rc=write_enable();if(rc)return rc;rc=begin(0x20);if(rc)return rc;
    rc=address(a);rc=finish(rc);return rc?rc:ready();
}
uint32_t flash_spi_jedec(void) {return jedec_id;}
int flash_spi_open(flash_io_t *io) {
    uint8_t id[3];unsigned i;int rc;
    transport_fault=0;jedec_id=0;
    wr(SPI_BASE+8,0);wr(SPI_BASE+0x20,19); /* mode 0; 100 MHz / 40 = 2.5 MHz */
    wr(SPI_BASE+0x24,5);wr(SPI_BASE+0x28,5);wr(SPI_BASE+0x2c,7);
    rc=end();if(rc)return rc;
    /* An IDE halt can leave unread responses from the previous application. */
    for(i=0;i<SPI_DEPTH && (rd(SPI_BASE+4)>>16);i++)(void)rd(SPI_BASE);
    if(rd(SPI_BASE+4)>>16)return FLASH_IO;
    rc=begin(0xab);if(rc)return rc;rc=end();if(rc)return rc;
    delay_us(40);rc=begin(0x9f);if(rc)return rc;
    for(i=0;i<3;i++){rc=receive(&id[i]);if(rc)return finish(rc);}
    rc=end();if(rc)return rc;
    jedec_id=(uint32_t)id[0]<<16|(uint32_t)id[1]<<8|id[2];
    /* Fail closed for a different density, vendor or bus stuck high/low. */
    if(jedec_id!=0xc86017u)return FLASH_ID;
    io->context=0;io->read=read_bytes;io->program=program_bytes;io->erase=erase_sector;
    return ready();
}
