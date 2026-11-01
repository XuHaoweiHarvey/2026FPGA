#include "lunaria.h"
#include "lunaria_tables.h"
static const uint16_t intervals[8] = {560, 180, 48, 1440, 1440, 1440, 520, 720};
/* Boundary retirement is primary. This long watchdog only bounds stationary
 * rose samples and very slow shots; it never fades a normal mid-screen shot. */
static const uint8_t lanes[8] = {24, 6, 1, 48, 40, 48, 12, 6};
static int32_t absi(int32_t x) { return x < 0 ? -x : x; }
static int32_t mul14(int32_t x, int32_t y) {
  return (int32_t)((int64_t)x * y / 16384);
}
static uint32_t isqrt32(uint32_t n) {
  uint32_t result = 0, bit = UINT32_C(1) << 30;
  while (bit > n)
    bit >>= 2;
  while (bit) {
    if (n >= result + bit) {
      n -= result + bit;
      result = (result >> 1) + bit;
    } else
      result >>= 1;
    bit >>= 2;
  }
  return result;
}
int16_t ln_sin(uint16_t a) {
  uint8_t index = (uint8_t)(a >> 8);
  int32_t first = ln_sine[index], next = ln_sine[(uint8_t)(index + 1u)];
  return (int16_t)(first + (next - first) * (int32_t)(a & 255u) / 256);
}
int16_t ln_cos(uint16_t a) { return ln_sin((uint16_t)(a + 16384u)); }
uint16_t ln_emitter_angle(const lunaria_t *g) {
  return (uint16_t)(g->phase_ms * 5u);
}
uint16_t ln_aim(int32_t x, int32_t y) {
  uint32_t ax = (uint32_t)absi(x), ay = (uint32_t)absi(y);
  uint16_t a;
  if (!ax && !ay)
    return 0;
  a = ax >= ay ? ln_atan[ay * 128u / ax]
               : (uint16_t)(16384u - ln_atan[ax * 128u / ay]);
  if (x < 0)
    a = (uint16_t)(32768u - a);
  return y < 0 ? (uint16_t)(0u - a) : a;
}
static void clear_actors(lunaria_t *g) {
  uint32_t i;
  ln_clear_bullets(g);
  g->allocation_cursor = 0;
  for (i = 0; i < LN_SHOTS; i++)
    g->shots[i].active = 0;
  for (i = 0; i < LN_LASERS; i++)
    g->lasers[i].active = 0;
}
static void effect(lunaria_t *g, int16_t x, int16_t y, uint8_t fatal) {
  uint32_t i, slot = LN_EFFECTS;
  for (i = 0; i < LN_EFFECTS; i++)
    if (!g->effects[i].active) {
      slot = i;
      break;
    }
  if (slot == LN_EFFECTS && fatal)
    for (i = 0; i < LN_EFFECTS; i++)
      if (!g->effects[i].fatal) {
        slot = i;
        break;
      }
  if (slot < LN_EFFECTS) {
    g->effects[slot].x = x;
    g->effects[slot].y = y;
    g->effects[slot].age = 0;
    g->effects[slot].active = 1;
    g->effects[slot].fatal = fatal;
  }
}
void ln_reset(lunaria_t *g, uint32_t now) {
  uint32_t i;
  uint8_t *p = (uint8_t *)g;
  for (i = 0; i < sizeof(*g); i++)
    p[i] = 0;
  ln_clear_bullets(g);
  g->last_ms = now;
  g->lives = 3;
  g->hp = LN_PHASE_HP;
  g->boss_x = 320;
  g->boss_y = 128;
  g->player_x = 320 * LN_Q;
  g->player_y = 424 * LN_Q;
  g->state = LN_TITLE;
  g->bullet_limit = LN_DEFAULT_LIMIT;
}
void ln_begin(lunaria_t *g) {
  uint32_t now = g->last_ms;
  uint32_t limit = g->bullet_limit, spin = g->spin_patterns;
  uint8_t inv = g->invincible;
  ln_reset(g, now);
  g->invincible = inv;
  g->bullet_limit = limit;
  g->spin_patterns = spin;
  g->state = LN_INTRO;
  g->previous_buttons = UART_KEY_FIRE;
  g->current_elements = 2; /* Empty introduction: player and Boss. */
}
uint32_t ln_configure(lunaria_t *g, uint32_t limit, uint32_t spin) {
  if (limit < LN_MIN_LIMIT || limit > LN_CAPACITY || spin > 1u)
    return 0;
  clear_actors(g);
  g->bullet_limit = limit;
  g->spin_patterns = spin;
  g->phase_ms = g->next_emit_ms = g->next_shot_ms = 0;
  g->event = 0;
  g->deferred_emissions = 0;
  ln_update_metrics(g);
  g->peak_bullets = g->peak_visible_bullets = g->peak_elements = 0;
  return 1;
}
static void enter_phase(lunaria_t *g) {
  clear_actors(g);
  g->phase_ms = 0;
  g->next_emit_ms = 0;
  g->next_shot_ms = 0;
  g->event = 0;
  g->state = LN_FIGHT;
  g->state_ms = 0;
  g->hp = LN_PHASE_HP;
}
uint32_t ln_active(const lunaria_t *g) {
  uint32_t n = 0, i;
  for (i = 0; i < g->bullet_limit; i++)
    n += ln_bullet_read(g, i)->active != 0;
  return n;
}
static uint32_t visible(int32_t x, int32_t y) {
  return x >= 0 && x < 640 * LN_Q && y >= 72 * LN_Q && y < 480 * LN_Q;
}
uint32_t ln_visible(const lunaria_t *g) {
  uint32_t n = 0, i;
  for (i = 0; i < g->bullet_limit; i++) {
    const ln_bullet_t *b = ln_bullet_read(g, i);
    n += b->active && visible(b->x, b->y);
  }
  return n;
}
static uint32_t elements(const lunaria_t *g, uint32_t n) {
  uint32_t i;
  if (g->state < LN_INTRO || g->state > LN_DEFEAT)
    return 0;
  for (i = 0; i < LN_SHOTS; i++)
    n += g->shots[i].active && visible(g->shots[i].x, g->shots[i].y);
  for (i = 0; i < LN_EFFECTS; i++)
    n += g->effects[i].active &&
         visible(g->effects[i].x * LN_Q, g->effects[i].y * LN_Q);
  for (i = 0; i < LN_LASERS; i++)
    n += g->lasers[i].active != 0;
  return n + 1u + (g->state != LN_DEFEAT || g->state_ms < 400u);
}
uint32_t ln_elements(const lunaria_t *g) {
  return elements(g, ln_visible(g));
}
void ln_update_metrics(lunaria_t *g) {
  uint32_t n = ln_visible(g), a = elements(g, n);
  g->current_visible = n;
  g->current_elements = a;
  if (n > g->peak_visible_bullets)
    g->peak_visible_bullets = n;
  if (a > g->peak_elements)
    g->peak_elements = a;
}
uint32_t ln_boss_hp(const lunaria_t *g) {
  return g->state >= LN_DEFEAT ? 0u : (7u - g->phase) * LN_PHASE_HP + g->hp;
}
void ln_hit(lunaria_t *g, int16_t x, int16_t y) {
  if (g->state != LN_FIGHT || !g->hp)
    return;
  effect(g, x, y, 0);
  g->hp--;
  g->score += 100;
  if (!g->hp) {
    clear_actors(g);
    g->state_ms = 0;
    if (g->phase == 7) {
      uint32_t i;
      for (i = 0; i < LN_EFFECTS; i++)
        g->effects[i].active = 0;
      g->state = LN_DEFEAT;
      g->death_bursts = 1;
      effect(g, g->boss_x, g->boss_y, 1);
      g->score += 5000;
    } else {
      g->phase++;
      g->state = LN_WARNING;
    }
  }
}
static ln_bullet_t *allocate(lunaria_t *g) {
  uint32_t i;
  for (i = 0; i < g->bullet_limit; i++) {
    uint32_t index = (g->allocation_cursor + i) % g->bullet_limit;
    if (!ln_bullet_read(g, index)->active) {
      ln_bullet_t *b = ln_bullet(g, index);
      uint8_t *p = (uint8_t *)b;
      uint32_t j;
      for (j = 0; j < sizeof(*b); j++)
        p[j] = 0;
      b->active = 1;
      g->allocation_cursor = index + 1u;
      return b;
    }
  }
  g->pool_drops++;
  return 0;
}
static void star_vector(uint32_t lane, uint32_t count, uint8_t six, int16_t *x,
                        int16_t *y) {
  uint32_t edge, f;
  uint16_t a, b;
  int32_t ra, rb;
  if (six) {
    uint32_t half = count / 2u;
    uint32_t u = (lane % half) * 3u * 256u / half;
    edge = u / 256u;
    f = u % 256u;
    a = (uint16_t)(49152u + (lane / half) * 10923u + edge * 21845u);
    b = (uint16_t)(a + 21845u);
    ra = rb = 16384;
  } else {
    uint32_t u = lane * 10u * 256u / count;
    edge = u / 256u;
    f = u % 256u;
    a = (uint16_t)(49152u + edge * 65536u / 10u);
    b = (uint16_t)(a + 6554u);
    ra = edge % 2u ? 6554 : 16384;
    rb = edge % 2u ? 16384 : 6554;
  }
  *x = (int16_t)((mul14(ln_cos(a), ra) * (int32_t)(256u - f) +
                  mul14(ln_cos(b), rb) * (int32_t)f) /
                 256);
  *y = (int16_t)((mul14(ln_sin(a), ra) * (int32_t)(256u - f) +
                  mul14(ln_sin(b), rb) * (int32_t)f) /
                 256);
}
static uint32_t emit(lunaria_t *g) {
  uint32_t i, p = g->phase, count = lanes[p], active = ln_active(g);
  uint32_t petals = 4u + g->event % 3u;
  uint32_t variant = g->phase_ms / 2800u;
  uint32_t fractional = p == 3 && g->event % 5u == 4u;
  if (p == 3 && g->event % 5u == 3u)
    petals = 3;
  if (fractional)
    petals = 7;
  if (p == 3)
    count = petals * 8u;
  if (p == 7 && g->event % 5u == 1u)
    count = 30;
  if (p == 7 && g->event % 5u == 3u)
    count = 32;
  /* Denser settings add complete edge samples, keeping symmetry intact.
   * At small limits keep at least the original complete 3/4/5/6/7-petal
   * and star outline; lower the firing cadence instead of cutting it. */
  if (g->bullet_limit > LN_DEFAULT_LIMIT) {
    uint32_t unit = p == 3 ? petals : p == 4 ? 10u : p == 5 ? 6u : 1u;
    count = count * g->bullet_limit / LN_DEFAULT_LIMIT / unit * unit;
  }
  if (active + count > g->bullet_limit) {
    g->deferred_emissions++;
    return 0; /* Admit an entire pattern; never cut off half a flower. */
  }
  /* Reuse low holes once per burst so a small live set stays in resident RAM,
   * even when the configured ceiling is 4096. Advance within the burst. */
  g->allocation_cursor = 0;
  for (i = 0; i < count; i++) {
    ln_bullet_t *b = allocate(g);
    uint16_t a = 0;
    int32_t speed = 88;
    if (!b)
      continue;
    b->ox = g->boss_x;
    b->oy = g->boss_y;
    b->color = (uint8_t)((i + g->event) % 3u);
    b->life =
        1000; /* 16 seconds, with ordinary shots leaving the view first. */
    if (p == 0) {
      a = (uint16_t)(i * 65536u / count + g->event * 782u);
      b->color = (uint8_t)(g->event % 3u);
      if (variant % 3u == 1u) {
        a = (uint16_t)(ln_aim(g->player_x / LN_Q - b->ox,
                              g->player_y / LN_Q - b->oy) +
                       ((int32_t)(i % 3u) - 1) * 1800);
        speed = 80 + (int32_t)(i * 8u / count) * 8;
        b->shape = 1;
      }
      if (variant % 3u == 2u) {
        /* Leave a readable sector centred downward; only later rings turn. */
        a = (uint16_t)(19000u + i * 59000u / count);
        b->shape = 1;
      }
    }
    if (p == 1) {
      a = (uint16_t)(i * 65536u / count + (variant % 2u && i % 2u
                                               ? 0u - g->phase_ms * 14u
                                               : g->phase_ms * 14u));
      speed = 90;
      b->color = (uint8_t)(i % 2u);
      b->shape = 1;
    }
    if (p == 2) {
      a = (uint16_t)((g->event * count + i) * 25033u + 49152u);
      speed = 70;
      b->color = (uint8_t)(g->event % 9u < 6u ? 2u : g->event % 2u);
      b->kind = 2;
      if (variant % 2u) {
        a = (uint16_t)((g->event * count + i) * 25033u);
        b->color = (uint8_t)(g->event % 3u);
      }
    }
    if (p == 3) {
      /* Odd roses cover the curve once on [0, pi); even roses use
       * abs(cos((petals/2)*theta)) on [0, 2*pi). Both give exactly
       * the requested number of petals, including four and six. */
      uint16_t t = (uint16_t)(i *
                              (fractional    ? 98304u
                               : petals & 1u ? 32768u
                                             : 65536u) /
                              count);
      int32_t rho = ln_cos(
          (uint16_t)(fractional ? i * 7u * 32768u / count
                                : (petals & 1u ? petals : petals / 2u) * t));
      if (!(petals & 1u) && rho < 0)
        rho = -rho;
      b->ux = (int16_t)mul14(ln_cos(t), rho);
      b->uy = (int16_t)mul14(ln_sin(t), rho);
      a = 16384;
      speed = 72;
      b->kind = 3;
      b->color = (uint8_t)(g->event % 3u);
    }
    if (p == 4 || p == 5) {
      star_vector(i, count, (uint8_t)(p == 5), &b->ux, &b->uy);
      if (p == 4 && variant % 2u) {
        /* Regular polygons use a radial speed envelope, frozen at birth. */
        uint32_t sides = 3u + g->event % 4u;
        uint16_t t = (uint16_t)(i * 65536u / count);
        int32_t c = ln_cos((uint16_t)(t % (65536u / sides) - 32768u / sides));
        int32_t rho = (int32_t)ln_cos((uint16_t)(32768u / sides)) * 16384 / c;
        b->ux = (int16_t)mul14(ln_cos(t), rho);
        b->uy = (int16_t)mul14(ln_sin(t), rho);
      }
      if (p == 5 && g->event % 2u)
        star_vector(i, count, 0, &b->ux, &b->uy);
      a = 0;
      speed = 72;
      b->kind = 3;
      b->shape = 4;
      b->color = (uint8_t)(p == 5 ? i / (count / 2u) : g->event % 3u);
    }
    if (p == 6) {
      b->ox += (int16_t)(i < count / 2u ? -20 : 20);
      b->oy += 23;
      a = (uint16_t)(16384 + (2 * (int32_t)i - (int32_t)count + 1) * 886 * 12 / (int32_t)count);
      speed = 42;
      b->kind = 6;
      if (g->event % 3u == 1u)
        b->kind = 8; /* Slow, stop, re-aim, launch. */
      if (g->event % 3u == 2u)
        b->kind = 9; /* Independent constant turn. */
      b->shape = (uint8_t)(i % 3u == 1u ? 0u : 1u);
    }
    if (p == 7) {
      a = (uint16_t)(16384 + (2 * (int32_t)i - (int32_t)count + 1) * 1460 * 6 / (int32_t)count);
      speed = 80;
      b->kind = 7;
      b->shape = 3;
      b->color = (uint8_t)(i % 2u ? 1u : 2u);
      if (g->event % 5u == 1u) {
        a = (uint16_t)(i * 65536u / count + ln_emitter_angle(g));
        speed = 68;
        b->kind = 9;
        b->shape = 4;
      }
      if (g->event % 5u == 2u) {
        a = (uint16_t)(i * 65536u / count + g->phase_ms * 17u);
        b->kind = 6;
      }
      if (g->event % 5u == 3u) {
        uint16_t t = (uint16_t)(i * 65536u / count);
        int32_t rho = ln_cos((uint16_t)(t * 2u));
        if (rho < 0)
          rho = -rho;
        b->ux = (int16_t)mul14(ln_cos(t), rho);
        b->uy = (int16_t)mul14(ln_sin(t), rho);
        a = 16384;
        speed = 72;
        b->kind = 3;
        b->shape = 0;
      }
      if (g->event % 5u == 4u) {
        a = (uint16_t)(g->event * 25033u + i * 25033u);
        b->kind = 2;
        b->shape = 0;
      }
    }
    if (b->kind != 3) {
      b->ux = ln_cos(a);
      b->uy = ln_sin(a);
    } else {
      /* Only the emitter turns. Freeze this burst's world-space rays
       * at birth; no live Boss transform or age-based angle afterwards. */
      int32_t x = b->ux, y = b->uy;
      a = (uint16_t)(a + ln_emitter_angle(g));
      b->ux = (int16_t)(mul14(x, ln_cos(a)) - mul14(y, ln_sin(a)));
      b->uy = (int16_t)(mul14(x, ln_sin(a)) + mul14(y, ln_cos(a)));
    }
    b->angle = b->initial_angle = a;
    if (b->kind == 3 && g->spin_patterns)
      b->kind = 10;
    b->vx = (int16_t)(speed * LN_Q * 16 / 1000);
    b->vy = 0;
    {
      int32_t r = p == 6 ? 0 : 28 * LN_Q;
      b->x = b->ox * LN_Q + mul14(b->ux, r);
      b->y = b->oy * LN_Q + mul14(b->uy, r);
    }
    g->emissions++;
  }
  if ((p == 6 || p == 7) && g->event % 6u == 4u) {
    for (i = 0; i < LN_LASERS; i++) {
      ln_laser_t *l = &g->lasers[i];
      l->active = 1;
      l->age = 0;
      l->x = g->boss_x;
      l->y = g->boss_y;
      l->angle =
          (uint16_t)(16384u + ((int32_t)i - 1) * 13000 + g->event * 173u);
    }
  }
  g->event++;
  {
    uint32_t n = active + count;
    if (n > g->peak_bullets)
      g->peak_bullets = n;
  }
  return 1;
}
static void move_bullet(lunaria_t *g, ln_bullet_t *b) {
  int32_t speed = b->vx;
  b->age++;
  if (b->kind == 3 || b->kind == 10) {
    int32_t r = 28 * LN_Q + speed * b->age;
    int32_t ux = b->ux, uy = b->uy;
    if (b->kind == 10) {
      uint16_t turn = (uint16_t)(b->age * 80u);
      ux = mul14(b->ux, ln_cos(turn)) - mul14(b->uy, ln_sin(turn));
      uy = mul14(b->ux, ln_sin(turn)) + mul14(b->uy, ln_cos(turn));
    }
    b->x = b->ox * LN_Q + mul14(ux, r);
    b->y = b->oy * LN_Q + mul14(uy, r);
  } else if (b->kind == 2) {
    /* r = 28 + 150 * (sqrt(t + .08) - sqrt(.08)), in Q8.
     * The radicand is Q16 and remains below 2^32 throughout bullet life. */
    int32_t radius =
        28 * LN_Q +
        150 * ((int32_t)isqrt32((b->age * 16u + 80u) * 65536u / 1000u) - 72);
    b->x = b->ox * LN_Q + mul14(radius, b->ux);
    b->y = b->oy * LN_Q + mul14(radius, b->uy);
  } else {
    if (b->kind == 6) {
      uint16_t a = (uint16_t)(b->age * 267u);
      b->angle = (uint16_t)(b->initial_angle + mul14(2190, ln_sin(a)));
      speed = (42 * LN_Q * 16 / 1000) + (int32_t)b->age * 3;
    }
    if (b->kind == 7 && b->age < 82u && b->y < g->player_y - 65 * LN_Q) {
      int16_t d = (int16_t)(ln_aim((g->player_x - b->x) / LN_Q,
                                   (g->player_y - b->y) / LN_Q) -
                            b->angle);
      if (d > 150)
        d = 150;
      if (d < -150)
        d = -150;
      b->angle = (uint16_t)(b->angle + d);
    }
    if (b->kind == 8) {
      if (b->age < 50u)
        speed = speed * (50 - (int32_t)b->age) / 50;
      else if (b->age < 85u)
        speed = 0;
      else {
        if (b->age == 85u)
          b->angle =
              ln_aim((g->player_x - b->x) / LN_Q, (g->player_y - b->y) / LN_Q);
        speed = 100 * LN_Q * 16 / 1000;
      }
    }
    if (b->kind == 9)
      b->angle = (uint16_t)(b->angle + 105u);
    b->x += mul14(speed, ln_cos(b->angle));
    b->y += mul14(speed, ln_sin(b->angle));
  }
  if (b->age > b->life || b->x < -32 * LN_Q || b->x > 672 * LN_Q ||
      b->y < -32 * LN_Q || b->y > 512 * LN_Q)
    b->active = 0;
}
static void tick(lunaria_t *g, uint8_t buttons) {
  uint32_t i;
  g->sim_ms += 16;
  g->state_ms += 16;
  for (i = 0; i < LN_EFFECTS; i++)
    if (g->effects[i].active) {
      g->effects[i].age += 16;
      if (g->effects[i].age >= (g->effects[i].fatal ? 400u : 120u))
        g->effects[i].active = 0;
    }
  if (g->state == LN_INTRO) {
    if (g->state_ms >= 1000u)
      enter_phase(g);
    return;
  }
  if (g->state == LN_WARNING) {
    if (g->state_ms >= 500u)
      enter_phase(g);
    return;
  }
  if (g->state == LN_DEFEAT) {
    if (g->death_bursts < 4u && g->state_ms >= g->death_bursts * 125u) {
      int16_t k = (int16_t)g->death_bursts;
      effect(g, (int16_t)(g->boss_x + (k % 2 ? 18 : -18)),
             (int16_t)(g->boss_y + k * 5 - 10), 1);
      g->death_bursts++;
    }
    if (g->state_ms >= 800u) {
      g->state = LN_VICTORY;
      g->state_ms = 0;
      g->restart_armed = 0;
    }
    return;
  }
  if (g->state != LN_FIGHT)
    return;
  g->phase_ms += 16;
  for (i = 0; i < LN_LASERS; i++) {
    ln_laser_t *l = &g->lasers[i];
    if (l->active) {
      l->age += 16;
      if (l->age >= 1800u)
        l->active = 0;
      if (l->active && l->age >= 700u && !g->hurt_ticks && !g->invincible) {
        int32_t dx = g->player_x / LN_Q - l->x, dy = g->player_y / LN_Q - l->y;
        int32_t along = dx * ln_cos(l->angle) + dy * ln_sin(l->angle);
        int32_t cross = dx * ln_sin(l->angle) - dy * ln_cos(l->angle);
        if (along >= 0 && absi(cross) < 5 * 16384) {
          g->lives--;
          g->hurt_ticks = 100;
          effect(g, (int16_t)(g->player_x / LN_Q),
                 (int16_t)(g->player_y / LN_Q), 0);
          if (!g->lives) {
            clear_actors(g);
            g->state = LN_FAILURE;
            g->state_ms = 0;
            g->restart_armed = 0;
            return;
          }
        }
      }
    }
  }
  if (g->phase >= 3 && g->phase <= 5) {
    g->boss_x = 320;
    g->boss_y = g->phase == 3 ? 184 : 193;
  } else {
    g->boss_x = (int16_t)(320 + mul14(28, ln_sin((uint16_t)(g->sim_ms * 7u))));
    g->boss_y = (int16_t)(128 + mul14(7, ln_sin((uint16_t)(g->sim_ms * 9u))));
  }
  {
    int32_t dx = ((buttons & UART_KEY_RIGHT) != 0) -
                 ((buttons & UART_KEY_LEFT) != 0),
            dy = ((buttons & UART_KEY_DOWN) != 0) -
                 ((buttons & UART_KEY_UP) != 0);
    int32_t speed = (buttons & UART_KEY_FIRE) ? 720 : 1050;
    if (dx && dy)
      speed = speed * 181 / 256;
    g->player_x += dx * speed;
    g->player_y += dy * speed;
    if (g->player_x < 16 * LN_Q)
      g->player_x = 16 * LN_Q;
    if (g->player_x > 624 * LN_Q)
      g->player_x = 624 * LN_Q;
    if (g->player_y < 85 * LN_Q)
      g->player_y = 85 * LN_Q;
    if (g->player_y > 448 * LN_Q)
      g->player_y = 448 * LN_Q;
  }
  if (g->hurt_ticks)
    g->hurt_ticks--;
  for (i = 0; i < g->bullet_limit; i++)
    if (ln_bullet_read(g, i)->active) {
      ln_bullet_t *b = ln_bullet(g, i);
      int32_t dx, dy;
      move_bullet(g, b);
      if (!b->active)
        continue;
      dx = (b->x - g->player_x) / LN_Q;
      dy = (b->y - g->player_y) / LN_Q;
      if (!g->hurt_ticks && !g->invincible && dx * dx + dy * dy < 30) {
        b->active = 0;
        g->lives--;
        g->hurt_ticks = 100;
        effect(g, (int16_t)(g->player_x / LN_Q), (int16_t)(g->player_y / LN_Q),
               0);
        if (!g->lives) {
          clear_actors(g);
          g->state = LN_FAILURE;
          g->state_ms = 0;
          g->restart_armed = 0;
          return;
        }
      }
    }
  if (g->phase_ms >= g->next_emit_ms) {
    uint32_t interval = intervals[g->phase];
    if (g->bullet_limit < LN_DEFAULT_LIMIT)
      interval = interval * LN_DEFAULT_LIMIT / g->bullet_limit;
    g->next_emit_ms = g->phase_ms + (emit(g) ? interval : 64u);
  }
  for (i = 0; i < LN_SHOTS; i++)
    if (g->shots[i].active) {
      ln_shot_t *s = &g->shots[i];
      int32_t dx, dy, oldy = s->y;
      s->y -= 9 * LN_Q;
      dx = s->x / LN_Q - g->boss_x;
      dy = s->y / LN_Q - g->boss_y;
      if (dx * dx + dy * dy <= 28 * 28 ||
          (absi(dx) < 20 && oldy / LN_Q >= g->boss_y &&
           s->y / LN_Q <= g->boss_y)) {
        s->active = 0;
        ln_hit(g, (int16_t)(s->x / LN_Q), (int16_t)(s->y / LN_Q));
        if (g->state != LN_FIGHT)
          return;
      } else if (s->y < 72 * LN_Q)
        s->active = 0;
    }
  if ((buttons & UART_KEY_FIRE) && g->phase_ms >= g->next_shot_ms) {
    for (i = 0; i < LN_SHOTS; i++)
      if (!g->shots[i].active) {
        g->shots[i].active = 1;
        g->shots[i].x = g->player_x;
        g->shots[i].y = g->player_y - 8 * LN_Q;
        break;
      }
    g->next_shot_ms = g->phase_ms + 180u;
  }
}
void ln_step(lunaria_t *g, uint8_t buttons, uint32_t now) {
  uint32_t elapsed = now - g->last_ms;
  uint8_t pressed = (uint8_t)(buttons & ~g->previous_buttons);
  g->last_ms = now;
  g->previous_buttons = buttons;
  if (g->state == LN_TITLE) {
    if (pressed & UART_KEY_FIRE)
      ln_begin(g);
    return;
  }
  if (pressed & UART_KEY_PAUSE) {
    g->paused ^= 1u;
    g->accumulator_ms = 0;
    return;
  }
  if (g->paused)
    return;
  if (elapsed > 128u) {
    g->dropped_ms += elapsed - 128u;
    elapsed = 128u;
  }
  g->accumulator_ms += elapsed;
  while (g->accumulator_ms >= 16u) {
    g->accumulator_ms -= 16u;
    tick(g, buttons);
    ln_update_metrics(g);
  }
  if (g->state == LN_VICTORY || g->state == LN_FAILURE) {
    uint32_t wait = g->state == LN_VICTORY ? 3000u : 500u;
    if (g->state_ms >= wait) {
      if (!(buttons & UART_KEY_FIRE))
        g->restart_armed = 1;
      if (g->restart_armed && (pressed & UART_KEY_FIRE))
        ln_begin(g);
    }
  }
}
