#include "lunaria_render.h"
typedef struct {
  ln_submit_fn submit;
  void *context;
  ln_render_stats_t *stats;
  uint32_t error;
} renderer_t;
static void command(renderer_t *r, uint32_t op, uint32_t src, uint32_t stride,
                    uint32_t x, uint32_t y, uint32_t w, uint32_t h,
                    uint32_t color) {
  ln_command_t c;
  if (r->error)
    return;
  c.op = op;
  c.src = src;
  c.stride = stride;
  c.x = x + LN_VIEW_X;
  c.y = y + LN_VIEW_Y;
  c.w = w;
  c.h = h;
  c.color = color;
  r->error = r->submit(r->context, &c);
  r->stats->commands++;
}
static void sprite(renderer_t *r, uint32_t sx, uint32_t sy, int32_t x,
                   int32_t y, uint32_t w, uint32_t h, uint32_t alpha) {
  uint32_t trim;
  if (!alpha)
    return;
  if (x < 0) {
    trim = ((uint32_t)(-x) + 3u) & ~3u;
    if (trim >= w)
      return;
    sx += trim;
    w -= trim;
    x = 0;
  }
  x &= ~3;
  if (x >= 640)
    return;
  if (w > 640u - (uint32_t)x)
    w = 640u - (uint32_t)x;
  if (y < 72) {
    trim = (uint32_t)(72 - y);
    if (trim >= h)
      return;
    sy += trim;
    h -= trim;
    y = 72;
  }
  if (y >= 480)
    return;
  if (h > 480u - (uint32_t)y)
    h = 480u - (uint32_t)y;
  command(r, 3, LN_SPRITE_BASE + sy * 2560u + sx * 4u, 2560u, (uint32_t)x,
          (uint32_t)y, w, h, alpha);
  r->stats->sprite_pixels += w * h;
}
static void art(renderer_t *r, uint32_t sx, uint32_t sy, uint32_t x, uint32_t y,
                uint32_t w, uint32_t h) {
  command(r, 3, LN_SPRITE_BASE + sy * 2560u + sx * 4u, 2560u, x, y, w, h, 255);
  r->stats->sprite_pixels += w * h;
}
static void text(renderer_t *r, uint32_t x, uint32_t y, const char *s) {
  while (*s) {
    uint32_t n = (uint8_t)*s++ - 32u;
    if (n < 64u && x + 16u <= 640u) {
      art(r, 448u + n % 12u * 16u, 224u + n / 12u * 24u, x, y, 16u, 24u);
      r->stats->glyphs++;
    }
    x += 12u;
  }
}
static void score(renderer_t *r, uint32_t value) {
  char s[8];
  uint32_t i;
  s[7] = 0;
  for (i = 0; i < 7; i++) {
    s[6 - i] = (char)('0' + value % 10u);
    value /= 10u;
  }
  text(r, 520, 448, s);
}
static void number3(char *s, uint32_t n) {
  if (n > 999u)
    n = 999u;
  s[0] = (char)('0' + n / 100u);
  s[1] = (char)('0' + n / 10u % 10u);
  s[2] = (char)('0' + n % 10u);
}
static void metrics(renderer_t *r, const lunaria_t *g) {
  char b[] = "B 000/000", a[] = "A 000/000", f[] = "FPS --.-", l[] = "MAX 000";
  number3(b + 2, ln_visible(g));
  number3(b + 6, g->peak_visible_bullets);
  number3(a + 2, ln_elements(g));
  number3(a + 6, g->peak_elements);
  number3(l + 4, g->bullet_limit);
  if (g->fps_x100) {
    uint32_t fps = g->fps_x100 > 9999u ? 9999u : g->fps_x100;
    f[4] = (char)('0' + fps / 1000u);
    f[5] = (char)('0' + fps / 100u % 10u);
    f[7] = (char)('0' + fps / 10u % 10u);
  }
  text(r, 280, 12, f);
  text(r, 20, 44, b);
  text(r, 160, 44, a);
  text(r, 292, 44, l);
  if (g->spin_patterns)
    text(r, 292, 68, "SPIN");
}
static void laser(renderer_t *r, const ln_laser_t *l, uint32_t color) {
  uint32_t d;
  int32_t ux = ln_cos(l->angle), uy = ln_sin(l->angle);
  for (d = 20; d < 820; d += l->age < 700u ? 16u : 3u) {
    int32_t x = l->x + ux * (int32_t)d / 16384;
    int32_t y = l->y + uy * (int32_t)d / 16384;
    if (x < -16 || x > 656 || y < 56 || y > 496)
      break;
    sprite(r, 448, color * 16u, x - 8, y - 8, 16, 16,
           l->age < 700u ? 70u : 245u);
  }
}
uint32_t ln_render(const lunaria_t *g, uint32_t alpha, ln_submit_fn submit,
                   void *context, ln_render_stats_t *stats) {
  renderer_t r;
  uint32_t i, f, boss_alpha = 255;
  const char *names[8] = {"RING",      "SPIRAL",   "SUNFLOWER", "ROSE",
                          "PENTAGRAM", "HEXAGRAM", "CURTAIN",   "FUSION"};
  stats->commands = stats->sprite_pixels = stats->background_pixels =
      stats->glyphs = 0;
  r.submit = submit;
  r.context = context;
  r.stats = stats;
  r.error = 0;
  command(&r, 1, LN_BACKGROUND_BASE + LN_VIEW_Y * 7680u + LN_VIEW_X * 4u, 7680,
          0, 0, 640, 480, 0);
  stats->background_pixels = 640u * 480u;
  art(&r, 0, 448, 16, 12, 256, 32);
  metrics(&r, g);
  if (g->state == LN_TITLE) {
    art(&r, 0, 448, 192, 176, 256, 32);
    art(&r, 256, 448, 224, 216, 192, 32);
    text(&r, 228, 286, "FIRE TO START");
    text(&r, 176, 320, "ARROWS MOVE  P PAUSE");
    return r.error;
  }
  if (g->state == LN_VICTORY || g->state == LN_FAILURE) {
    if (g->state == LN_VICTORY)
      art(&r, 448, 368, 224, 190, 192, 40);
    else
      text(&r, 260, 192, "GAME OVER");
    text(&r, 260, 250, "SCORE");
    {
      char s[8];
      uint32_t n = g->score;
      s[7] = 0;
      for (i = 0; i < 7; i++) {
        s[6 - i] = (char)('0' + n % 10u);
        n /= 10u;
      }
      text(&r, 248, 280, s);
    }
    if (g->state_ms >= (g->state == LN_VICTORY ? 3000u : 500u))
      text(&r, 224, 338, "FIRE TO RESTART");
    return r.error;
  }
  text(&r, 420, 18, names[g->phase]);
  if (g->phase == 3) {
    uint32_t event = g->event ? g->event - 1u : 0u;
    char petals[2] = {(char)(event % 5u == 3u ? '3' : '4' + event % 3u), 0};
    text(&r, 484, 18, event % 5u == 4u ? "7/3" : petals);
  }
  command(&r, 0, 0, 0, 420, 52, 196, 3, 0x00251c36);
  if (ln_boss_hp(g)) {
    uint32_t width = 196u * ln_boss_hp(g) / (8u * LN_PHASE_HP);
    command(&r, 0, 0, 0, 420, 52, width ? width : 1u, 3, 0x00edbadf);
  }
  for (i = 0; i < g->lives; i++)
    sprite(&r, 480, 32, (int32_t)(20 + i * 20u), 445, 16, 16, 220);
  if (g->invincible)
    text(&r, 96, 445, "INV");
  score(&r, g->score);
  for (i = 0; i < LN_CAPACITY; i++)
    if (g->bullets[i].active) {
      const ln_bullet_t *b = &g->bullets[i];
      uint32_t a = alpha;
      if (b->age < 5u)
        a = a * b->age / 5u;
      uint32_t sx = 448u + b->shape * 16u, sy = b->color * 16u;
      if (b->shape == 1u) sx = 512u + (((b->angle + 16384u + 4096u) >> 13) & 7u) * 16u;
      if (b->shape == 4u) {sx = 512u + b->color * 16u; sy = 48u;}
      sprite(&r, sx, sy, b->x / LN_Q - 8,
             b->y / LN_Q - 8, 16, 16, a);
    }
  for (i = 0; i < LN_LASERS; i++)
    if (g->lasers[i].active)
      laser(&r, &g->lasers[i], i % 3u);
  for (i = 0; i < LN_SHOTS; i++)
    if (g->shots[i].active)
      sprite(&r, 480, 32, g->shots[i].x / LN_Q - 8, g->shots[i].y / LN_Q - 8,
             16, 16, 255);
  if (g->state == LN_DEFEAT)
    boss_alpha = g->state_ms >= 400u ? 0u : 255u - g->state_ms * 255u / 400u;
  f = (g->sim_ms / 90u) % 16u;
  if (g->phase >= 3 && g->phase <= 5)
    f = (ln_emitter_angle(g) % 10923u) * 16u / 10923u;
  sprite(&r, f % 4u * 112u, f / 4u * 112u, g->boss_x - 56, g->boss_y - 56, 112,
         112, boss_alpha);
  for (i = 0; i < LN_EFFECTS; i++)
    if (g->effects[i].active) {
      const ln_effect_t *e = &g->effects[i];
      f = (uint32_t)e->age * 8u / (e->fatal ? 400u : 120u);
      if (f > 7u)
        f = 7u;
      sprite(&r, 448u + f % 4u * 32u, 160u + f / 4u * 32u, e->x - 16, e->y - 16,
             32, 32, 255);
      if (e->fatal) {
        uint32_t j;
        for (j = 0; j < 6; j++) {
          uint16_t a = (uint16_t)(j * 65536u / 6u);
          int32_t radius = e->age / 10;
          int32_t x = e->x + radius * ln_cos(a) / 16384,
                  y = e->y + radius * ln_sin(a) / 16384;
          sprite(&r, 448u + f % 4u * 32u, 160u + f / 4u * 32u, x - 16, y - 16,
                 32, 32, 210);
        }
      }
    }
  f = (g->sim_ms / 100u) % 8u;
  sprite(&r, 448u + f % 4u * 32u, 96u + f / 4u * 32u, g->player_x / LN_Q - 16,
         g->player_y / LN_Q - 16, 32, 32,
         g->hurt_ticks && g->hurt_ticks % 8u < 4u ? 90 : 255);
  command(&r, 0, 0, 0, ((uint32_t)(g->player_x / LN_Q)) & ~3u,
          (uint32_t)(g->player_y / LN_Q), 2, 2, 0x00ffffff);
  if (g->state == LN_INTRO || g->state == LN_WARNING)
    art(&r, 448, 408, 224, 264, 192, 32);
  if (g->paused)
    text(&r, 284, 240, "PAUSED");
  return r.error;
}
