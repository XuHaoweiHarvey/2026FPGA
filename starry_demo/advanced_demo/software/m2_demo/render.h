#ifndef M2_RENDER_H
#define M2_RENDER_H
#include <stdint.h>
#include "scene.h"

/* CPU BLIT's measured inner kernel: read every source pixel from DDR and
 * actually store every destination pixel into the current Back row. */
static void m2_copy_image_row_cpu(volatile uint32_t *dst,
                                  const volatile uint32_t *src) {
    uint32_t x;
    for(x=0;x<M2_VIEW_W;++x) dst[x]=src[x];
}
#endif
