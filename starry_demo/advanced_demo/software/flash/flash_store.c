#include "flash_store.h"

uint32_t flash_get32(const uint8_t *p) {
    return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;
}
void flash_put32(uint8_t *p,uint32_t v) {
    unsigned i; for(i=0;i<4;i++) p[i]=(uint8_t)(v>>(i*8));
}
/* Incremental IEEE CRC32: start with zero, pass the returned CRC to next chunk. */
uint32_t flash_crc32(uint32_t crc,const void *data,uint32_t n) {
    const uint8_t *p=(const uint8_t *)data; unsigned b;
    crc=~crc;
    while(n--) { crc^=*p++; for(b=0;b<8;b++) crc=(crc>>1)^(0xedb88320u & (0u-(crc&1u))); }
    return ~crc;
}
int flash_pack_open(const flash_io_t *io,flash_pack_t *pack) {
    uint8_t h[32],table[128]; uint32_t i,j,crc;
    int rc=io->read(io->context,0,h,sizeof(h)); if(rc) return rc;
    if(flash_get32(h)==0xffffffffu) return FLASH_EMPTY;
    if(flash_get32(h)!=FLASH_PACK_MAGIC || flash_get32(h+4)!=1 ||
       flash_get32(h+8)!=32 || flash_get32(h+12)!=4 || flash_get32(h+24)!=0)
        return FLASH_FORMAT;
    if(flash_crc32(0,h,28)!=flash_get32(h+28)) return FLASH_CRC;
    pack->total=flash_get32(h+16);
    if(pack->total<160 || pack->total>FLASH_ASSET_END) return FLASH_RANGE;
    rc=io->read(io->context,32,table,sizeof(table)); if(rc) return rc;
    crc=flash_crc32(0,table,sizeof(table)); if(crc!=flash_get32(h+20)) return FLASH_CRC;
    for(i=0;i<4;i++) {
        flash_asset_t *e=&pack->entries[i]; uint32_t words[8];
        for(j=0;j<8;j++) words[j]=flash_get32(table+i*32+j*4);
        e->id=words[0];e->offset=words[1];e->width=words[2];e->height=words[3];
        e->stride=words[4];e->format=words[5];e->length=words[6];e->crc=words[7];
        /* Four exact windows match the existing source/CPU DDR guards. */
        if(e->id!=i+1 || e->width!=640 || e->height!=480 || e->stride!=2560 ||
           e->format!=(i==3?FLASH_FORMAT_ARGB:FLASH_FORMAT_XRGB) || e->length!=0x12c000)
            return FLASH_FORMAT;
        if(e->offset<0x10000 || (e->offset & 4095) || e->offset>pack->total ||
           e->length>pack->total-e->offset) return FLASH_RANGE;
        if(i && e->offset<pack->entries[i-1].offset+pack->entries[i-1].length)
            return FLASH_RANGE;
    }
    return FLASH_OK;
}
int flash_asset_verify(const flash_io_t *io,const flash_asset_t *e) {
    uint8_t buf[256];uint32_t off=0,crc=0,n;int rc;
    if(e->offset>FLASH_ASSET_END || e->length>FLASH_ASSET_END-e->offset) return FLASH_RANGE;
    while(off<e->length) {
        n=e->length-off; if(n>sizeof(buf))n=sizeof(buf);
        rc=io->read(io->context,e->offset+off,buf,n);if(rc)return rc;
        crc=flash_crc32(crc,buf,n);off+=n;
    }
    return crc==e->crc?FLASH_OK:FLASH_CRC;
}

#define SAVE_MAGIC 0x56533246u /* F2SV */
#define SAVE_COMMIT 0x54494d43u /* CMIT */
static int save_read(const flash_io_t *io,uint32_t slot,game_save_t *s,uint32_t *seq) {
    uint8_t b[36];int rc=io->read(io->context,slot,b,sizeof(b));if(rc)return rc;
    if(flash_get32(b)!=SAVE_MAGIC || flash_get32(b+4)!=1 || flash_get32(b+12)!=12 ||
       flash_get32(b+32)!=SAVE_COMMIT) return FLASH_EMPTY;
    if(flash_crc32(0,b,28)!=flash_get32(b+28))return FLASH_CRC;
    *seq=flash_get32(b+8);s->high_score=flash_get32(b+16);
    s->difficulty=flash_get32(b+20);s->flags=flash_get32(b+24);
    if(s->difficulty>2 || s->flags!=0)return FLASH_FORMAT;
    return FLASH_OK;
}
int game_save_load(const flash_io_t *io,game_save_t *save,game_save_info_t *info) {
    game_save_t a,b;uint32_t sa=0,sb=0;int ra,rb;
    info->valid=0;info->slot=0;info->sequence=0;
    ra=save_read(io,FLASH_SAVE_A,&a,&sa);rb=save_read(io,FLASH_SAVE_B,&b,&sb);
    /* A transport failure is never silently treated as an erased device. */
    if(ra==FLASH_IO || ra==FLASH_TIMEOUT || rb==FLASH_IO || rb==FLASH_TIMEOUT)
        return ra==FLASH_IO||ra==FLASH_TIMEOUT?ra:rb;
    if(ra && rb) {save->high_score=0;save->difficulty=1;save->flags=0;return FLASH_EMPTY;}
    if(!rb && (ra || (int32_t)(sb-sa)>0)) {
        *save=b;info->slot=FLASH_SAVE_B;info->sequence=sb;
    } else { *save=a;info->slot=FLASH_SAVE_A;info->sequence=sa; }
    info->valid=1;return FLASH_OK;
}
int game_save_write(const flash_io_t *io,const game_save_t *save,game_save_info_t *info) {
    uint8_t b[36],check[36];uint32_t i,slot,seq;game_save_t previous;game_save_info_t old;
    int rc;
    if(save->difficulty>2 || save->flags)return FLASH_FORMAT;
    rc=game_save_load(io,&previous,&old);if(rc!=FLASH_OK && rc!=FLASH_EMPTY)return rc;
    if(rc==FLASH_OK && previous.high_score==save->high_score &&
       previous.difficulty==save->difficulty && previous.flags==save->flags) {
        *info=old;return FLASH_OK;
    }
    slot=old.valid && old.slot==FLASH_SAVE_A?FLASH_SAVE_B:FLASH_SAVE_A;
    seq=old.valid?old.sequence+1:1;
    for(i=0;i<sizeof(b);i++)b[i]=0xff;
    flash_put32(b,SAVE_MAGIC);flash_put32(b+4,1);flash_put32(b+8,seq);flash_put32(b+12,12);
    flash_put32(b+16,save->high_score);flash_put32(b+20,save->difficulty);flash_put32(b+24,save->flags);
    flash_put32(b+28,flash_crc32(0,b,28));flash_put32(b+32,SAVE_COMMIT);
    rc=io->erase(io->context,slot);if(rc)return rc;
    rc=io->program(io->context,slot,b,32);if(rc)return rc;
    rc=io->read(io->context,slot,check,32);if(rc)return rc;
    for(i=0;i<32;i++)if(check[i]!=b[i])return FLASH_CRC;
    /* Atomic commit is last; the old slot remains untouched throughout. */
    rc=io->program(io->context,slot+32,b+32,4);if(rc)return rc;
    rc=io->read(io->context,slot,check,36);if(rc)return rc;
    for(i=0;i<36;i++)if(check[i]!=b[i])return FLASH_CRC;
    info->slot=slot;info->sequence=seq;info->valid=1;return FLASH_OK;
}
