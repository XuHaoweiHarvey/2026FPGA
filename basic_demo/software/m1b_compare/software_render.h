#ifndef M1B_SOFTWARE_RENDER_H
#define M1B_SOFTWARE_RENDER_H
#include <stdint.h>

/* Pixel operations run on the M1a uncached DDR aliases. The caller owns Back,
 * validates geometry and drains the bridge before releasing the session. */
static inline void m1b_software_fill(volatile uint32_t *dst, uint32_t stride,
                                     uint32_t x, uint32_t y, uint32_t w, uint32_t h,
                                     uint32_t color) {
    uint32_t row,col;
    for(row=0;row<h;++row)
        for(col=0;col<w;++col) dst[(y+row)*stride+x+col]=color;
}
static inline void m1b_software_blit(volatile uint32_t *dst,
                                     const volatile uint32_t *src,
                                     uint32_t stride,uint32_t x,uint32_t y,
                                     uint32_t w,uint32_t h,uint32_t keyed,uint32_t key_rgb) {
    uint32_t row,col,pixel;
    for(row=0;row<h;++row) for(col=0;col<w;++col) {
        pixel=src[row*stride+col];
        if(!keyed || (pixel&UINT32_C(0x00ffffff))!=(key_rgb&UINT32_C(0x00ffffff)))
            dst[(y+row)*stride+x+col]=pixel;
    }
}
#endif
