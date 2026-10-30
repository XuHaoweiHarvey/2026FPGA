#ifndef LUNARIA_H
#define LUNARIA_H
#include "../interactive_demo/uart_keyboard_protocol.h"
#include <stdint.h>
#define LN_CAPACITY 512u
#define LN_DEFAULT_LIMIT 256u
#define LN_MIN_LIMIT 64u
#define LN_SETTINGS_MAGIC UINT32_C(0x4c4e5331)
typedef struct {
  uint32_t magic, version, sequence, ack, result;
  uint32_t requested_limit, requested_spin, limit, spin, min_limit, capacity;
} ln_settings_t;
#define LN_SHOTS 16u
#define LN_EFFECTS 8u
#define LN_LASERS 3u
#define LN_Q 256
#define LN_TICK_MS 16u
#define LN_PHASE_HP 28u
enum {
  LN_TITLE,
  LN_INTRO,
  LN_FIGHT,
  LN_WARNING,
  LN_DEFEAT,
  LN_VICTORY,
  LN_FAILURE
};
typedef struct {
  int32_t x, y;
  int16_t vx, vy, ox, oy, ux, uy;
  uint16_t age, life, angle, initial_angle;
  uint8_t active, color, shape, kind;
} ln_bullet_t;
typedef struct {
  int32_t x, y;
  uint8_t active;
} ln_shot_t;
typedef struct {
  int16_t x, y;
  uint16_t age;
  uint8_t active, fatal;
} ln_effect_t;
typedef struct {
  int16_t x, y;
  uint16_t angle, age;
  uint8_t active;
} ln_laser_t;
typedef struct {
  ln_bullet_t bullets[LN_CAPACITY];
  ln_shot_t shots[LN_SHOTS];
  ln_effect_t effects[LN_EFFECTS];
  ln_laser_t lasers[LN_LASERS];
  int32_t player_x, player_y;
  int16_t boss_x, boss_y;
  uint32_t last_ms, accumulator_ms, sim_ms, state_ms, phase_ms, next_emit_ms,
      next_shot_ms;
  uint32_t score, frames, dropped_ms, emissions, pool_drops, peak_bullets;
  uint32_t fps_x100, peak_visible_bullets, peak_elements, deferred_emissions;
  uint32_t bullet_limit, spin_patterns;
  uint16_t event, hp, hurt_ticks;
  uint8_t state, phase, lives, paused, previous_buttons, invincible,
      restart_armed, death_bursts;
} lunaria_t;
void ln_reset(lunaria_t *g, uint32_t now);
void ln_begin(lunaria_t *g);
uint32_t ln_configure(lunaria_t *g, uint32_t limit, uint32_t spin);
void ln_step(lunaria_t *g, uint8_t buttons, uint32_t now);
uint32_t ln_active(const lunaria_t *g);
uint32_t ln_visible(const lunaria_t *g);
uint32_t ln_elements(const lunaria_t *g);
void ln_update_metrics(lunaria_t *g);
uint32_t ln_boss_hp(const lunaria_t *g);
uint16_t ln_emitter_angle(const lunaria_t *g);
void ln_hit(lunaria_t *g, int16_t x, int16_t y);
int16_t ln_sin(uint16_t angle);
int16_t ln_cos(uint16_t angle);
uint16_t ln_aim(int32_t x, int32_t y);
#endif
