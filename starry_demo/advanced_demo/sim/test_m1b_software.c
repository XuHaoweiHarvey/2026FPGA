#include <stdint.h>
#include <stdio.h>
#include "../software/m1b_compare/software_render.h"
#include "../software/m1b_compare/hud.h"

static uint32_t src[32*12],dst[32*12];
static int check(int condition,const char *message) {
    if(!condition) {fprintf(stderr,"FAIL %s\n",message);return 1;}
    return 0;
}
int main(void) {
    uint32_t x,y,before,after;
    int fail=0;
    for(y=0;y<12;++y) for(x=0;x<32;++x) {
        src[y*32+x]=x<8 ? UINT32_C(0x80ff00ff) : UINT32_C(0x40e8e8f0);
        dst[y*32+x]=UINT32_C(0x00182838);
    }
    m1b_software_fill(dst,32,4,2,16,7,UINT32_C(0x0030c0e0));
    for(y=0;y<12;++y) for(x=0;x<32;++x)
        fail|=check(dst[y*32+x]==((x>=4 && x<20 && y>=2 && y<9) ?
                    UINT32_C(0x0030c0e0):UINT32_C(0x00182838)),"fill bounds");
    for(y=0;y<12;++y) for(x=0;x<32;++x) dst[y*32+x]=UINT32_C(0x00182838);
    m1b_software_blit(dst,src,32,4,2,16,7,0,0);
    for(y=0;y<7;++y) for(x=0;x<16;++x)
        fail|=check(dst[(y+2)*32+x+4]==src[y*32+x],"blit X and row");
    for(y=0;y<12;++y) for(x=0;x<32;++x) dst[y*32+x]=UINT32_C(0x00182838);
    before=src[0];after=src[7*32+15];
    m1b_software_blit(dst,src,32,4,2,16,7,1,UINT32_C(0x00ff00ff));
    for(y=0;y<12;++y) for(x=0;x<32;++x) {
        uint32_t expected=UINT32_C(0x00182838);
        if(y>=2 && y<9 && x>=12 && x<20) expected=UINT32_C(0x40e8e8f0);
        fail|=check(dst[y*32+x]==expected,"key preserves background");
    }
    fail|=check(src[0]==before && src[7*32+15]==after,"source remains read-only");
    fail|=check(m1b_hud_row('A',0)==14 && m1b_hud_row('9',6)==14,
                "font glyphs");
    if(!fail) puts("PASS M1b software fill/blit/key and guards");
    return fail ? 1:0;
}
