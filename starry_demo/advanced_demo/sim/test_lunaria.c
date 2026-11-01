#include "../software/lunaria/lunaria_render.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static lunaria_t game;
static uint32_t checks, max_commands, max_pixels;
static FILE *trace;
#define CHECK(x)                                                               \
  do {                                                                         \
    checks++;                                                                  \
    if (!(x)) {                                                                \
      fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x);                     \
      exit(1);                                                                 \
    }                                                                          \
  } while (0)
static void step(uint8_t buttons) {
  ln_step(&game, buttons, game.last_ms + 16u);
}
static void advance(uint32_t ticks, uint8_t buttons) {
  uint32_t i;
  for (i = 0; i < ticks; i++)
    step(buttons);
}
static void fight(uint8_t phase) {
  ln_reset(&game, 0);
  game.state = LN_FIGHT;
  game.phase = phase;
  game.invincible = 1;
}
static uint32_t validate(void *context, const ln_command_t *c) {
  uint32_t offset, x, y;
  FILE *output = (FILE *)context;
  CHECK(c->w && c->h && c->x >= LN_VIEW_X && c->y >= LN_VIEW_Y);
  CHECK(c->x + c->w <= LN_VIEW_X + 640u && c->y + c->h <= LN_VIEW_Y + 480u);
  CHECK(c->op == 0 || c->op == 1 || c->op == 3);
  if (c->op) {
    CHECK((c->op == 3 || !(c->x & 3u)) && !(c->w & 3u) && !(c->src & 15u));
    if (c->op == 1) {
      CHECK(c->stride == 7680u);
      CHECK(c->src == LN_BACKGROUND_BASE + 300u * 7680u + 640u * 4u);
      CHECK(c->w == 640u && c->h == 480u);
    } else {
      CHECK(c->color <= 255u && c->stride == 2560u);
      CHECK(c->src >= LN_SPRITE_BASE);
      offset = (c->src - LN_SPRITE_BASE) / 4u;
      x = offset % 640u;
      y = offset / 640u;
      CHECK(x + c->w <= 640u && y + c->h <= 480u);
    }
  }
  if (output)
    CHECK(fwrite(c, sizeof(*c), 1, output) == 1);
  return 0;
}
static void render(const char *name) {
  ln_render_stats_t stats;
  char label[32] = {0};
  if (name && trace) {
    long position = ftell(trace);
    uint32_t count = 0;
    snprintf(label, sizeof(label), "%s", name);
    CHECK(fwrite(label, sizeof(label), 1, trace) == 1);
    CHECK(fwrite(&count, 4, 1, trace) == 1);
    CHECK(ln_render(&game, 255, validate, trace, &stats) == 0);
    CHECK(fseek(trace, position + 32, SEEK_SET) == 0);
    count = stats.commands;
    CHECK(fwrite(&count, 4, 1, trace) == 1);
    CHECK(fseek(trace, 0, SEEK_END) == 0);
  } else
    CHECK(ln_render(&game, 225, validate, NULL, &stats) == 0);
  CHECK(stats.background_pixels == 640u * 480u);
  if (stats.commands > max_commands)
    max_commands = stats.commands;
  if (stats.sprite_pixels > max_pixels)
    max_pixels = stats.sprite_pixels;
}
static uint32_t expected_bullet_x, checked_bullet;
static uint32_t check_pixel_x(void *context, const ln_command_t *c) {
  (void)context;
  if (c->op == 3 && c->src == LN_SPRITE_BASE + 448u * 4u && c->w == 16 &&
      c->h == 16) {
    CHECK(c->x == LN_VIEW_X + expected_bullet_x);
    checked_bullet++;
  }
  return validate(NULL, c);
}
static void pixel_motion(void) {
  ln_render_stats_t stats;
  fight(0);
  game.bullets[0].active = 1;
  game.bullets[0].age = 20;
  game.bullets[0].y = 200 * LN_Q;
  checked_bullet = 0;
  for (expected_bullet_x = 100; expected_bullet_x < 108; expected_bullet_x++) {
    game.bullets[0].x = (int32_t)(expected_bullet_x + 8) * LN_Q;
    CHECK(ln_render(&game, 255, check_pixel_x, NULL, &stats) == 0);
  }
  CHECK(checked_bullet == 8);
  {
    volatile unsigned int bytes = sizeof(ln_bullet_t);
    CHECK(bytes == 28);
  }
}
static void patterns(void) {
  uint32_t p, i;
  const uint32_t lanes[8] = {24, 6, 1, 32, 40, 48, 12, 6};
  for (p = 0; p < 8; p++) {
    char label[32];
    fight((uint8_t)p);
    step(0);
    CHECK(ln_active(&game) == lanes[p]);
    for (i = 0; i < LN_CAPACITY; i++)
      if (game.bullets[i].active) {
        const ln_bullet_t *b = &game.bullets[i];
        int32_t dx = b->x / LN_Q - game.boss_x;
        int32_t dy = b->y / LN_Q - game.boss_y;
        CHECK(dx * dx + dy * dy <= 32 * 32);
        CHECK(abs(b->ox - game.boss_x) <= 20 && abs(b->oy - game.boss_y) <= 23);
      }
    advance(74, 0);
    snprintf(label, sizeof(label), "phase%u-1200ms", p);
    render(label);
    advance(62, 0);
    snprintf(label, sizeof(label), "phase%u-2192ms", p);
    render(label);
    CHECK(game.peak_bullets <= LN_CAPACITY);
  }
  for (p = 3; p <= 5; p++) {
    ln_bullet_t born;
    uint16_t ray;
    fight((uint8_t)p);
    advance(10, 0);
    born = game.bullets[0];
    ray = ln_aim(born.x - born.ox * LN_Q, born.y - born.oy * LN_Q);
    game.next_emit_ms = UINT32_MAX;
    game.phase_ms +=
        800; /* Boss/emitter changes after the projectile leaves. */
    game.boss_x += 60;
    advance(30, 0);
    CHECK(game.bullets[0].ox == born.ox && game.bullets[0].oy == born.oy);
    CHECK(game.bullets[0].angle == born.angle);
    CHECK(game.bullets[0].ux == born.ux && game.bullets[0].uy == born.uy);
    CHECK(abs((int16_t)(ln_aim(game.bullets[0].x - born.ox * LN_Q,
                               game.bullets[0].y - born.oy * LN_Q) -
                        ray)) < 100);
    CHECK(abs(game.bullets[0].x - born.ox * LN_Q) +
              abs(game.bullets[0].y - born.oy * LN_Q) >
          abs(born.x - born.ox * LN_Q) + abs(born.y - born.oy * LN_Q));
    /* A later birth inherits the emitter's NEW angle; the old birth does not.
     */
    game.next_emit_ms = game.phase_ms;
    step(0);
    CHECK(game.event == 2);
    CHECK(game.bullets[lanes[p]].angle != born.angle);
    CHECK(game.bullets[0].angle == born.angle);
  }
  for (p = 4; p <= 6; p++) {
    char label[32];
    uint32_t count = p * 8u, maxima = 0;
    fight(3);
    game.event = (uint16_t)(p - 4u);
    step(0);
    CHECK(ln_active(&game) == count);
    CHECK(game.event == p - 3u);
    for (i = 0; i < count; i++) {
      const ln_bullet_t *b = &game.bullets[i];
      const ln_bullet_t *prev = &game.bullets[(i + count - 1u) % count];
      const ln_bullet_t *next = &game.bullets[(i + 1u) % count];
      int32_t radius = b->ux * b->ux + b->uy * b->uy;
      int32_t rp = prev->ux * prev->ux + prev->uy * prev->uy;
      int32_t rn = next->ux * next->ux + next->uy * next->uy;
      if (radius > rp && radius > rn)
        maxima++;
    }
    CHECK(maxima == p); /* Four/six do not accidentally become eight/twelve. */
    game.next_emit_ms = UINT32_MAX;
    advance(75, 0);
    snprintf(label, sizeof(label), "rose%u-first-burst", p);
    render(label);
  }
  fight(3);
  advance(220, 0);
  CHECK(game.event == 3 && game.peak_bullets <= LN_CAPACITY);
  /* All 4/5/6-petal groups can coexist without pool overflow. */
  CHECK(game.pool_drops == 0);
  {
    ln_bullet_t old = game.bullets[0];
    step(UART_KEY_PAUSE);
    advance(30, 0);
    CHECK(game.bullets[0].x == old.x && game.bullets[0].y == old.y);
  }
  fight(7);
  advance(100, 0);
  {
    ln_bullet_t *b = &game.bullets[0];
    uint16_t angle = b->angle;
    game.player_x = 16 * LN_Q;
    advance(5, 0);
    CHECK(b->angle == angle); /* Homing stops after 1.3 seconds. */
  }
  fight(7);
  step(0);
  for (i = 0; i < 60; i++) {
    uint16_t before = game.bullets[0].angle;
    step(0);
    CHECK(abs((int16_t)(game.bullets[0].angle - before)) <= 150);
  }
}
static void collisions(void) {
  uint32_t i, old;
  fight(0);
  game.next_emit_ms = UINT32_MAX;
  for (i = 0; i < 3; i++) {
    game.shots[i].active = 1;
    game.shots[i].x = game.boss_x * LN_Q;
    game.shots[i].y = (game.boss_y + 9) * LN_Q;
  }
  step(0);
  CHECK(game.hp == LN_PHASE_HP - 3 && game.score == 300);
  for (i = 0; i < 3; i++)
    CHECK(game.effects[i].active);
  game.hp = 1;
  old = game.score;
  ln_hit(&game, 320, 128);
  CHECK(game.state == LN_WARNING && game.score == old + 100);
  CHECK(!ln_active(&game));
  ln_hit(&game, 320, 128);
  CHECK(game.score == old + 100);
  advance(62, 0);
  CHECK(game.state == LN_WARNING);
  step(0);
  CHECK(game.state == LN_FIGHT && game.hp == LN_PHASE_HP);
  fight(0);
  for (i = 0; i < LN_CAPACITY; i++) {
    game.bullets[i].active = 1;
    game.bullets[i].life = 10000;
    game.bullets[i].x = 320 * LN_Q;
    game.bullets[i].y = 120 * LN_Q;
  }
  step(0);
  CHECK(ln_active(&game) == LN_CAPACITY && game.pool_drops == 0 &&
        game.deferred_emissions == 1);
  fight(7);
  for (i = 0; i < LN_EFFECTS; i++)
    game.effects[i].active = 1;
  game.hp = 1;
  ln_hit(&game, 320, 128);
  CHECK(game.state == LN_DEFEAT && game.effects[0].active &&
        game.effects[0].fatal);
  advance(30, UART_KEY_FIRE);
  CHECK(game.death_bursts == 4);
  render("final-explosion");
  advance(20, UART_KEY_FIRE);
  CHECK(game.state == LN_VICTORY && !ln_active(&game));
  render("victory-hold");
  advance(250, UART_KEY_FIRE);
  CHECK(game.state == LN_VICTORY);
  render("victory-restart");
  step(0);
  step(UART_KEY_FIRE);
  CHECK(game.state == LN_INTRO);
  fight(0);
  game.invincible = 0;
  game.next_emit_ms = UINT32_MAX;
  for (i = 0; i < 3; i++) {
    game.hurt_ticks = 0;
    game.bullets[0].active = 1;
    game.bullets[0].life = 10;
    game.bullets[0].age = 0;
    game.bullets[0].x = game.player_x;
    game.bullets[0].y = game.player_y;
    step(0);
  }
  CHECK(!game.lives && game.state == LN_FAILURE && !ln_active(&game));
}
static void new_feedback_and_patterns(void) {
  uint32_t i, before;
  ln_bullet_t held;
  fight(3);
  step(0);
  game.next_emit_ms = UINT32_MAX;
  advance(240, 0);
  CHECK(game.bullets[3].active && game.bullets[3].age == 240);
  CHECK(game.bullets[3].y > 72 * LN_Q && game.bullets[3].y < 480 * LN_Q);
  render("rose-past-old-ttl");
  /* Large radii must retire correctly rather than overflow signed Q14 math. */
  for (i = 0; i < LN_CAPACITY; i++)
    game.bullets[i].active = 0;
  game.bullets[0].active = 1;
  game.bullets[0].kind = 3;
  game.bullets[0].age = 900;
  game.bullets[0].life = 1000;
  game.bullets[0].ux = 16384;
  game.bullets[0].uy = 0;
  game.bullets[0].vx = 294;
  step(0);
  CHECK(!game.bullets[0].active);
  fight(6);
  game.event = 1;
  step(0);
  game.next_emit_ms = UINT32_MAX;
  CHECK(game.bullets[0].kind == 8);
  advance(52, 0);
  held = game.bullets[0];
  advance(20, 0);
  CHECK(game.bullets[0].x == held.x && game.bullets[0].y == held.y);
  advance(14, 0);
  CHECK(game.bullets[0].x != held.x || game.bullets[0].y != held.y);
  before = game.bullets[0].angle;
  game.player_x = 10 * LN_Q;
  step(0);
  CHECK(game.bullets[0].angle == before);
  fight(6);
  game.event = 2;
  step(0);
  before = game.bullets[0].angle;
  step(0);
  CHECK(game.bullets[0].angle == (uint16_t)(before + 105u));
  fight(6);
  game.event = 4;
  step(0);
  game.next_emit_ms = UINT32_MAX;
  CHECK(game.lasers[0].active && game.lasers[0].age == 0);
  render("laser-warning");
  for (i = 0; i < LN_CAPACITY; i++)
    game.bullets[i].active = 0;
  for (i = 1; i < LN_LASERS; i++)
    game.lasers[i].active = 0;
  game.lasers[0].x = 320;
  game.lasers[0].y = 100;
  game.lasers[0].angle = 16384;
  game.lasers[0].age = 668;
  game.player_x = 320 * LN_Q;
  game.invincible = 0;
  step(0);
  CHECK(game.lives == 3);
  step(0);
  CHECK(game.lives == 2);
  render("laser-active");
  step(0);
  CHECK(game.lives == 2);
  game.lasers[0].age = 1792;
  step(0);
  CHECK(!game.lasers[0].active);
  fight(3);
  game.fps_x100 = 5990;
  step(0);
  CHECK(ln_visible(&game) <= ln_active(&game));
  CHECK(ln_elements(&game) == ln_visible(&game) + 2);
  CHECK(game.peak_elements == ln_elements(&game));
  before = game.peak_elements;
  for (i = 0; i < LN_CAPACITY; i++)
    game.bullets[i].active = 0;
  ln_update_metrics(&game);
  CHECK(ln_elements(&game) == 2 && game.peak_elements == before);
  render("metrics-59-9fps");
  ln_begin(&game);
  CHECK(!game.peak_elements && !game.peak_visible_bullets);
}
static void timing_and_endurance(void) {
  uint32_t i, before, phase;
  fight(3);
  advance(20, 0);
  step(UART_KEY_PAUSE);
  before = game.sim_ms;
  advance(100, 0);
  CHECK(game.paused && game.sim_ms == before);
  step(UART_KEY_PAUSE);
  CHECK(!game.paused && game.sim_ms == before);
  step(0);
  CHECK(game.sim_ms == before + 16);
  game.last_ms = UINT32_MAX - 7u;
  before = game.sim_ms;
  step(0);
  CHECK(game.sim_ms == before + 16);
  ln_step(&game, 0, game.last_ms + 1000);
  CHECK(game.dropped_ms == 872);
  for (i = 0; i < 3; i++) {
    uint32_t ticks = 0;
    ln_reset(&game, 0);
    ln_begin(&game);
    game.invincible = 1;
    while (game.state != LN_VICTORY && ticks < 7500) {
      /* Follow horizontally only; all damage is actual player-shot collision.
       */
      uint8_t buttons = UART_KEY_FIRE;
      if (game.player_x / LN_Q < game.boss_x - 3)
        buttons |= UART_KEY_RIGHT;
      if (game.player_x / LN_Q > game.boss_x + 3)
        buttons |= UART_KEY_LEFT;
      step(buttons);
      ticks++;
    }
    CHECK(game.state == LN_VICTORY && game.phase == 7 && game.score == 27400);
    CHECK(ticks * 16 >= 45000 && ticks * 16 <= 65000);
    printf("PASS collision-driven campaign %u: %u ms\n", i + 1, ticks * 16);
  }
  for (phase = 0; phase < 8; phase++) {
    fight((uint8_t)phase);
    for (i = 0; i < 4688; i++) {
      step((i / 90) % 2 ? UART_KEY_LEFT : UART_KEY_RIGHT);
      CHECK(game.state == LN_FIGHT && ln_active(&game) <= game.bullet_limit);
      CHECK(game.pool_drops == 0);
      if (i % 200 == 0)
        render(NULL);
    }
  }
  printf("PASS 600064 ms simulated endurance across all eight patterns\n");
}
static void settings_and_capacity(void) {
  const uint32_t limits[] = {64, 65, 128, 256, 384, 512, 640};
  uint32_t n, p, i;
  fight(3);
  step(0);
  CHECK(!ln_configure(&game, 0, 0) &&
        !ln_configure(&game, LN_CAPACITY + 1u, 0));
  CHECK(!ln_configure(&game, 64, 2));
  CHECK(ln_active(&game) && game.bullet_limit == 256);
  CHECK(ln_configure(&game, 128, 1));
  CHECK(!ln_active(&game) && !game.peak_visible_bullets &&
        game.hp == LN_PHASE_HP);
  ln_begin(&game);
  CHECK(game.bullet_limit == 128 && game.spin_patterns == 1);
  for (n = 0; n < sizeof(limits) / sizeof(limits[0]); n++) {
    uint32_t peak = 0, peak_visible = 0;
    for (p = 0; p < 8; p++) {
      fight((uint8_t)p);
      CHECK(ln_configure(&game, limits[n], 0));
      for (i = 0; i < 1250; i++) {
        step(0);
        CHECK(ln_active(&game) <= limits[n] && !game.pool_drops);
        CHECK(ln_visible(&game) <= ln_active(&game));
        if (i % 250 == 0)
          render(NULL);
      }
      CHECK(game.emissions > 0 && game.event > 1);
      if (game.peak_bullets > peak)
        peak = game.peak_bullets;
      if (game.peak_visible_bullets > peak_visible)
        peak_visible = game.peak_visible_bullets;
    }
    printf("PASS configurable limit %u: eight patterns, peak allocated %u, "
           "visible %u\n",
           limits[n], peak, peak_visible);
  }
  for (p = 3; p <= 5; p++) {
    ln_bullet_t born;
    uint16_t before, after;
    char label[32];
    fight((uint8_t)p);
    CHECK(ln_configure(&game, 512, 1));
    step(0);
    born = game.bullets[0];
    CHECK(born.kind == 10);
    game.next_emit_ms = UINT32_MAX;
    before = ln_aim(born.x - born.ox * LN_Q, born.y - born.oy * LN_Q);
    advance(75, 0);
    after = ln_aim(game.bullets[0].x - born.ox * LN_Q,
                   game.bullets[0].y - born.oy * LN_Q);
    CHECK(abs((int16_t)(after - before)) > 4000);
    CHECK(game.bullets[0].ux == born.ux && game.bullets[0].ox == born.ox);
    snprintf(label, sizeof(label), "phase%u-spin-512", p);
    render(label);
  }
  fight(7);
  CHECK(ln_configure(&game, 512, 1));
  advance(370, 0);
  render("fusion-512");
}
static void presentation_and_rhythm(void) {
  uint32_t n, t, e;
  ln_render_stats_t normal, paused;
  fight(3);
  step(0);
  n = game.emissions;
  CHECK(n == 32 && game.bullets[0].color == 3 && game.accent_due);
  advance(56, 0);
  CHECK(game.emissions == n);
  step(0);
  CHECK(game.emissions == n + 3 && !game.accent_due);
  while (game.event < 3)
    step(0);
  CHECK(game.next_emit_ms - game.phase_ms == 2240);
  e = game.event;
  advance(100, 0);
  CHECK(game.event == e);
  t = game.combat_ms;
  step(UART_KEY_PAUSE);
  advance(30, 0);
  CHECK(game.combat_ms == t && game.paused);
  CHECK(!ln_render(&game, 255, validate, NULL, &paused));
  step(UART_KEY_PAUSE);
  CHECK(!game.paused);
  CHECK(!ln_render(&game, 255, validate, NULL, &normal));
  CHECK(paused.commands ==
        normal.commands + 6); /* PAUSED only; HUD always visible. */
  game.state = LN_FAILURE;
  game.state_ms = 1000;
  game.score = 18700;
  game.phase = 4;
  game.lives = 0;
  game.combat_ms = 95400;
  game.peak_visible_bullets = 321;
  render("result-failure");
  advance(50, 0);
  CHECK(game.combat_ms == 95400);
  game.state = LN_VICTORY;
  game.state_ms = 4000;
  game.lives = 2;
  render("result-victory");
  step(0);
  step(UART_KEY_FIRE);
  CHECK(game.state == LN_INTRO && !game.combat_ms);
  /* A full pool cannot be exceeded by the new three-shot accent. */
  fight(3);
  game.bullet_limit = 64;
  game.accent_due = 16;
  game.next_emit_ms = UINT32_MAX;
  for (n = 0; n < 64; n++) {
    game.bullets[n].active = 1;
    game.bullets[n].life = 1000;
    game.bullets[n].x = 100 * LN_Q;
    game.bullets[n].y = 100 * LN_Q;
  }
  step(0);
  CHECK(ln_active(&game) == 64 && !game.accent_due);
  puts("PASS phrase pacing, bounded accents, frozen results and persistent "
       "battle "
       "HUD");
}
static uint32_t beam_commands;
static uint32_t count_beam(void *context, const ln_command_t *c) {
  if (c->op == 3 && c->src == LN_SPRITE_BASE + 96u * 2560u + 576u * 4u)
    beam_commands++;
  return validate(context, c);
}
static void revision_feedback(void) {
  uint32_t p, i, old_pixels = 0, old_commands = 0;
  static const uint32_t dense[8] = {67, 16, 2, 88, 110, 132, 33, 16};
  ln_render_stats_t empty, wide;
  /* Include fractional coordinates and both axes at every non-final boundary.
   */
  for (p = 0; p < 7; p++) {
    int32_t x = (93 + (int32_t)p * 61) * LN_Q + 97,
            y = (177 + (int32_t)p * 29) * LN_Q + 123;
    fight((uint8_t)p);
    game.player_x = x;
    game.player_y = y;
    game.hp = 1;
    ln_hit(&game, game.boss_x, game.boss_y);
    CHECK(game.state == LN_WARNING && game.player_x == x && game.player_y == y);
    for (i = 0; i < 63; i++) {
      step(0);
      CHECK(game.player_x == x && game.player_y == y);
    }
    CHECK(game.state == LN_FIGHT && game.phase == p + 1);
    step(0);
    CHECK(game.player_x == x && game.player_y == y);
    step(UART_KEY_RIGHT);
    CHECK(game.player_x == x + 1050 && game.player_y == y);
  }
  for (p = 0; p < 8; p++) {
    fight((uint8_t)p);
    CHECK(ln_configure(&game, 640, 0));
    step(0);
    CHECK(ln_active(&game) == dense[p]);
    for (i = 0; i < LN_CAPACITY; i++)
      if (game.bullets[i].active)
        CHECK(game.bullets[i].shape != 4);
  }
  fight(6);
  game.next_emit_ms = UINT32_MAX;
  CHECK(!ln_render(&game, 255, validate, NULL, &empty));
  game.lasers[0].active = 1;
  game.lasers[0].age = 700;
  game.lasers[0].x = 320;
  game.lasers[0].y = 100;
  game.lasers[0].angle = 16384;
  beam_commands = 0;
  CHECK(!ln_render(&game, 255, count_beam, NULL, &wide));
  for (i = 20; i < 820; i += 3) {
    int32_t y = 100 + (int32_t)i - 8;
    if (y >= 480)
      break;
    old_pixels += 16u * (y + 16 > 480 ? 480 - y : 16);
    old_commands++;
  }
  CHECK(beam_commands <= old_commands / 3);
  CHECK(wide.sprite_pixels - empty.sprite_pixels <= old_pixels * 110u / 100u);
  printf("PASS wide laser: %u commands / %u pixels; old reference %u / %u\n",
         beam_commands, wide.sprite_pixels - empty.sprite_pixels, old_commands,
         old_pixels);
  render("laser-wide");
  game.invincible = 0;
  game.player_x = 334 * LN_Q;
  step(0);
  CHECK(game.lives == 2);
  game.hurt_ticks = 0;
  game.player_x = 336 * LN_Q;
  step(0);
  CHECK(game.lives == 2);
  game.lasers[0].age = 0;
  game.player_x = 320 * LN_Q;
  step(0);
  CHECK(game.lives == 2);
  render("laser-wide-warning");
  puts("PASS all phase boundaries preserve player position, 640 burst counts, "
       "circles and wide-beam collision");
}
static void warning_movement(void) {
  uint32_t phase, i, t;
  for (phase = 0; phase < 8; phase++) {
    int32_t x = 300 * LN_Q + 17, y = 300 * LN_Q + 31;
    fight((uint8_t)phase);
    game.state = phase == 0 ? LN_INTRO : LN_WARNING;
    game.player_x = x;
    game.player_y = y;
    step(UART_KEY_RIGHT);
    CHECK(game.player_x == x + 1050 && game.player_y == y);
    step(UART_KEY_LEFT);
    CHECK(game.player_x == x && game.player_y == y);
    step(UART_KEY_UP);
    CHECK(game.player_y == y - 1050);
    step(UART_KEY_DOWN);
    CHECK(game.player_y == y);
    step(UART_KEY_RIGHT | UART_KEY_UP | UART_KEY_FIRE);
    CHECK(game.player_x == x + 720 * 181 / 256 &&
          game.player_y == y - 720 * 181 / 256);
    for (i = 0; i < LN_SHOTS; i++)
      CHECK(!game.shots[i].active);
    CHECK(!game.emissions && !ln_active(&game) && !game.combat_ms);
    x = game.player_x;
    y = game.player_y;
    t = game.state_ms;
    step(UART_KEY_PAUSE);
    advance(80, UART_KEY_RIGHT);
    CHECK(game.paused && game.state_ms == t && game.player_x == x &&
          game.player_y == y);
    step(UART_KEY_PAUSE);
    CHECK(!game.paused);
    while (game.state_ms < 992u)
      step(0);
    CHECK(game.state == (phase == 0 ? LN_INTRO : LN_WARNING));
    step(UART_KEY_RIGHT);
    CHECK(game.state == LN_FIGHT && game.player_x == x + 1050 &&
          game.player_y == y);
    CHECK(!game.combat_ms && !game.emissions && game.state_ms == 0);
    step(UART_KEY_RIGHT);
    CHECK(game.player_x == x + 2100 && game.combat_ms == 16);
  }
  fight(0);
  game.state = LN_WARNING;
  game.player_x = 16 * LN_Q;
  game.player_y = 85 * LN_Q;
  step(UART_KEY_LEFT | UART_KEY_UP);
  CHECK(game.player_x == 16 * LN_Q && game.player_y == 85 * LN_Q);
  game.player_x = 624 * LN_Q;
  game.player_y = 448 * LN_Q;
  step(UART_KEY_RIGHT | UART_KEY_DOWN);
  CHECK(game.player_x == 624 * LN_Q && game.player_y == 448 * LN_Q);
  puts("PASS movable 1008 ms preparation: input, boundaries, pause, no attacks "
       "and continuous handoff");
}
int main(int argc, char **argv) {
  if (argc > 1) {
    trace = fopen(argv[1], "wb");
    CHECK(trace);
  }
  ln_reset(&game, 0);
  render("title");
  warning_movement();
  revision_feedback();
  presentation_and_rhythm();
  patterns();
  collisions();
  new_feedback_and_patterns();
  timing_and_endurance();
  pixel_motion();
  settings_and_capacity();
  if (trace)
    fclose(trace);
  printf(
      "PASS %u checks, max %u commands / %u sprite pixels per sampled frame\n",
      checks, max_commands, max_pixels);
  return 0;
}
