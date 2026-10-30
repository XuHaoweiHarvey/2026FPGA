#ifndef M2_ASSETS_H
#define M2_ASSETS_H
#include "scene.h"

/* Three deterministic images are generated directly into DDR. No image-sized
 * array is linked into, or copied through, the 64 KiB OCRAM. */
static uint32_t m2_image_pixel(uint32_t image,uint32_t x,uint32_t y) {
    uint32_t r,g,b,band;
    if(image==0u) {
        r=(x+(y>>1))&255u;g=(y+(x>>2))&255u;
        b=(((x+y)>>5)&1u) ? 0xe0u : 0x28u;
    } else if(image==1u) {
        band=((x>>5)^(y>>5))&1u;
        r=band ? 0xf0u : 0x20u;
        g=((x>>2)^(y>>1))&255u;
        b=band ? 0x30u : 0xe8u;
    } else {
        band=((x+(y<<1))>>4)&7u;
        r=band*29u+28u;g=((x^y)>>1)&255u;
        b=255u-((y*3u+x)>>3 & 255u);
    }
    return (r<<16)|(g<<8)|b;
}
static uint32_t m2_image_base(uint32_t index) {
    return M2_ASSET_BASE+index*M2_IMAGE_BYTES;
}
#endif
