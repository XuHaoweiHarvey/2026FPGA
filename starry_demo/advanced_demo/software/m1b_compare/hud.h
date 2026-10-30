#ifndef M1B_HUD_H
#define M1B_HUD_H
#include <stdint.h>

/* Five columns, seven rows. Only the glyphs used by the benchmark are kept. */
static const uint8_t m1b_font[36][7]={
 {14,17,17,31,17,17,17},{30,17,17,30,17,17,30},
 {14,17,16,16,16,17,14},{30,17,17,17,17,17,30},
 {31,16,16,30,16,16,31},{31,16,16,30,16,16,16},
 {14,17,16,23,17,17,14},{17,17,17,31,17,17,17},
 {31,4,4,4,4,4,31},{7,2,2,2,18,18,12},
 {17,18,20,24,20,18,17},{16,16,16,16,16,16,31},
 {17,27,21,21,17,17,17},{17,25,21,19,17,17,17},
 {14,17,17,17,17,17,14},{30,17,17,30,16,16,16},
 {14,17,17,17,21,18,13},{30,17,17,30,20,18,17},
 {15,16,16,14,1,1,30},{31,4,4,4,4,4,4},
 {17,17,17,17,17,17,14},{17,17,17,17,17,10,4},
 {17,17,17,21,21,21,10},{17,17,10,4,10,17,17},
 {17,17,10,4,4,4,4},{31,1,2,4,8,16,31},
 {14,17,19,21,25,17,14},{4,12,4,4,4,4,14},
 {14,17,1,2,4,8,31},{30,1,1,14,1,1,30},
 {2,6,10,18,31,2,2},{31,16,16,30,1,1,30},
 {14,16,16,30,17,17,14},{31,1,2,4,8,8,8},
 {14,17,17,14,17,17,14},{14,17,17,15,1,1,14}
};
static uint8_t m1b_hud_row(char ch,uint32_t row) {
    if(ch>='A' && ch<='Z') return m1b_font[(uint32_t)(ch-'A')][row];
    if(ch>='0' && ch<='9') return m1b_font[26u+(uint32_t)(ch-'0')][row];
    if(ch=='.') return row==6u ? 4u : 0u;
    if(ch==':') return row==2u || row==5u ? 4u : 0u;
    if(ch=='/') return (uint8_t)(1u<<(row<5u ? 4u-row : 0u));
    if(ch=='-') return row==3u ? 14u : 0u;
    return 0;
}
static void m1b_hud_text(volatile uint32_t *dst,uint32_t x,uint32_t y,
                         const char *s,uint32_t color) {
    uint32_t index,row,col,dx,dy;
    for(index=0;s[index];++index) for(row=0;row<7u;++row) {
        uint8_t bits=m1b_hud_row(s[index],row);
        for(col=0;col<5u;++col) if(bits&(1u<<(4u-col)))
            for(dy=0;dy<3u;++dy) for(dx=0;dx<3u;++dx)
                dst[(y+row*3u+dy)*1920u+x+index*18u+col*3u+dx]=color;
    }
}
static inline char *m1b_append(char *p,const char *s) { while(*s) *p++=*s++;return p; }
static char *m1b_u32(char *p,uint32_t n) {
    char tmp[10];uint32_t count=0;
    do {tmp[count++]=(char)('0'+n%10u);n/=10u;} while(n);
    while(count) *p++=tmp[--count];
    return p;
}
static char *m1b_fixed2(char *p,uint32_t hundredths) {
    p=m1b_u32(p,hundredths/100u);*p++='.';
    *p++=(char)('0'+(hundredths/10u)%10u);
    *p++=(char)('0'+hundredths%10u);
    return p;
}
#endif
