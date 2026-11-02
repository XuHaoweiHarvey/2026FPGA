#include "game_logic.h"

#define PLAYER_STEP (5 * (int32_t)GAME_PIXEL_SCALE)
#define ENEMY_SIZE ((int32_t)GAME_PLAYER_SIZE)
#define BULLET_W ((int32_t)GAME_PROJECTILE_SIZE)
#define BULLET_H ((int32_t)GAME_PROJECTILE_SIZE)
#define PLAYER_INVULNERABLE_MS 900u
#define INITIAL_LIVES 3u
#define DEFAULT_AUTO_RESTART_MS 3000u
#define DEFAULT_ENEMY_FIRE_INTERVAL_MS 900u
#define ENEMY_BULLET_SIZE ((int32_t)GAME_PROJECTILE_SIZE)
#define ENEMY_BULLET_SPEED (3 * (int32_t)GAME_PIXEL_SCALE)

static uint32_t game_random(survival_game_t *game) {
    game->rng = game->rng * UINT32_C(1664525) + UINT32_C(1013904223);
    return game->rng;
}

static int32_t clamp_i32(int32_t value, int32_t low, int32_t high) {
    return value < low ? low : (value > high ? high : value);
}

static int time_reached(uint32_t now, uint32_t deadline) {
    return (int32_t)(now - deadline) >= 0;
}

static uint32_t enemy_count(const survival_game_t *game) {
    uint32_t i, count = 0;
    for (i = 0; i < GAME_ENEMY_LIMIT; ++i)
        count += game->enemies[i].active != 0u;
    return count;
}

static void spawn_enemy(survival_game_t *game, uint32_t now_ms) {
    uint32_t i, v;
    for (i = 0; i < game->enemy_limit; ++i) {
        game_enemy_t *enemy = &game->enemies[i];
        if (enemy->active) continue;
        v = game_random(game);
        enemy->x = (int16_t)(8u + v % (GAME_WORLD_WIDTH - ENEMY_SIZE - 16u));
        enemy->y = (int16_t)(GAME_WORLD_TOP + (v >> 8) % 40u);
        enemy->vx = (int8_t)(((int32_t)((v >> 16) % 3u) - 1) * (int32_t)GAME_PIXEL_SCALE);
#if GAME_SHOWCASE
        if (game->showcase) enemy->vx = game->campaign_stage == 1u ? 0 :
            (int8_t)((i & 1u) ? 2 : -2);
#endif
        enemy->active = 1u;
        break;
    }
    /* Difficulty ramps from a modest opening wave to the full stress load. */
    {
        uint32_t elapsed = now_ms - game->started_ms;
        uint32_t interval = elapsed < 18000u ? 620u - (elapsed / 3000u) * 55u : 290u;
        if (interval < 290u) interval = 290u;
        if(game->difficulty==0u)interval=interval*3u/2u;
        else if(game->difficulty==2u)interval=interval*3u/4u;
        game->next_spawn_ms = now_ms + interval;
#if GAME_SHOWCASE
        if (game->showcase) game->next_spawn_ms = now_ms + 600u - 80u * game->campaign_stage;
#endif
    }
}

static void reset_with_options(survival_game_t *game, uint32_t now_ms,
                               uint32_t auto_restart_ms, uint32_t enemy_fire_interval_ms,
                               uint8_t enemy_limit, uint8_t invincible_mode) {
    uint8_t *bytes = (uint8_t *)game;
    uint32_t i;
    for (i = 0; i < (uint32_t)sizeof(*game); ++i) bytes[i] = 0;
    game->player_x = (int16_t)((GAME_WORLD_WIDTH - GAME_PLAYER_SIZE) / 2u);
    game->player_y = (int16_t)(GAME_WORLD_HEIGHT - GAME_PLAYER_SIZE - 16u);
    game->started_ms = now_ms;
    game->last_ms = now_ms;
    game->simulation_ms = now_ms;
    game->wave = 1u;
    game->next_spawn_ms = now_ms;
    game->next_fire_ms = now_ms;
    game->next_enemy_fire_ms = now_ms + enemy_fire_interval_ms;
    game->auto_restart_ms = auto_restart_ms;
    game->enemy_fire_interval_ms = enemy_fire_interval_ms;
    game->enemy_limit = enemy_limit;
    game->invincible_mode = invincible_mode;
    game->lives = INITIAL_LIVES;
    game->difficulty = 1u;
    game->rng = UINT32_C(0x7a31c5e9) ^ now_ms;
}

static void fire_enemy_volley(survival_game_t *game, uint32_t now_ms) {
    uint32_t i, slot, lane;
    game->next_enemy_fire_ms = now_ms + game->enemy_fire_interval_ms;
    for (i = 0; i < game->enemy_limit; ++i) {
        const game_enemy_t *enemy = &game->enemies[i];
        int32_t dx, dy, scale;
        if (!enemy->active) continue;
        dx = (int32_t)game->player_x + (int32_t)GAME_PLAYER_SIZE / 2 -
             ((int32_t)enemy->x + ENEMY_SIZE / 2);
        dy = (int32_t)game->player_y + (int32_t)GAME_PLAYER_SIZE / 2 -
             ((int32_t)enemy->y + ENEMY_SIZE / 2);
        scale = dx < 0 ? -dx : dx;
        if ((dy < 0 ? -dy : dy) > scale) scale = dy < 0 ? -dy : dy;
        if (!scale) scale = 1;
        uint32_t lanes = (game->wave & 1u) ? 1u : 3u;
#if GAME_SHOWCASE
        if (game->showcase) lanes = game->campaign_stage == 3u ? 3u : 1u;
#endif
        for (lane = 0; lane < lanes; ++lane) {
            for (slot = 0; slot < survival_game_enemy_bullet_limit(game); ++slot)
                if (!game->enemy_bullets[slot].active) break;
            if (slot == survival_game_enemy_bullet_limit(game)) return;
            game->enemy_bullets[slot].x = (int16_t)(enemy->x + ENEMY_SIZE / 2 - ENEMY_BULLET_SIZE / 2);
            game->enemy_bullets[slot].y = (int16_t)(enemy->y + ENEMY_SIZE - ENEMY_BULLET_SIZE / 2);
            game->enemy_bullets[slot].vx = (int8_t)(dx * ENEMY_BULLET_SPEED / scale);
            game->enemy_bullets[slot].vy = (int8_t)(dy * ENEMY_BULLET_SPEED / scale);
            if (lanes == 3u) {
                game->enemy_bullets[slot].vx = (int8_t)(((int32_t)lane * 2 - 2) * (int32_t)GAME_PIXEL_SCALE);
                game->enemy_bullets[slot].vy = ENEMY_BULLET_SPEED;
            }
            game->enemy_bullets[slot].active = 1u;
        }
    }
}

static void fire_bullet(survival_game_t *game, uint32_t now_ms) {
    uint32_t i;
    for (i = 0; i < GAME_BULLET_LIMIT; ++i) {
        game_bullet_t *bullet = &game->bullets[i];
        if (!bullet->active) {
            bullet->x = (int16_t)(game->player_x + (int16_t)(GAME_PLAYER_SIZE / 2u) -
                                  (int16_t)(BULLET_W / 2));
            bullet->y = (int16_t)(game->player_y - BULLET_H);
            bullet->active = 1u;
            break;
        }
    }
    game->next_fire_ms = now_ms + 170u;
}

static int intersects(int32_t ax, int32_t ay, int32_t aw, int32_t ah,
                      int32_t bx, int32_t by, int32_t bw, int32_t bh) {
    return ax < bx + bw && bx < ax + aw && ay < by + bh && by < ay + ah;
}

static void add_effect(survival_game_t *game, int16_t x, int16_t y, uint32_t now_ms) {
    uint32_t i;
    for (i = 0; i < GAME_EFFECT_LIMIT; ++i) {
        if (!game->effects[i].active || time_reached(now_ms, game->effects[i].expires_ms)) {
            game->effects[i].x = x;
            game->effects[i].y = y;
            game->effects[i].expires_ms = now_ms + GAME_EFFECT_LIFETIME_MS;
            game->effects[i].active = 1u;
            game->effects[i].kind = GAME_EFFECT_EXPLOSION;
            return;
        }
    }
}

void survival_game_reset(survival_game_t *game, uint32_t now_ms) {
    reset_with_options(game, now_ms, DEFAULT_AUTO_RESTART_MS,
                       DEFAULT_ENEMY_FIRE_INTERVAL_MS, (uint8_t)GAME_ENEMY_LIMIT, 0u);
}

void survival_game_begin_campaign(survival_game_t *game, uint32_t now_ms) {
    uint32_t delay = game->enemy_limit ? game->auto_restart_ms : 0u;
    uint32_t interval = game->enemy_limit ? game->enemy_fire_interval_ms : DEFAULT_ENEMY_FIRE_INTERVAL_MS;
    uint8_t limit = game->enemy_limit ? game->enemy_limit : (uint8_t)GAME_ENEMY_LIMIT;
    uint8_t invincible = game->invincible_mode, difficulty = game->difficulty;
    reset_with_options(game, now_ms, delay, interval, limit, invincible);
    game->difficulty = difficulty;
    game->campaign_stage = 1u;
}

#if GAME_SHOWCASE
void survival_game_begin_showcase(survival_game_t *game, uint32_t now_ms) {
    survival_game_begin_campaign(game, now_ms);
    game->showcase = 1u;
    game->showcase_state = GAME_SHOWCASE_WAVES;
    game->showcase_state_ms = now_ms;
    game->auto_restart_ms = 0u;
}

static void showcase_effect(survival_game_t *game, int16_t x, int16_t y,
                            uint32_t now_ms, uint8_t kind) {
    uint32_t i, selected = GAME_EFFECT_LIMIT;
    for (i = 0; i < GAME_EFFECT_LIMIT; ++i) {
        if (!game->effects[i].active || time_reached(now_ms, game->effects[i].expires_ms)) {
            selected = i; break;
        }
        if (kind == GAME_EFFECT_DEFEAT && game->effects[i].kind != GAME_EFFECT_DEFEAT)
            selected = i;
    }
    if (selected < GAME_EFFECT_LIMIT) {
        game_effect_t *effect = &game->effects[selected];
        effect->x = x; effect->y = y; effect->kind = kind; effect->active = 1u;
        effect->expires_ms = now_ms + (kind == GAME_EFFECT_HIT ? GAME_SHOWCASE_HIT_MS : GAME_EFFECT_LIFETIME_MS);
    }
}

static void showcase_death_tick(survival_game_t *game, uint32_t now_ms) {
    if (game->defeat_bursts < 4u && time_reached(now_ms, game->next_spawn_ms)) {
        uint32_t n = game->defeat_bursts++;
        showcase_effect(game, (int16_t)(game->boss.x + (n & 1u) * 24u),
            (int16_t)(game->boss.y + (n >> 1) * 24u), now_ms, GAME_EFFECT_DEFEAT);
        game->next_spawn_ms = now_ms + 125u;
    }
    if ((uint32_t)(now_ms - game->showcase_state_ms) >= 800u) {
        game->showcase_state = GAME_SHOWCASE_VICTORY;
        game->showcase_state_ms = now_ms;
        game->campaign_result = 1u; game->game_over = 1u; game->victory_armed = 0u;
    }
}
#endif

/* Reproducible full-pool scene. Refill departing/hit objects continuously;
 * unlike the campaign it cannot finish during the 60-second measurement. */
static void refill_stress(survival_game_t *game) {
    uint32_t i, limit = survival_game_enemy_bullet_limit(game);
    uint32_t rows = (limit + 15u) / 16u, row_step = GAME_PLAYER_SIZE;
    uint32_t vertical_space = GAME_WORLD_HEIGHT - GAME_WORLD_TOP -
                              GAME_PLAYER_SIZE - GAME_PROJECTILE_SIZE - 8u;
    if (rows > 1u && row_step * (rows - 1u) > vertical_space)
        row_step = vertical_space / (rows - 1u);
    for (i = 0u; i < game->enemy_limit; ++i) if (!game->enemies[i].active) {
        game_enemy_t *enemy = &game->enemies[i];
        enemy->x = (int16_t)(16u + (i % 12u) * (GAME_WORLD_WIDTH - GAME_PLAYER_SIZE - 32u) / 11u);
        enemy->y = (int16_t)(GAME_WORLD_TOP + (i / 12u) * (GAME_PLAYER_SIZE + 8u));
        enemy->vx = (int8_t)((i & 1u) ? (int32_t)GAME_PIXEL_SCALE : -(int32_t)GAME_PIXEL_SCALE);
        enemy->active = 1u;
    }
    for (i = 0u; i < limit; ++i) if (!game->enemy_bullets[i].active) {
        game_enemy_bullet_t *bullet = &game->enemy_bullets[i];
        bullet->x = (int16_t)(16u + (i % 16u) * (GAME_WORLD_WIDTH - GAME_PROJECTILE_SIZE - 32u) / 15u);
        bullet->y = (int16_t)(GAME_WORLD_TOP + GAME_PLAYER_SIZE + (i / 16u) * row_step);
        bullet->vx = (int8_t)(((int32_t)(i % 3u) - 1) * (int32_t)GAME_PIXEL_SCALE);
        bullet->vy = ENEMY_BULLET_SPEED;
        bullet->active = 1u;
    }
}

void survival_game_begin_stress(survival_game_t *game, uint32_t now_ms) {
    uint32_t interval = game->enemy_fire_interval_ms;
    reset_with_options(game, now_ms, 0u, interval ? interval : DEFAULT_ENEMY_FIRE_INTERVAL_MS,
                       (uint8_t)GAME_ENEMY_LIMIT, 1u);
    game->stress_mode = 1u;
#if GAME_STRESS_TUNING
    game->stress_enemy_bullet_limit = GAME_ENEMY_BULLET_LIMIT;
#endif
    refill_stress(game);
}

#if GAME_STRESS_TUNING
int survival_game_begin_stress_load(survival_game_t *game, uint32_t now_ms,
                                    uint32_t enemies, uint32_t enemy_bullets) {
    uint32_t interval = game->enemy_fire_interval_ms;
    if (enemies < 1u || enemies > GAME_ENEMY_LIMIT ||
        enemy_bullets < 1u || enemy_bullets > GAME_ENEMY_BULLET_CAPACITY) return 0;
    reset_with_options(game, now_ms, 0u, interval ? interval : DEFAULT_ENEMY_FIRE_INTERVAL_MS,
                       (uint8_t)enemies, 1u);
    game->stress_mode = 1u;
    game->stress_enemy_bullet_limit = enemy_bullets;
    refill_stress(game);
    return 1;
}
#endif

static void clear_combat(survival_game_t *game) {
    uint32_t i;
    for (i = 0u; i < GAME_ENEMY_LIMIT; ++i) game->enemies[i].active = 0u;
    for (i = 0u; i < GAME_BULLET_LIMIT; ++i) game->bullets[i].active = 0u;
    for (i = 0u; i < GAME_ENEMY_BULLET_CAPACITY; ++i) game->enemy_bullets[i].active = 0u;
    for (i = 0u; i < GAME_EFFECT_LIMIT; ++i) game->effects[i].active = 0u;
}

static void advance_campaign(survival_game_t *game, uint32_t now_ms) {
    uint32_t period = GAME_CAMPAIGN_WAVE_MS;
    uint32_t stage;
#if GAME_SHOWCASE
    if (game->showcase) period = GAME_SHOWCASE_WAVE_MS;
#endif
    stage = 1u + (now_ms - game->started_ms) / period;
    if (stage > GAME_CAMPAIGN_BOSS_STAGE) stage = GAME_CAMPAIGN_BOSS_STAGE;
    if (stage != game->campaign_stage) {
        game->campaign_stage = (uint8_t)stage;
        game->next_spawn_ms = now_ms;
        game->next_enemy_fire_ms = now_ms + 500u;
#if GAME_SHOWCASE
        if (game->showcase) {
            clear_combat(game);
            game->showcase_state_ms = now_ms;
        }
#endif
        if (stage == GAME_CAMPAIGN_BOSS_STAGE) {
            clear_combat(game);
            game->boss.active = 1u;
            game->boss.hp = GAME_BOSS_MAX_HP;
            game->boss.x = (int16_t)((GAME_WORLD_WIDTH - GAME_BOSS_SIZE) / 2u);
            game->boss.y = (int16_t)(GAME_WORLD_TOP + 24u);
            game->boss.vx = (int8_t)(2u * GAME_PIXEL_SCALE);
            game->boss.attack_phase = 1u;
            game->boss_next_fire_ms = now_ms + 800u;
#if GAME_SHOWCASE
            if (game->showcase) {
                game->boss.hp = GAME_SHOWCASE_BOSS_HP;
                game->showcase_state = GAME_SHOWCASE_INTRO;
                game->boss_warning_until_ms = now_ms + 1000u;
                game->boss_next_fire_ms = now_ms + 1000u;
            }
#endif
        }
    }
    game->wave = stage;
}

#if GAME_SHOWCASE
static void showcase_boss_phase(survival_game_t *game, uint32_t now_ms) {
    uint32_t lane;
    uint8_t phase = game->boss.hp <= 20u ? 3u : game->boss.hp <= 40u ? 2u : 1u;
    if (phase == game->boss.attack_phase) return;
    game->boss.attack_phase = phase;
    for (lane = 0; lane < GAME_ENEMY_BULLET_CAPACITY; ++lane)
        game->enemy_bullets[lane].active = 0u;
    game->boss_warning_until_ms = now_ms + 500u;
    game->boss_next_fire_ms = now_ms + 500u;
    game->boss_angle = 0u;
}

static void tick_showcase_boss(survival_game_t *game, uint32_t now_ms) {
    static const int8_t direction[32][2] = {
        {4,0},{4,1},{4,2},{3,2},{3,3},{2,3},{2,4},{1,4},
        {0,4},{-1,4},{-2,4},{-2,3},{-3,3},{-3,2},{-4,2},{-4,1},
        {-4,0},{-4,-1},{-4,-2},{-3,-2},{-3,-3},{-2,-3},{-2,-4},{-1,-4},
        {0,-4},{1,-4},{2,-4},{2,-3},{3,-3},{3,-2},{4,-2},{4,-1}
    };
    game_boss_t *boss = &game->boss;
    uint32_t phase = boss->hp <= 20u ? 3u : boss->hp <= 40u ? 2u : 1u;
    uint32_t lane, count, interval, moving;
    if (game->showcase_state == GAME_SHOWCASE_INTRO) {
        if (!time_reached(now_ms, game->boss_warning_until_ms)) return;
        game->showcase_state = GAME_SHOWCASE_BOSS;
        game->boss_phase_ms = now_ms;
    }
    showcase_boss_phase(game, now_ms);
    moving = ((now_ms - game->boss_phase_ms) % 5000u) < 3000u;
    if (moving) {
        boss->x = (int16_t)(boss->x + boss->vx);
        if (boss->x <= 32 || boss->x >= (int32_t)(GAME_WORLD_WIDTH - GAME_BOSS_SIZE - 32u)) {
            boss->vx = (int8_t)-boss->vx;
            boss->x = (int16_t)clamp_i32(boss->x, 32, GAME_WORLD_WIDTH - GAME_BOSS_SIZE - 32u);
        }
    }
    if (!time_reached(now_ms, game->boss_next_fire_ms)) return;
    count = phase == 1u ? 4u : phase == 2u ? 14u : 24u;
    interval = phase == 1u ? 112u : phase == 2u ? 320u :
        (game->boss_angle % 3u == 2u ? 800u : 180u);
    game->boss_next_fire_ms = now_ms + interval * (moving ? 2u : 1u);
    for (lane = 0; lane < count; ++lane) {
        uint32_t slot, angle;
        game_enemy_bullet_t *bullet;
        for (slot = 0; slot < GAME_ENEMY_BULLET_CAPACITY; ++slot)
            if (!game->enemy_bullets[slot].active) break;
        if (slot == GAME_ENEMY_BULLET_CAPACITY) break;
        angle = phase == 1u ? game->boss_angle + (lane / 2u) * 16u + lane % 2u :
                phase == 2u ? (lane < 7u ? 2u : 8u) + lane % 7u :
                lane * 32u / 24u + game->boss_angle;
        bullet = &game->enemy_bullets[slot];
        bullet->x = (int16_t)(boss->x + (GAME_BOSS_SIZE - GAME_PROJECTILE_SIZE) / 2u);
        if (phase == 2u) bullet->x = (int16_t)(boss->x +
            (lane < 7u ? 8u : GAME_BOSS_SIZE - GAME_PROJECTILE_SIZE - 8u));
        bullet->y = (int16_t)(boss->y + (GAME_BOSS_SIZE - GAME_PROJECTILE_SIZE) / 2u);
        bullet->vx = direction[angle & 31u][0]; bullet->vy = direction[angle & 31u][1];
        bullet->active = 1u;
    }
    ++game->boss_angle;
}
#endif

static void tick_boss(survival_game_t *game, uint32_t now_ms) {
#if GAME_SHOWCASE
    if (game->showcase) { tick_showcase_boss(game, now_ms); return; }
#endif
    /* Integer velocity table keeps the second phase independent of libm. */
    static const int8_t ring[16][2] = {
        {0,4},{2,4},{3,3},{4,2},{4,0},{4,-2},{3,-3},{2,-4},
        {0,-4},{-2,-4},{-3,-3},{-4,-2},{-4,0},{-4,2},{-3,3},{-2,4}
    };
    game_boss_t *boss = &game->boss;
    uint32_t lane, slot, count;
    boss->attack_phase = boss->hp <= GAME_BOSS_MAX_HP / 2u ? 2u : 1u;
    boss->x = (int16_t)(boss->x + boss->vx);
    if (boss->x < 8 || boss->x > (int32_t)(GAME_WORLD_WIDTH - GAME_BOSS_SIZE - 8u)) {
        boss->vx = (int8_t)-boss->vx;
        boss->x = (int16_t)clamp_i32(boss->x, 8, (int32_t)(GAME_WORLD_WIDTH - GAME_BOSS_SIZE - 8u));
    }
    if (!time_reached(now_ms, game->boss_next_fire_ms)) return;
    game->boss_next_fire_ms = now_ms + (boss->attack_phase == 1u ? 650u : 430u);
    count = boss->attack_phase == 1u ? 7u : 16u;
    for (lane = 0u; lane < count; ++lane) {
        game_enemy_bullet_t *bullet;
        for (slot = 0u; slot < survival_game_enemy_bullet_limit(game); ++slot)
            if (!game->enemy_bullets[slot].active) break;
        if (slot == survival_game_enemy_bullet_limit(game)) break;
        bullet = &game->enemy_bullets[slot];
        bullet->x = (int16_t)(boss->x + (GAME_BOSS_SIZE - GAME_PROJECTILE_SIZE) / 2u);
        bullet->y = (int16_t)(boss->y + GAME_BOSS_SIZE - GAME_PROJECTILE_SIZE);
        bullet->vx = (int8_t)((boss->attack_phase == 1u ? (int32_t)lane - 3 : ring[lane][0]) * (int32_t)GAME_PIXEL_SCALE);
        bullet->vy = (int8_t)((boss->attack_phase == 1u ? 4 : ring[lane][1]) * (int32_t)GAME_PIXEL_SCALE);
        bullet->active = 1u;
    }
}

void survival_game_set_options(survival_game_t *game, uint32_t auto_restart_ms,
                               uint32_t enemy_fire_interval_ms, uint8_t enemy_limit,
                               uint8_t invincible_mode) {
    uint32_t i;
    if (auto_restart_ms > 60000u) auto_restart_ms = 60000u;
    if (enemy_fire_interval_ms < 150u) enemy_fire_interval_ms = 150u;
    if (enemy_fire_interval_ms > 10000u) enemy_fire_interval_ms = 10000u;
    if (enemy_limit < 1u) enemy_limit = 1u;
    if (enemy_limit > GAME_ENEMY_LIMIT) enemy_limit = (uint8_t)GAME_ENEMY_LIMIT;
    game->auto_restart_ms = auto_restart_ms;
    game->enemy_fire_interval_ms = enemy_fire_interval_ms;
    game->enemy_limit = enemy_limit;
    game->invincible_mode = invincible_mode != 0u;
    for (i = enemy_limit; i < GAME_ENEMY_LIMIT; ++i) game->enemies[i].active = 0u;
}

uint32_t survival_game_sprite_count(const survival_game_t *game, uint32_t now_ms) {
    /* The player is rendered as two independent sprites: a glow and a ship. */
    uint32_t i, count = !game->game_over ? 2u : 0u;
    count += game->boss.active != 0u;
    for (i = 0; i < GAME_ENEMY_LIMIT; ++i) count += game->enemies[i].active != 0u;
    for (i = 0; i < GAME_BULLET_LIMIT; ++i) count += game->bullets[i].active != 0u;
    for (i = 0; i < survival_game_enemy_bullet_limit(game); ++i)
        count += game->enemy_bullets[i].active != 0u;
    for (i = 0; i < GAME_EFFECT_LIMIT; ++i)
        count += game->effects[i].active && !time_reached(now_ms, game->effects[i].expires_ms);
    return count;
}

static void freeze_game_timers(survival_game_t *game, uint32_t elapsed_ms) {
    uint32_t i;
    /* Deadlines stay in the wall-clock domain used by rendering, but retain
       their remaining duration while paused, including across clock wrap. */
    game->started_ms += elapsed_ms;
    game->next_spawn_ms += elapsed_ms;
    game->next_fire_ms += elapsed_ms;
    game->next_enemy_fire_ms += elapsed_ms;
    game->boss_next_fire_ms += elapsed_ms;
#if GAME_SHOWCASE
    if (game->showcase) {
        game->showcase_state_ms += elapsed_ms;
        game->boss_phase_ms += elapsed_ms;
        game->boss_warning_until_ms += elapsed_ms;
    }
#endif
    if (game->invulnerable) game->invulnerable_until_ms += elapsed_ms;
    for (i = 0; i < GAME_EFFECT_LIMIT; ++i)
        if (game->effects[i].active) game->effects[i].expires_ms += elapsed_ms;
}

static void simulation_tick(survival_game_t *game, uint8_t buttons, uint32_t now_ms) {
    uint32_t i;
    int32_t dx = 0, dy = 0;
#if GAME_SHOWCASE
    if (game->showcase && game->showcase_state == GAME_SHOWCASE_DEFEAT) {
        showcase_death_tick(game, now_ms); ++game->frames; return;
    }
#endif
    if (game->campaign_stage) advance_campaign(game, now_ms);
    else game->wave = 1u + (now_ms - game->started_ms) / 12000u;
    if (game->stress_mode) buttons |= UART_KEY_FIRE;
    if (game->invulnerable && time_reached(now_ms, game->invulnerable_until_ms))
        game->invulnerable = 0u;

    if (buttons & UART_KEY_LEFT) dx -= PLAYER_STEP;
    if (buttons & UART_KEY_RIGHT) dx += PLAYER_STEP;
    if (buttons & UART_KEY_UP) dy -= PLAYER_STEP;
    if (buttons & UART_KEY_DOWN) dy += PLAYER_STEP;
    game->player_x = (int16_t)clamp_i32(game->player_x + dx, 0,
        (int32_t)(GAME_WORLD_WIDTH - GAME_PLAYER_SIZE));
    game->player_y = (int16_t)clamp_i32(game->player_y + dy, (int32_t)GAME_WORLD_TOP,
        (int32_t)(GAME_WORLD_HEIGHT - GAME_PLAYER_SIZE));

    if ((buttons & UART_KEY_FIRE) && time_reached(now_ms, game->next_fire_ms))
        fire_bullet(game, now_ms);
    if (game->boss.active) tick_boss(game, now_ms);
    else {
        uint32_t limit = game->enemy_limit;
        if (game->campaign_stage && limit > 8u + 4u * game->campaign_stage)
            limit = 8u + 4u * game->campaign_stage;
#if GAME_SHOWCASE
        if (game->showcase && limit > 4u + 2u * game->campaign_stage)
            limit = 4u + 2u * game->campaign_stage;
#endif
        if (time_reached(now_ms, game->next_spawn_ms) && enemy_count(game) < limit)
            spawn_enemy(game, now_ms);
        if (time_reached(now_ms, game->next_enemy_fire_ms)) fire_enemy_volley(game, now_ms);
    }

    for (i = 0; i < GAME_BULLET_LIMIT; ++i) {
        game_bullet_t *bullet = &game->bullets[i];
        uint32_t j;
        if (!bullet->active) continue;
        bullet->y = (int16_t)(bullet->y - 9 * (int32_t)GAME_PIXEL_SCALE);
        if (bullet->y + BULLET_H < (int32_t)GAME_WORLD_TOP) {
            bullet->active = 0u;
            continue;
        }
        if (game->boss.active && intersects(bullet->x, bullet->y, BULLET_W, BULLET_H,
                game->boss.x, game->boss.y, GAME_BOSS_SIZE, GAME_BOSS_SIZE)) {
            bullet->active = 0u;
#if GAME_SHOWCASE
            if (game->showcase && game->showcase_state == GAME_SHOWCASE_INTRO) continue;
            if (game->showcase) {
                int16_t hit_x = (int16_t)(bullet->x + BULLET_W / 2 - 8);
                int16_t hit_y = (int16_t)(bullet->y + BULLET_H / 2 - 8);
                showcase_effect(game, hit_x, hit_y, now_ms, GAME_EFFECT_HIT);
            }
#endif
            game->score += 5u;
            if (--game->boss.hp == 0u) {
                game->score += 1000u;
                game->boss.active = 0u;
#if GAME_SHOWCASE
                if (game->showcase) {
                    for (j = 0; j < GAME_ENEMY_LIMIT; ++j) game->enemies[j].active = 0u;
                    for (j = 0; j < GAME_BULLET_LIMIT; ++j) game->bullets[j].active = 0u;
                    for (j = 0; j < GAME_ENEMY_BULLET_CAPACITY; ++j) game->enemy_bullets[j].active = 0u;
                    game->showcase_state = GAME_SHOWCASE_DEFEAT;
                    game->showcase_state_ms = now_ms;
                    game->defeat_bursts = 0u; game->next_spawn_ms = now_ms;
                    showcase_death_tick(game, now_ms);
                    ++game->frames; return;
                }
#endif
                game->campaign_result = 1u;
                game->game_over = 1u;
                game->auto_restart_at_ms = now_ms + game->auto_restart_ms;
                clear_combat(game);
                break;
            }
#if GAME_SHOWCASE
            if (game->showcase) showcase_boss_phase(game, now_ms);
#endif
            continue;
        }
        for (j = 0; j < GAME_ENEMY_LIMIT; ++j) {
            game_enemy_t *enemy = &game->enemies[j];
            if (!enemy->active || !intersects(bullet->x, bullet->y, BULLET_W, BULLET_H,
                                               enemy->x, enemy->y, ENEMY_SIZE, ENEMY_SIZE))
                continue;
            bullet->active = 0u;
            enemy->active = 0u;
            game->score += 10u;
            add_effect(game, enemy->x, enemy->y, now_ms);
            break;
        }
    }

    for (i = 0; i < GAME_ENEMY_LIMIT; ++i) {
        game_enemy_t *enemy = &game->enemies[i];
        if (!enemy->active) continue;
        enemy->x = (int16_t)(enemy->x + enemy->vx);
        if (enemy->x < 4 || enemy->x > (int32_t)(GAME_WORLD_WIDTH - ENEMY_SIZE - 4u)) {
            enemy->vx = (int8_t)-enemy->vx;
            enemy->x = (int16_t)clamp_i32(enemy->x, 4,
                (int32_t)(GAME_WORLD_WIDTH - ENEMY_SIZE - 4u));
        }
        enemy->move_phase ^= 1u;
        if (enemy->move_phase) enemy->y = (int16_t)(enemy->y + GAME_PIXEL_SCALE);
        if (enemy->y >= (int32_t)GAME_WORLD_HEIGHT) {
            enemy->active = 0u;
            if (game->lives && !game->invincible_mode) --game->lives;
            continue;
        }
        if (!game->invulnerable && intersects(game->player_x, game->player_y,
                GAME_PLAYER_SIZE, GAME_PLAYER_SIZE, enemy->x, enemy->y, ENEMY_SIZE, ENEMY_SIZE)) {
            enemy->active = 0u;
            if (game->lives && !game->invincible_mode) --game->lives;
            game->invulnerable = 1u;
            game->invulnerable_until_ms = now_ms + PLAYER_INVULNERABLE_MS;
        }
    }
    for (i = 0; i < survival_game_enemy_bullet_limit(game); ++i) {
        game_enemy_bullet_t *bullet = &game->enemy_bullets[i];
        if (!bullet->active) continue;
        bullet->x = (int16_t)(bullet->x + bullet->vx);
        bullet->y = (int16_t)(bullet->y + bullet->vy);
        if (bullet->x < -ENEMY_BULLET_SIZE || bullet->x >= (int32_t)GAME_WORLD_WIDTH ||
            bullet->y < (int32_t)GAME_WORLD_TOP - ENEMY_BULLET_SIZE ||
            bullet->y >= (int32_t)GAME_WORLD_HEIGHT) {
            bullet->active = 0u;
            continue;
        }
        /* Keep the small central hitbox proportional to the sprite scale. */
        if (!game->invulnerable && intersects(game->player_x + 13 * (int32_t)GAME_PIXEL_SCALE,
                game->player_y + 13 * (int32_t)GAME_PIXEL_SCALE,
                6 * (int32_t)GAME_PIXEL_SCALE, 6 * (int32_t)GAME_PIXEL_SCALE, bullet->x, bullet->y,
                ENEMY_BULLET_SIZE, ENEMY_BULLET_SIZE)) {
            bullet->active = 0u;
            if (game->lives && !game->invincible_mode) --game->lives;
            game->invulnerable = 1u;
            game->invulnerable_until_ms = now_ms + PLAYER_INVULNERABLE_MS;
        }
    }

    if (game->boss.active && !game->invulnerable && intersects(game->player_x, game->player_y,
            GAME_PLAYER_SIZE, GAME_PLAYER_SIZE, game->boss.x, game->boss.y, GAME_BOSS_SIZE, GAME_BOSS_SIZE)) {
        if (game->lives && !game->invincible_mode) --game->lives;
        game->invulnerable = 1u;
        game->invulnerable_until_ms = now_ms + PLAYER_INVULNERABLE_MS;
    }
    if (game->lives == 0u && !game->game_over) {
        game->game_over = 1u;
        if (game->campaign_stage) game->campaign_result = 2u;
#if GAME_SHOWCASE
        if (game->showcase) {
            game->showcase_state = GAME_SHOWCASE_FAILURE;
            game->showcase_state_ms = now_ms; game->victory_armed = 0u;
        }
#endif
        game->auto_restart_at_ms = now_ms + game->auto_restart_ms;
    }
    if (game->stress_mode) refill_stress(game);
    ++game->frames;
    {
        uint32_t sprites = survival_game_sprite_count(game, now_ms);
        if (sprites > game->max_sprites_seen) game->max_sprites_seen = sprites;
    }
}

void survival_game_step(survival_game_t *game, uint8_t buttons, uint32_t now_ms) {
    uint32_t elapsed_ms = now_ms - game->last_ms;
    uint8_t was_paused = game->paused;
    if (game->campaign_stage == GAME_CAMPAIGN_TITLE) {
        if ((buttons & UART_KEY_FIRE) && !(game->previous_buttons & UART_KEY_FIRE))
#if GAME_SHOWCASE
            survival_game_begin_showcase(game, now_ms);
#else
            survival_game_begin_campaign(game, now_ms);
#endif
        game->previous_buttons = buttons;
        game->last_ms = now_ms;
        return;
    }
    if (game->game_over) {
#if GAME_SHOWCASE
        if (game->showcase) {
            uint32_t hold_ms = game->campaign_result == 1u ? 3000u : 500u;
            if ((uint32_t)(now_ms - game->showcase_state_ms) >= hold_ms && !(buttons & UART_KEY_FIRE))
                game->victory_armed = 1u;
            if (game->victory_armed && (buttons & UART_KEY_FIRE) && !(game->previous_buttons & UART_KEY_FIRE))
                survival_game_begin_showcase(game, now_ms);
            game->previous_buttons = buttons; game->last_ms = now_ms; return;
        }
#endif
        if (((buttons & UART_KEY_FIRE) && !(game->previous_buttons & UART_KEY_FIRE)) ||
            (game->auto_restart_ms && time_reached(now_ms, game->auto_restart_at_ms))) {
            uint32_t delay = game->auto_restart_ms, interval = game->enemy_fire_interval_ms;
            uint8_t limit = game->enemy_limit, invincible = game->invincible_mode;
            uint8_t campaign = game->campaign_stage, difficulty = game->difficulty;
            reset_with_options(game, now_ms, delay, interval, limit, invincible);
            game->difficulty = difficulty;
            if (campaign) game->campaign_stage = 1u;
        }
        game->previous_buttons = buttons;
        game->last_ms = now_ms;
        return;
    }
    if ((buttons & UART_KEY_PAUSE) && !(game->previous_buttons & UART_KEY_PAUSE))
        game->paused ^= 1u;
    game->previous_buttons = buttons;
    game->last_ms = now_ms;
    if (was_paused || game->paused) {
        freeze_game_timers(game, elapsed_ms);
        game->simulation_ms += elapsed_ms;
        game->pending_buttons = 0u;
        return;
    }
    /* Bounded catch-up prevents a debug halt from running minutes of simulation.
       Ordinary rendering at different frame rates advances identical 16 ms ticks. */
    if (elapsed_ms > 1024u) {
        uint32_t dropped = elapsed_ms - 1024u;
        game->dropped_ms += dropped;
        freeze_game_timers(game, dropped);
        game->simulation_ms += dropped;
        elapsed_ms = 1024u;
    }
    game->pending_buttons |= buttons & UART_KEY_FIRE;
    game->accumulator_ms += elapsed_ms;
    while (game->accumulator_ms >= GAME_TICK_MS && !game->game_over) {
        game->accumulator_ms -= GAME_TICK_MS;
        game->simulation_ms += GAME_TICK_MS;
        simulation_tick(game, (uint8_t)(buttons | game->pending_buttons), game->simulation_ms);
        game->pending_buttons = 0u;
    }
}
