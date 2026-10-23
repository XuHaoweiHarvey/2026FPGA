#include "game_logic.h"

#define PLAYER_STEP 5
#define ENEMY_SIZE 32
#define BULLET_W 16
#define BULLET_H 16
#define PLAYER_INVULNERABLE_MS 900u
#define EFFECT_LIFETIME_MS 420u
#define INITIAL_LIVES 3u

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
    for (i = 0; i < GAME_ENEMY_LIMIT; ++i) {
        game_enemy_t *enemy = &game->enemies[i];
        if (enemy->active) continue;
        v = game_random(game);
        enemy->x = (int16_t)(8u + v % (GAME_WORLD_WIDTH - ENEMY_SIZE - 16u));
        enemy->y = (int16_t)(GAME_WORLD_TOP + (v >> 8) % 40u);
        enemy->vx = (int8_t)((int32_t)((v >> 16) % 3u) - 1);
        enemy->active = 1u;
        break;
    }
    /* Difficulty ramps from a modest opening wave to the full stress load. */
    {
        uint32_t elapsed = now_ms - game->started_ms;
        uint32_t interval = elapsed < 18000u ? 620u - (elapsed / 3000u) * 55u : 290u;
        if (interval < 290u) interval = 290u;
        game->next_spawn_ms = now_ms + interval;
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
            game->effects[i].expires_ms = now_ms + EFFECT_LIFETIME_MS;
            game->effects[i].active = 1u;
            return;
        }
    }
}

void survival_game_reset(survival_game_t *game, uint32_t now_ms) {
    uint8_t *bytes = (uint8_t *)game;
    uint32_t i;
    for (i = 0; i < (uint32_t)sizeof(*game); ++i) bytes[i] = 0;
    game->player_x = (int16_t)((GAME_WORLD_WIDTH - GAME_PLAYER_SIZE) / 2u);
    game->player_y = (int16_t)(GAME_WORLD_HEIGHT - GAME_PLAYER_SIZE - 16u);
    game->started_ms = now_ms;
    game->last_ms = now_ms;
    game->next_spawn_ms = now_ms;
    game->next_fire_ms = now_ms;
    game->lives = INITIAL_LIVES;
    game->rng = UINT32_C(0x7a31c5e9) ^ now_ms;
}

uint32_t survival_game_sprite_count(const survival_game_t *game, uint32_t now_ms) {
    /* The player is rendered as two independent sprites: a glow and a ship. */
    uint32_t i, count = game->lives ? 2u : 0u;
    for (i = 0; i < GAME_ENEMY_LIMIT; ++i) count += game->enemies[i].active != 0u;
    for (i = 0; i < GAME_BULLET_LIMIT; ++i) count += game->bullets[i].active != 0u;
    for (i = 0; i < GAME_EFFECT_LIMIT; ++i)
        count += game->effects[i].active && !time_reached(now_ms, game->effects[i].expires_ms);
    return count;
}

void survival_game_step(survival_game_t *game, uint8_t buttons, uint32_t now_ms) {
    uint32_t i;
    int32_t dx = 0, dy = 0;
    if (game->game_over) {
        if ((buttons & UART_KEY_FIRE) && !(game->previous_buttons & UART_KEY_FIRE))
            survival_game_reset(game, now_ms);
        game->previous_buttons = buttons;
        game->last_ms = now_ms;
        return;
    }
    if ((buttons & UART_KEY_PAUSE) && !(game->previous_buttons & UART_KEY_PAUSE))
        game->paused ^= 1u;
    game->previous_buttons = buttons;
    game->last_ms = now_ms;
    if (game->paused) return;

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
    if (time_reached(now_ms, game->next_spawn_ms) && enemy_count(game) < GAME_ENEMY_LIMIT)
        spawn_enemy(game, now_ms);

    for (i = 0; i < GAME_BULLET_LIMIT; ++i) {
        game_bullet_t *bullet = &game->bullets[i];
        uint32_t j;
        if (!bullet->active) continue;
        bullet->y = (int16_t)(bullet->y - 9);
        if (bullet->y + BULLET_H < (int32_t)GAME_WORLD_TOP) {
            bullet->active = 0u;
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
        if (enemy->move_phase) enemy->y = (int16_t)(enemy->y + 1);
        if (enemy->y >= (int32_t)GAME_WORLD_HEIGHT) {
            enemy->active = 0u;
            if (game->lives) --game->lives;
            continue;
        }
        if (!game->invulnerable && intersects(game->player_x, game->player_y,
                GAME_PLAYER_SIZE, GAME_PLAYER_SIZE, enemy->x, enemy->y, ENEMY_SIZE, ENEMY_SIZE)) {
            enemy->active = 0u;
            if (game->lives) --game->lives;
            game->invulnerable = 1u;
            game->invulnerable_until_ms = now_ms + PLAYER_INVULNERABLE_MS;
        }
    }
    if (game->invulnerable && time_reached(now_ms, game->invulnerable_until_ms))
        game->invulnerable = 0u;
    if (game->lives == 0u) game->game_over = 1u;
    ++game->frames;
    {
        uint32_t sprites = survival_game_sprite_count(game, now_ms);
        if (sprites > game->max_sprites_seen) game->max_sprites_seen = sprites;
    }
}
