#ifndef LUNARIA_RENDER_H
#define LUNARIA_RENDER_H
#include "lunaria.h"
#define LN_SPRITE_BASE UINT32_C(0x01384000)
#define LN_BACKGROUND_BASE UINT32_C(0x02000000)
/* Software-only repeat descriptor; first command always supplies full Alpha state. */
#define LN_COMMAND_REPEAT_ALPHA 0x103u
#define LN_VIEW_X 640u
#define LN_VIEW_Y 300u
typedef struct {
  uint32_t op, src, stride, x, y, w, h, color;
} ln_command_t;
typedef uint32_t (*ln_submit_fn)(void *, const ln_command_t *);
typedef struct {
  uint32_t commands, sprite_pixels, background_pixels, glyphs;
} ln_render_stats_t;
uint32_t ln_render(const lunaria_t *g, uint32_t alpha, ln_submit_fn submit,
                   void *context, ln_render_stats_t *stats);
#endif
