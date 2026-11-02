#include "../software/lunaria/lunaria_render.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static lunaria_t game;
static unsigned checks;
#define CHECK(x)                                                               \
  do {                                                                         \
    checks++;                                                                  \
    if (!(x)) {                                                                \
      fprintf(stderr, "FAIL %d: %s\n", __LINE__, #x);                          \
      exit(1);                                                                 \
    }                                                                          \
  } while (0)
static void step(uint8_t keys) { ln_step(&game, keys, game.last_ms + 16); }
static uint32_t submit(void *context, const ln_command_t *c) {
  CHECK(c->x >= LN_VIEW_X && c->y >= LN_VIEW_Y && c->w && c->h);
  CHECK(c->x + c->w <= LN_VIEW_X + 640 && c->y + c->h <= LN_VIEW_Y + 480);
  CHECK(c->op == 0 || c->op == 1 || c->op == 3);
  if (c->op)
    CHECK(!(c->src & 15) && !(c->w & 3));
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
  CHECK(!ln_render(&game, 255, submit, trace, &stats));
  CHECK(fseek(trace, pos + 32, SEEK_SET) == 0);
  CHECK(fwrite(&stats.commands, 4, 1, trace) == 1);
  CHECK(fseek(trace, 0, SEEK_END) == 0);
  printf("FRAME %s: B=%u A=%u commands=%u pixels=%u\n", name, ln_visible(&game),
         ln_elements(&game), stats.commands, stats.sprite_pixels);
}
int main(int argc, char **argv) {
  const unsigned limits[] = {64,  65,  128, 256, 384, 512,
                             610, 640, 704, 768, 832};
  unsigned n, i, j;
  FILE *trace;
  CHECK(LN_STRESS_TEST == 1 && argc == 2);
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
      for (j = 0; j < LN_CAPACITY; j++) {
        CHECK((game.bullets[j].active != 0) == (j < game.stress_active));
        if (game.bullets[j].active) {
          const ln_bullet_t *b = &game.bullets[j];
          CHECK(b->x >= 8 * LN_Q && b->x <= 632 * LN_Q && b->y >= 80 * LN_Q &&
                b->y <= 472 * LN_Q);
          CHECK(b->ux == (int32_t)((int64_t)b->vx * ln_cos(b->angle) / 16384));
          CHECK(b->uy == (int32_t)((int64_t)b->vx * ln_sin(b->angle) / 16384));
          CHECK(game.bullets[j].kind == 0 && game.bullets[j].shape == 0);
          if (game.bullets[j].age == 5)
            CHECK(game.bullets[j].x == game.boss_x * LN_Q &&
                  game.bullets[j].y == game.boss_y * LN_Q);
        }
      }
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
        if (game.bullets[j].angle == prior[i].angle) {
          CHECK(game.bullets[j].x == prior[i].x + prior[i].ux);
          CHECK(game.bullets[j].y == prior[i].y + prior[i].uy);
          CHECK(game.bullets[j].age == prior[i].age + 1);
          found++;
        }
      CHECK(found == 1);
    }
  }
  for (i = 0; i < 37500; i++) {
    step(0);
    CHECK(game.state == LN_FIGHT && game.invincible &&
          ln_visible(&game) == LN_CAPACITY);
  }
  {
    ln_render_stats_t stats;
    CHECK(!ln_render(&game, 255, submit, NULL, &stats));
    CHECK(stats.sprite_pixels < 203648u); /* Old 640/16x16 sampled workload. */
    printf("FRAME stress-832-steady: B=%u A=%u commands=%u pixels=%u\n",
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
  printf("PASS %u stress checks; 600000 ms steady 832 visible bullets; no "
         "board FPS claim\n",
         checks);
  return 0;
}
