#ifndef SURVIVAL_GAME_LOGIC_H
#define SURVIVAL_GAME_LOGIC_H

#include <stdint.h>
#include "game_display_config.h"
#include "uart_keyboard_protocol.h"
#ifndef GAME_SHOWCASE
#define GAME_SHOWCASE 0
#endif

#define GAME_ENEMY_LIMIT 48u
#define GAME_BULLET_LIMIT 16u
#define GAME_ENEMY_BULLET_LIMIT 64u
#ifndef GAME_STRESS_TUNING
#define GAME_STRESS_TUNING 0
#endif
#ifndef GAME_ENEMY_BULLET_CAPACITY
#define GAME_ENEMY_BULLET_CAPACITY GAME_ENEMY_BULLET_LIMIT
#endif
#if GAME_ENEMY_BULLET_CAPACITY < GAME_ENEMY_BULLET_LIMIT
#error "Enemy bullet pool must retain the original baseline"
#endif
#define GAME_EFFECT_LIMIT 8u
#define GAME_TICK_MS 16u
#define GAME_EFFECT_LIFETIME_MS 420u
#define GAME_CAMPAIGN_WAVE_COUNT 3u
#define GAME_CAMPAIGN_WAVE_MS 22000u
#define GAME_CAMPAIGN_BOSS_STAGE (GAME_CAMPAIGN_WAVE_COUNT + 1u)
#define GAME_BOSS_MAX_HP 90u
#define GAME_BOSS_SIZE (64u * GAME_PIXEL_SCALE)
#define GAME_CAMPAIGN_TITLE 255u
#define GAME_SHOWCASE_WAVE_MS 7000u
#define GAME_SHOWCASE_BOSS_HP 60u
#define GAME_SHOWCASE_HIT_MS 120u
enum { GAME_EFFECT_EXPLOSION=0, GAME_EFFECT_HIT=1, GAME_EFFECT_DEFEAT=2 };
enum { GAME_SHOWCASE_WAVES=1, GAME_SHOWCASE_INTRO=2, GAME_SHOWCASE_BOSS=3,
       GAME_SHOWCASE_DEFEAT=4, GAME_SHOWCASE_VICTORY=5, GAME_SHOWCASE_FAILURE=6 };

typedef struct {
    int16_t x, y;
    int8_t vx;
    uint8_t active, move_phase;
} game_enemy_t;

typedef struct {
    int16_t x, y;
    uint8_t active;
} game_bullet_t;

typedef struct {
    int16_t x, y;
    int8_t vx, vy;
    uint8_t active;
} game_enemy_bullet_t;

typedef struct {
    int16_t x, y;
    uint32_t expires_ms;
    uint8_t active, kind;
} game_effect_t;

typedef struct {
    int16_t x, y;
    int8_t vx;
    uint8_t hp, active, attack_phase;
} game_boss_t;

typedef struct {
    int16_t player_x, player_y;
    uint32_t started_ms, last_ms, next_spawn_ms, next_fire_ms, next_enemy_fire_ms;
    uint32_t score, frames, max_sprites_seen;
    uint32_t rng;
    uint32_t simulation_ms, accumulator_ms, dropped_ms, wave;
    uint8_t lives, paused, game_over, previous_buttons;
    uint8_t invulnerable, difficulty; /* 0 easy, 1 normal, 2 hard */
    uint8_t enemy_limit, invincible_mode, pending_buttons;
    uint32_t auto_restart_ms, auto_restart_at_ms, enemy_fire_interval_ms;
    uint32_t invulnerable_until_ms;
    uint32_t boss_next_fire_ms;
    uint8_t campaign_stage, campaign_result, stress_mode;
#if GAME_SHOWCASE
    uint8_t showcase, showcase_state, victory_armed, boss_angle, defeat_bursts;
    uint32_t showcase_state_ms, boss_phase_ms, boss_warning_until_ms;
#endif
#if GAME_STRESS_TUNING
    uint32_t stress_enemy_bullet_limit;
#endif
    game_boss_t boss;
    game_enemy_t enemies[GAME_ENEMY_LIMIT];
    game_bullet_t bullets[GAME_BULLET_LIMIT];
    game_enemy_bullet_t enemy_bullets[GAME_ENEMY_BULLET_CAPACITY];
    game_effect_t effects[GAME_EFFECT_LIMIT];
} survival_game_t;

void survival_game_reset(survival_game_t *game, uint32_t now_ms);
void survival_game_begin_campaign(survival_game_t *game, uint32_t now_ms);
#if GAME_SHOWCASE
void survival_game_begin_showcase(survival_game_t *game, uint32_t now_ms);
#endif
void survival_game_begin_stress(survival_game_t *game, uint32_t now_ms);
#if GAME_STRESS_TUNING
int survival_game_begin_stress_load(survival_game_t *game, uint32_t now_ms,
                                    uint32_t enemies, uint32_t enemy_bullets);
#endif
static inline uint32_t survival_game_enemy_bullet_limit(const survival_game_t *game) {
#if GAME_SHOWCASE
    if (game->showcase && !game->stress_mode) return GAME_ENEMY_BULLET_CAPACITY;
#endif
#if GAME_STRESS_TUNING
    return game->stress_mode ? game->stress_enemy_bullet_limit : GAME_ENEMY_BULLET_LIMIT;
#else
    (void)game;
    return GAME_ENEMY_BULLET_LIMIT;
#endif
}
void survival_game_set_options(survival_game_t *game, uint32_t auto_restart_ms,
                               uint32_t enemy_fire_interval_ms, uint8_t enemy_limit,
                               uint8_t invincible_mode);
void survival_game_step(survival_game_t *game, uint8_t buttons, uint32_t now_ms);
uint32_t survival_game_sprite_count(const survival_game_t *game, uint32_t now_ms);

#endif
