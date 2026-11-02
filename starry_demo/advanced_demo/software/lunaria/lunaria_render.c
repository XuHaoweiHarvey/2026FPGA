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
  /* v12 preserves integer-pixel destination coordinates. */
  if (x >= 640)
    return;
  if (w > 640u - (uint32_t)x)
    w = (640u - (uint32_t)x) & ~3u;
  if (!w)
    return;
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
static void lettering(renderer_t *r, uint32_t x, uint32_t y, const char *s, uint32_t advance) {
  while (*s) {
    uint32_t n = (uint8_t)*s++ - 32u;
    if (n && n < 64u && x + 16u <= 640u) {
      art(r, 448u + n % 12u * 16u, 224u + n / 12u * 24u, x, y, 16u, 24u);
      r->stats->glyphs++;
    }
    x += advance;
  }
}
static void text(renderer_t *r, uint32_t x, uint32_t y, const char *s) {
  lettering(r,x,y,s,12u);
}
static void value(renderer_t *, uint32_t, uint32_t, uint32_t, uint32_t);
static void score(renderer_t *r, uint32_t points) {
#if PIXELFORGE
  text(r, 436, 448, "SCORE");
#endif
  value(r,520,448,points,PIXELFORGE?5:7);
}
#if LN_STRESS_TEST
static void number4(char *s, uint32_t n) {
  if (n > 9999u)
    n = 9999u;
  s[0] = (char)('0' + n / 1000u);
  s[1] = (char)('0' + n / 100u % 10u);
  s[2] = (char)('0' + n / 10u % 10u);
  s[3] = (char)('0' + n % 10u);
}
#elif !PIXELFORGE
static void number3(char *s, uint32_t n) {
  if (n > 999u)
    n = 999u;
  s[0] = (char)('0' + n / 100u);
  s[1] = (char)('0' + n / 10u % 10u);
  s[2] = (char)('0' + n % 10u);
}
#endif
static void metrics(renderer_t *r, const lunaria_t *g) {
#if PIXELFORGE
  char f[] = "FPS --.-";
#elif LN_STRESS_TEST
  char b[] = "B 0000/0000", a[] = "A 0000/0000", f[] = "FPS --.-",
       l[] = "MAX 0000";
  number4(b + 2, ln_visible(g));
  number4(b + 7, g->peak_visible_bullets);
  number4(a + 2, ln_elements(g));
  number4(a + 7, g->peak_elements);
  number4(l + 4, g->bullet_limit);
#else
  char b[] = "B 000/000", a[] = "A 000/000", f[] = "FPS --.-", l[] = "MAX 000";
  number3(b + 2, ln_visible(g));
  number3(b + 6, g->peak_visible_bullets);
  number3(a + 2, ln_elements(g));
  number3(a + 6, g->peak_elements);
  number3(l + 4, g->bullet_limit);
#endif
  if (g->fps_x100) {
    uint32_t fps = g->fps_x100 > 9999u ? 9999u : g->fps_x100;
    f[4] = (char)('0' + fps / 1000u);
    f[5] = (char)('0' + fps / 100u % 10u);
    f[7] = (char)('0' + fps / 10u % 10u);
  }
#if PIXELFORGE
  text(r, 20, 44, "SPRITE");
  value(r,104,44,ln_elements(g),4);
  text(r, 184, 44, f);
#else
  text(r, 280, 12, f);
  text(r, 20, 44, b);
#if LN_STRESS_TEST || PIXELFORGE
  text(r, 168, 44, a);
  text(r, 320, 44, l);
#else
  text(r, 160, 44, a);
  text(r, 292, 44, l);
#endif
#endif
  if (g->spin_patterns)
    text(r, 156, 445, "SPIN");
}
static void fill(renderer_t *r, uint32_t x, uint32_t y, uint32_t w, uint32_t h,
                 uint32_t c) {
  command(r, 0, 0, 0, x, y, w, h, c);
}
static void value(renderer_t *r, uint32_t x, uint32_t y, uint32_t n,
                  uint32_t digits) {
  char b[8];
  uint32_t i;
  b[digits] = 0;
  for (i = digits; i > 0; i--) {
    b[i - 1] = (char)('0' + n % 10);
    n /= 10;
  }
  text(r, x, y, b);
}
#ifdef __GNUC__
/* Menus are cold; retain O2 for the simulation and battle renderer. */
__attribute__((noinline, optimize("Os")))
#endif
static void
menu(renderer_t *r, const lunaria_t *g) {
  uint32_t result = g->state != LN_TITLE,
           accent = g->state == LN_FAILURE ? 0x00b6a0cd : 0x009bc9dd;
  fill(r, 72, 82, 496, 330, 0x00101728);
  fill(r, 72, 82, 496, 1, accent);
  fill(r, 72, 411, 496, 1, 0x00384b67);
  fill(r, 88, 96, 16, 2, accent);
  fill(r, 536, 96, 16, 2, accent);
  if (!result) {
    text(r, 236, 112, "A STARRY REVERIE");
    art(r, 0, 448, 192, 164, 256, 32);
    art(r, 256, 448, 224, 204, 192, 32);
    fill(r, 256, 254, 128, 1, accent);
    text(r, 176, 278, "MOVE  WASD / ARROWS");
    text(r, 188, 306, "FIRE  SPACE / CTRL");
    fill(r, 208, 350, 224, 34, 0x002b3c55);
    text(r, 240, 354, "FIRE TO BEGIN");
    text(r, 278, 432, "P PAUSE");
  } else {
    text(r, 236, 104, "VOYAGE ARCHIVE");
    if (g->state == LN_VICTORY)
      art(r, 448, 368, 224, 140, 192, 40);
    else
      text(r, 248, 148, "JOURNEY ENDS");
    fill(r, 112, 194, 416, 1, 0x00384b67);
    text(r, 116, 210, "SCORE");
    value(r, 380, 210, g->score, 7);
    text(r, 116, 242, "BATTLE TIME");
    value(r, 404, 242, (g->combat_ms / 60000) % 100, 2);
    text(r, 428, 242, ":");
    value(r, 440, 242, g->combat_ms / 1000 % 60, 2);
    text(r, 116, 274, "STAGES CLEARED");
    value(r, 440, 274, g->state == LN_VICTORY ? 8 : g->phase, 1);
    text(r, 452, 274, "/8");
    text(r, 116, 306, "LIVES");
    value(r, 224, 306, g->lives, 1);
    text(r, 308, 306, "PEAK BULLETS");
    value(r, 464, 306, g->peak_visible_bullets, PIXELFORGE ? 4 : 3);
    if (g->invincible)
      text(r, 212, 432, "ASSISTED VOYAGE");
    if (g->state_ms >= (g->state == LN_VICTORY ? 3000u : 500u)) {
      fill(r, 208, 356, 224, 32, 0x002b3c55);
      text(r, 230, 360, "FIRE TO RESTART");
    }
  }
}
#if PIXELFORGE
static void beam(renderer_t *r, const ln_laser_t *l, int32_t ux, int32_t uy) {
  /* Atlas mapping in build_pixelforge.py: x/8 [6:0], y/8 [12:7],
   * transparent side trim/4 [14:13]. Retain 2560-byte cacheable stride. */
  static const uint16_t sources[17] = {
    73|(20<<7)|(0<<13),73|(21<<7)|(1<<13),73|(22<<7)|(1<<13),73|(23<<7)|(1<<13),
    73|(24<<7)|(2<<13),73|(25<<7)|(2<<13),73|(26<<7)|(2<<13),73|(27<<7)|(2<<13),
    72|(16<<7)|(3<<13),72|(17<<7)|(2<<13),72|(18<<7)|(2<<13),72|(19<<7)|(2<<13),
    64|(43<<7)|(2<<13),72|(43<<7)|(1<<13),64|(44<<7)|(1<<13),72|(44<<7)|(1<<13),64|(45<<7)|(0<<13)
  };
  int32_t ax=ux<0?-ux:ux, ay=uy<0?-uy:uy;
  int32_t vertical=ay>=ax, major=vertical?uy:ux, minor=vertical?ux:uy;
  int32_t origin=vertical?l->y:l->x, across=vertical?l->x:l->y;
  /* Quantize only the short tile slope; place each tile on the true ray. */
  int32_t slope=(minor*16/major+(minor*major>=0?1:-1))/2;
  int32_t index=slope+8, source=sources[index], trim=(source>>13)*4;
  int32_t direction=major<0?-1:1, extent=vertical?ay:ax;
  int32_t d, sx, sy, w=56-2*trim,h=8, step;
  int32_t start=extent*74/16384;
  if(vertical){sx=(source&127)*8+trim;sy=((source>>7)&63)*8;}
  else{sx=448+index*8;sy=160+trim;h=w;w=8;}
  /* The 16px muzzle rim begins about 7px beyond the Boss's 51px ring. */
  sprite(r,608,64,l->x+ux*74/16384-16,l->y+uy*74/16384-16,32,32,255);
  for(d=start-(minor?16:0);d<extent*820/16384;d+=step){
    /* Disjoint 8px slabs, aligned for exact clipping at both x edges. */
    int32_t length=56-2*trim,offset=0;
    step=minor && d<start+24?4:8;
    int32_t along=(origin+direction*d-(direction<0?step-1:0))&~3;
    int32_t cross=across+minor*(2*(along-origin)+7)/(2*major)-28+trim;
    if(step==4){
      /* The radial muzzle covers the rear half; only draw the forward join. */
      int32_t cut=across+minor*74/16384-major*(along+1-origin-major*74/16384)/minor-cross;
      cut &= ~3;
      if(minor>0){if(cut>0){offset=cut;cross+=cut;length-=cut;}}
      else if(cut<length)length=cut;
      if(length<=0)continue;
    }
    int32_t x=vertical?cross:along,y=vertical?along:cross;
    w=vertical?length:step;h=vertical?step:length;
    if((uint32_t)(x+56)>=696u || (uint32_t)(y-16)>=464u)break;
    sprite(r,(uint32_t)(sx+(vertical?offset:0)),(uint32_t)(sy+(vertical?0:offset)),x,y,(uint32_t)w,(uint32_t)h,255);
  }
}
#endif
static void laser(renderer_t *r, const ln_laser_t *l) {
  uint32_t d;
  int32_t ux = ln_cos(l->angle), uy = ln_sin(l->angle);
#if PIXELFORGE
  if(l->age>=700u){beam(r,l,ux,uy);return;}
#endif
  for (d = 20; d < 820; d += l->age < 700u ? 24u : LN_LASER_STEP) {
    int32_t x = l->x + ux * (int32_t)d / 16384;
    int32_t y = l->y + uy * (int32_t)d / 16384;
    if (x < -32 || x > 672 || y < 40 || y > 512)
      break;
    sprite(r, l->age < 700u ? 608u : 576u, 96, x - 16, y - 16, LN_LASER_TILE,
           LN_LASER_TILE, 255u);
  }
}
#if PIXELFORGE
static void hit_art(renderer_t *r,uint32_t f,int32_t x,int32_t y,uint32_t alpha){
  sprite(r,f<6?448+f*32:576,f<6?448:64+(f-6)*32,x,y,32,32,alpha);
}
#endif

#if PIXELFORGE && defined(__GNUC__)
__attribute__((noinline))
#endif
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
  if (g->state == LN_TITLE || g->state == LN_VICTORY ||
      g->state == LN_FAILURE) {
    menu(&r, g);
    return r.error;
  }
  art(&r, 0, 448, 16, 12, 256, 32);
  metrics(&r, g);
#if PIXELFORGE
  lettering(&r,420,18,names[g->phase],16);
  {
    uint32_t percent=(ln_boss_hp(g)*100u+8u*LN_PHASE_HP-1u)/(8u*LN_PHASE_HP);
    char hp[]="000%";
    hp[0]=percent==100u?'1':' ';
    hp[1]=percent>=10u?(char)('0'+percent/10u%10u):' ';
    hp[2]=(char)('0'+percent%10u);
    text(&r,352,44,hp);
  }
#else
  text(&r, 420, 18, LN_STRESS_TEST ? "STRESS" : names[g->phase]);
#endif
#if !PIXELFORGE
  if (g->phase == 3) {
    uint32_t event = g->event ? g->event - 1u : 0u;
    char petals[2] = {(char)(event % 5u == 3u ? '3' : '4' + event % 3u), 0};
    text(&r, PIXELFORGE ? 576u : 484u, 18, event % 5u == 4u ? "7/3" : petals);
  }
#endif
  command(&r, 0, 0, 0, 420, 52, 196, 3, 0x00251c36);
  if (ln_boss_hp(g)) {
    uint32_t width = 196u * ln_boss_hp(g) / (8u * LN_PHASE_HP);
    command(&r, 0, 0, 0, 420, 52, width ? width : 1u, 3, 0x00edbadf);
  }
  for (i = 0; i < g->lives; i++)
    sprite(&r, 560, 64, (int32_t)((PIXELFORGE ? 92u : 20u) + i * 20u), 445, 16, 16, 220);
#if PIXELFORGE
  text(&r,20,440,"LIVES");
#else
  if (g->invincible)
    text(&r, 96, 445, "INV");
#endif
  score(&r, g->score);
#if LN_STRESS_TEST
  if (alpha)
    for (i = 0; i < g->stress_active; i++) {
      const ln_bullet_t *b = &g->bullets[i];
      /* Live stress bullets are fully inside the viewport; no generic clipping.
       */
      command(&r, i ? LN_COMMAND_REPEAT_ALPHA : 3u, LN_SPRITE_BASE + 64u * 2560u + 448u * 4u, 2560u,
              (uint32_t)(b->x / LN_Q - LN_STRESS_BULLET_SIZE / 2u),
              (uint32_t)(b->y / LN_Q - LN_STRESS_BULLET_SIZE / 2u),
              LN_STRESS_BULLET_SIZE, LN_STRESS_BULLET_SIZE, alpha);
      r.stats->sprite_pixels += LN_STRESS_BULLET_SIZE * LN_STRESS_BULLET_SIZE;
    }
#else
  for (i = 0; i < LN_CAPACITY; i++)
    if (g->bullets[i].active) {
      const ln_bullet_t *b = &g->bullets[i];
      uint32_t a = alpha;
      if (b->age < 5u)
        a = a * b->age / 5u;
      uint32_t sx = 448u + b->shape * 16u, sy = b->color * 16u;
      if (b->shape == 1u)
        sx = 512u + (((b->angle + 16384u + 4096u) >> 13) & 7u) * 16u;
      if (b->shape == 4u)
        sx = 448u; /* legacy star IDs are circles */
      sprite(&r, sx, sy, b->x / LN_Q - 8, b->y / LN_Q - 8, 16, 16, a);
    }
#endif
  for (i = 0; i < LN_LASERS; i++)
    if (g->lasers[i].active)
      laser(&r, &g->lasers[i]);
  for (i = 0; i < LN_SHOTS; i++)
    if (g->shots[i].active)
      sprite(&r, 528, 64, g->shots[i].x / LN_Q - 8, g->shots[i].y / LN_Q - 8,
             16, 16, 255);
  if (g->state == LN_DEFEAT)
    boss_alpha = g->state_ms >= 400u ? 0u : 255u - g->state_ms * 255u / 400u;
  f = (g->sim_ms / 90u) % 16u;
  if (g->phase >= 3 && g->phase <= 5)
    f = (ln_emitter_angle(g) % 10923u) * 16u / 10923u;
  sprite(&r, f % 4u * 112u, f / 4u * 112u, g->boss_x - 56, g->boss_y - 56, 112,
         112, boss_alpha);
  if (g->flash_ms)
    sprite(&r, 448u + ((128u - g->flash_ms) / 32u) * 16u, 80, g->boss_x - 8,
           g->boss_y + 16, 16, 16, 255);
  if (g->state == LN_FIGHT && g->phase >= 3 && g->phase <= 5 &&
      g->next_emit_ms > g->phase_ms && g->next_emit_ms - g->phase_ms < 240u)
    sprite(&r, 448, 80, g->boss_x - 8, g->boss_y + 16, 16, 16, 180);
  for (i = 0; i < LN_EFFECTS; i++)
    if (g->effects[i].active) {
      const ln_effect_t *e = &g->effects[i];
      f = (uint32_t)e->age * 8u / (e->fatal ? 400u : 120u);
      if (f > 7u)
        f = 7u;
#if PIXELFORGE
      hit_art(&r,f,e->x-16,e->y-16,255);
#else
      sprite(&r, 448u + f % 4u * 32u, 160u + f / 4u * 32u, e->x - 16, e->y - 16,
             32, 32, 255);
#endif
      if (e->fatal) {
        uint32_t j;
        for (j = 0; j < 6; j++) {
          uint16_t a = (uint16_t)(j * 65536u / 6u);
          int32_t radius = e->age / 10;
          int32_t x = e->x + radius * ln_cos(a) / 16384,
                  y = e->y + radius * ln_sin(a) / 16384;
#if PIXELFORGE
          hit_art(&r,f,x-16,y-16,210);
#else
          sprite(&r, 448u + f % 4u * 32u, 160u + f / 4u * 32u, x - 16, y - 16,
                 32, 32, 210);
#endif
        }
      }
    }
  f = (g->sim_ms / 100u) % 8u;
  sprite(&r, 448u + f % 4u * 32u, 96u + f / 4u * 32u, g->player_x / LN_Q - 16,
         g->player_y / LN_Q - 16, 32, 32,
         g->hurt_ticks && g->hurt_ticks % 8u < 4u ? 90 : 255);
  command(&r, 0, 0, 0, ((uint32_t)(g->player_x / LN_Q)) & ~3u,
          (uint32_t)(g->player_y / LN_Q), 2, 2, 0x00ffffff);
  if (g->state == LN_INTRO || g->state == LN_WARNING) {
    art(&r, 448, 408, 224, 264, 192, 32);
    text(&r, 260, 300, names[g->phase]);
  }
  if (g->paused)
    text(&r, 284, 240, "PAUSED");
  return r.error;
}
