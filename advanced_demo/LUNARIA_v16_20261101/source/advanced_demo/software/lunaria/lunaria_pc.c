/* Desktop adapter. Gameplay, paging and draw commands come from the firmware
 * sources. No second implementation of bullet movement exists in this viewer. */
#include "lunaria_render.h"
#include "lunaria_pool.h"
#include "lunaria_beam.h"
#include <assert.h>
#include <string.h>
#define API __declspec(dllexport)
static lunaria_t game;
static uint32_t background[640 * 480], atlas[640 * 480], pixels[640 * 480];
static uint8_t rgb[640 * 480 * 3];
static ln_command_t commands[8192];
static uint32_t command_count, alpha = 255, back = LN_POOL_SLOT1, session;
static ln_render_stats_t stats;
#ifdef LN_EXTERNAL_POOL
static uint32_t scratch[2][LN_POOL_BYTES / 4];
static uint32_t io_reads, io_writes, io_sessions;
void ln_pool_io_begin(void) { assert(!session); session = 1; io_sessions++; }
void ln_pool_io_end(void) { assert(session); session = 0; }
uint32_t ln_pool_io_back(void) { assert(session); return back; }
static uint32_t *address(uint32_t physical) {
  uint32_t slot = physical >= LN_POOL_SLOT1, offset = physical - slot * LN_POOL_SLOT1;
  assert(session && !(physical & 3u));
  assert(offset >= LN_POOL_OFFSET && offset < LN_POOL_OFFSET + LN_POOL_BYTES);
  return &scratch[slot][(offset - LN_POOL_OFFSET) / 4];
}
uint32_t ln_pool_io_read(uint32_t physical) { io_reads++; return *address(physical); }
void ln_pool_io_write(uint32_t physical, uint32_t word) {
  assert((physical >= LN_POOL_SLOT1 ? LN_POOL_SLOT1 : 0u) == back);
  io_writes++; *address(physical) = word;
}
#endif
static uint32_t record(void *context, const ln_command_t *c) {
  (void)context;
  assert(!session && command_count < 8192);
  assert(c->x >= LN_VIEW_X && c->y >= LN_VIEW_Y && c->x + c->w <= LN_VIEW_X + 640u && c->y + c->h <= LN_VIEW_Y + 480u);
  commands[command_count++] = *c;
  return 0;
}
API void pc_init(const uint32_t *bg, const uint32_t *art) {
  memcpy(background, bg, sizeof(background)); memcpy(atlas, art, sizeof(atlas));
  ln_reset(&game, 0);
}
API uint32_t pc_configure(uint32_t limit, uint32_t spin, uint32_t opacity, uint32_t invincible) {
  if (opacity > 255 || invincible > 1 || !ln_configure(&game, limit, spin)) return 0;
  alpha = opacity; game.invincible = (uint8_t)invincible; return 1;
}
API void pc_begin(void) { ln_begin(&game); }
API void pc_phase(uint32_t phase) {
  assert(phase < 8); ln_begin(&game); game.state = LN_FIGHT; game.phase = (uint8_t)phase;
}
API void pc_tick(uint32_t buttons) {
  ln_step(&game, (uint8_t)buttons, game.last_ms + LN_TICK_MS);
}
API void pc_draw(void) {
#ifdef LN_EXTERNAL_POOL
  ln_pool_flush();
#endif
  command_count = 0;
  assert(!ln_render(&game, alpha, record, 0, &stats));
  assert(!session);
  back ^= LN_POOL_SLOT1;
  game.frames++;
}
API const ln_command_t *pc_commands(void) { return commands; }
API uint32_t pc_command_count(void) { return command_count; }
/* Same two rounded /255 operations as alpha_pixel_pipeline.v. */
API const uint8_t *pc_pixels(void) {
  uint32_t n, x, y, k;
  for (n = 0; n < command_count; ++n) {
    const ln_command_t *c = &commands[n];
    uint32_t dx = c->x - LN_VIEW_X, dy = c->y - LN_VIEW_Y;
    uint32_t src = c->op == 3 ? (c->src - LN_SPRITE_BASE) / 4u : 0;
    for (y = 0; y < c->h; ++y) for (x = 0; x < c->w; ++x) {
      uint32_t *dst = &pixels[(dy+y)*640u+dx+x];
      if (c->op == 0) *dst = c->color;
      else if (c->op == 1) *dst = background[(dy+y)*640u+dx+x];
      else {
        uint32_t color, opacity=c->color, result=0;
        if (c->op==LN_OP_BEAM) {
          int32_t nx=(int16_t)c->src,ny=(int16_t)(c->src>>16);
          color=ln_beam_pixel((int32_t)c->stride+(int32_t)x*nx+(int32_t)y*ny,c->color);
          opacity=c->color>>24;
        } else color=atlas[src+y*640u+x];
        uint32_t a = ((color >> 24) * opacity + 127u) / 255u;
        for (k = 0; k < 24; k += 8)
          result |= ((((color >> k) & 255u) * a + ((*dst >> k) & 255u) * (255u-a) + 127u) / 255u) << k;
        *dst = result;
      }
    }
  }
  for (n = 0; n < 640u*480u; ++n) {
    rgb[n*3] = (uint8_t)(pixels[n] >> 16);
    rgb[n*3+1] = (uint8_t)(pixels[n] >> 8);
    rgb[n*3+2] = (uint8_t)pixels[n];
  }
  return rgb;
}
API void pc_status(uint32_t *s) {
  s[0]=game.sim_ms; s[1]=game.state; s[2]=game.phase; s[3]=game.lives;
  s[4]=game.score; s[5]=ln_active(&game); s[6]=ln_visible(&game);
  s[7]=game.peak_bullets; s[8]=game.bullet_limit; s[9]=game.paused;
  s[10]=game.hp; s[11]=game.emissions; s[12]=game.pool_drops; s[13]=game.frames;
  s[14]=game.player_x; s[15]=game.player_y;
}
API uint32_t pc_bullet_hash(void) {
  uint32_t i, j, h=2166136261u;
  for (i=0;i<LN_CAPACITY;++i) {
    const ln_bullet_t *b = ln_bullet_read(&game,i);
    h = (h ^ b->active) * 16777619u;
    if (b->active) for (j=0;j<sizeof(*b);++j) h=(h ^ ((const uint8_t *)b)[j])*16777619u;
  }
  return h;
}
API void pc_io_counts(uint32_t *s) {
#ifdef LN_EXTERNAL_POOL
  s[0]=io_reads; s[1]=io_writes; s[2]=io_sessions;
#else
  s[0]=s[1]=s[2]=0;
#endif
}
