#include "../software/lunaria/lunaria_render.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static lunaria_t game;
static unsigned checks;
static unsigned char velocity_valid[655][328];
static unsigned bullet_commands, hud_seen;
static char hud[3][20];
#define CHECK(x)                                                               \
  do {                                                                         \
    checks++;                                                                  \
    if (!(x)) {                                                                \
      fprintf(stderr, "FAIL %d: %s\n", __LINE__, #x);                          \
      exit(1);                                                                 \
    }                                                                          \
  } while (0)
static void step(uint8_t keys) { ln_step(&game, keys, game.last_ms + 16); }
static void begin_render(void) {
  bullet_commands = hud_seen = 0;
  snprintf(hud[0], sizeof(hud[0]), "B %04u/%04u", ln_visible(&game),
           game.peak_visible_bullets);
  snprintf(hud[1], sizeof(hud[1]), "A %04u/%04u", ln_elements(&game),
           game.peak_elements);
  snprintf(hud[2], sizeof(hud[2]), "MAX %04u", game.bullet_limit);
}
static void end_render(void) {
  CHECK(bullet_commands == game.stress_active);
  CHECK(hud_seen == 27); /* Both current/peak counters and MAX, four digits. */
}
static uint32_t submit(void *context, const ln_command_t *c) {
  CHECK(c->x >= LN_VIEW_X && c->y >= LN_VIEW_Y && c->w && c->h);
  CHECK(c->x + c->w <= LN_VIEW_X + 640 && c->y + c->h <= LN_VIEW_Y + 480);
  CHECK(c->op == 0 || c->op == 1 || c->op == 3 || c->op == LN_COMMAND_REPEAT_ALPHA);
  if (c->op)
    CHECK(!(c->src & 15) && !(c->w & 3));
  if ((c->op == 3 || c->op == LN_COMMAND_REPEAT_ALPHA) && c->src == LN_SPRITE_BASE + 64u * 2560u + 448u * 4u) {
    const ln_bullet_t *b;
    CHECK(bullet_commands < game.stress_active);
    CHECK(c->op == (bullet_commands ? LN_COMMAND_REPEAT_ALPHA : 3u));
    b = &game.bullets[bullet_commands++];
    CHECK(c->w == 8 && c->h == 8);
    CHECK(c->x == LN_VIEW_X + (uint32_t)(b->x / LN_Q) - 4);
    CHECK(c->y == LN_VIEW_Y + (uint32_t)(b->y / LN_Q) - 4);
  }
  if (c->op == 3 && c->y == LN_VIEW_Y + 44 && c->h == 24) {
    static const unsigned starts[3] = {20, 168, 320};
    unsigned k;
    for (k = 0; k < 3; k++) {
      unsigned x = c->x - LN_VIEW_X;
      if (x >= starts[k] && x < starts[k] + strlen(hud[k]) * 12) {
        unsigned slot = (x - starts[k]) / 12;
        unsigned glyph = (unsigned)hud[k][slot] - 32;
        CHECK((x - starts[k]) % 12 == 0 && glyph > 0 && glyph < 64);
        CHECK(c->src == LN_SPRITE_BASE + (224u + glyph / 12u * 24u) * 2560u +
                            (448u + glyph % 12u * 16u) * 4u);
        hud_seen++;
      }
    }
  }
  if (context)
    CHECK(fwrite(c, sizeof(*c), 1, (FILE *)context) == 1);
  return 0;
}
static void frame(FILE *trace, const char *name) {
  ln_render_stats_t stats;
  char label[32] = {0};
  uint32_t count = 0;
  long pos = ftell(trace);
  snprintf(label, sizeof(label), "%s", name);
  CHECK(fwrite(label, 32, 1, trace) == 1 && fwrite(&count, 4, 1, trace) == 1);
  begin_render();
  CHECK(!ln_render(&game, 255, submit, trace, &stats));
  end_render();
  CHECK(fseek(trace, pos + 32, SEEK_SET) == 0);
  CHECK(fwrite(&stats.commands, 4, 1, trace) == 1);
  CHECK(fseek(trace, 0, SEEK_END) == 0);
  printf("FRAME %s: B=%u A=%u commands=%u pixels=%u\n", name, ln_visible(&game),
         ln_elements(&game), stats.commands, stats.sprite_pixels);
}
/* Independent closed-form trajectory: no dense-pool/retirement implementation
 * is copied. A dropped, duplicated or twice-moved survivor violates this
 * oracle. */
static void check_trajectory(const ln_bullet_t *b) {
  int32_t dx=b->ux,dy=b->uy;
  int32_t distance=b->y-128*LN_Q;
  CHECK(dy>0 && distance>=0 && distance%dy==0);
  CHECK(b->x == 320*LN_Q + (distance/dy)*dx);
  CHECK(dx>=-327 && dx<=327 && dy<=327 && velocity_valid[dx+327][dy]);
  CHECK(b->x >= 8 * LN_Q && b->x <= 632 * LN_Q && b->y >= 80 * LN_Q &&
        b->y <= 472 * LN_Q);
}
int main(int argc, char **argv) {
  const unsigned limits[] = {64,  65,  128, 256,  384,  512,  610, 640,
                             704, 768, 832, 1000, 1024, 1152, 1280, 1536, 1792, 2048};
  unsigned n, i, j, packed_size = sizeof(ln_bullet_t);
  FILE *trace;
  CHECK(LN_STRESS_TEST == 1 && argc == 2);
  CHECK(packed_size == 12 && LN_CAPACITY == 2048);
  for (i=4096;i<=28672;i++) {
    int dx=(int)((int64_t)327*ln_cos((uint16_t)i)/16384);
    int dy=(int)((int64_t)327*ln_sin((uint16_t)i)/16384);
    velocity_valid[dx+327][dy]=1;
  }
  trace = fopen(argv[1], "wb");
  CHECK(trace);
  ln_reset(&game, 0);
  CHECK(game.state == LN_FIGHT && game.invincible);
  CHECK(!ln_configure(&game, 0, 0) && !ln_configure(&game, LN_CAPACITY + 1, 0));
  for (n = 0; n < sizeof(limits) / sizeof(limits[0]); n++) {
    CHECK(ln_configure(&game, limits[n], 1));
    CHECK(!game.spin_patterns);
    for (i = 0; i < 1000; i++) {
      game.invincible =
          0; /* Even a bad external setting must not disable it. */
      step(UART_KEY_FIRE);
      CHECK(game.state == LN_FIGHT && game.invincible && game.lives == 3 &&
            game.phase == 0);
      CHECK(ln_active(&game) <= limits[n] &&
            ln_active(&game) == ln_visible(&game));
      if (i >= (limits[n] + 31) / 32 - 1)
        CHECK(ln_visible(&game) == limits[n]);
      for (j = 0; j < game.stress_active; j++)
        check_trajectory(&game.bullets[j]);
      for (j = 0; j < LN_LASERS; j++)
        CHECK(!game.lasers[j].active);
    }
    CHECK(!game.pool_drops && !game.deferred_emissions);
    printf("PASS limit %u: visible %u, continuous fire score %u\n", limits[n],
           ln_visible(&game), game.score);
    if (limits[n] == 640) {
      frame(trace, "stress-640-firing");
      for (i = 0; i < 100; i++)
        step(0);
      frame(trace, "stress-640-steady");
    }
    if (limits[n] >= 1000) {
      ln_render_stats_t stats;
      begin_render();
      CHECK(!ln_render(&game, 255, submit, NULL, &stats));
      end_render();
    }
  }
  CHECK(game.score > LN_PHASE_HP * 100u);
  {
    unsigned score = game.score, count = ln_active(&game);
    int32_t x = game.player_x;
    game.hp = 1;
    ln_hit(&game, game.boss_x, game.boss_y);
    CHECK(game.hp == LN_PHASE_HP && game.score == score + 100 &&
          game.state == LN_FIGHT && ln_active(&game) == count);
    step(UART_KEY_RIGHT);
    CHECK(game.player_x > x);
    step(UART_KEY_LEFT);
    CHECK(game.player_x == x);
    step(UART_KEY_PAUSE);
    x = game.player_x;
    step(UART_KEY_RIGHT);
    CHECK(game.paused && game.player_x == x);
    step(UART_KEY_PAUSE);
    CHECK(!game.paused);
  }
  /* Force removal at both ends and prove each swapped survivor moves once. */
  {
    static ln_bullet_t prior[LN_CAPACITY];
    static unsigned char matched[LN_CAPACITY];
    ln_reset(&game, 0);
    CHECK(ln_configure(&game, LN_CAPACITY, 0));
    for (i = 0; i < (LN_CAPACITY + 31) / 32; i++)
      step(0);
    memcpy(prior, game.bullets, sizeof(prior));
    game.bullets[0].x = 700 * LN_Q;
    game.bullets[LN_CAPACITY - 1].x = 700 * LN_Q;
    step(0);
    CHECK(ln_visible(&game) == LN_CAPACITY);
    for (i = 1; i < LN_CAPACITY - 1; i++) {
      unsigned found = 0;
      for (j = 0; j < game.stress_active; j++)
        if (!matched[j] && game.bullets[j].x == prior[i].x + prior[i].ux &&
            game.bullets[j].y == prior[i].y + prior[i].uy &&
            game.bullets[j].ux == prior[i].ux && game.bullets[j].uy == prior[i].uy) {
          CHECK(game.bullets[j].x == prior[i].x + prior[i].ux);
          CHECK(game.bullets[j].y == prior[i].y + prior[i].uy);
          found++; matched[j]=1; break;
        }
      CHECK(found == 1);
    }
  }
  for (i = 0; i < 37500; i++) {
    step(0);
    CHECK(game.state == LN_FIGHT && game.invincible &&
          ln_visible(&game) == LN_CAPACITY);
    if (!(i % 64))
      for (j = 0; j < game.stress_active; j++)
        check_trajectory(&game.bullets[j]);
  }
  {
    ln_render_stats_t stats;
    begin_render();
    CHECK(!ln_render(&game, 255, submit, NULL, &stats));
    end_render();
    CHECK(stats.sprite_pixels >= LN_CAPACITY * 64u); /* No omitted bullets. */
    printf("FRAME stress-2048-steady: B=%u A=%u commands=%u pixels=%u\n",
           ln_visible(&game), ln_elements(&game), stats.commands,
           stats.sprite_pixels);
  }
  CHECK(ln_configure(&game, 64, 0));
  CHECK(ln_active(&game) == 0);
  step(0);
  step(0);
  CHECK(ln_visible(&game) == 64);
  ln_begin(&game);
  CHECK(game.state == LN_FIGHT && game.invincible && game.bullet_limit == 64);
  fclose(trace);
  printf("PASS %u stress checks; 600000 ms steady 2048 visible bullets; no "
         "board FPS claim\n",
         checks);
  return 0;
}
