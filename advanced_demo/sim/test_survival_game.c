#include <assert.h>
#include <stdint.h>
#include "../software/interactive_demo/game_logic.h"

static void movement_is_bounded(void) {
    survival_game_t game;
    uint32_t i;
    survival_game_reset(&game, 0u);
    for (i = 0; i < 200u; ++i)
        survival_game_step(&game, UART_KEY_LEFT | UART_KEY_UP, i * 16u);
    assert(game.player_x == 0);
    assert(game.player_y == (int16_t)GAME_WORLD_TOP);
    for (i = 200u; i < 500u; ++i)
        survival_game_step(&game, UART_KEY_RIGHT | UART_KEY_DOWN, i * 16u);
    assert(game.player_x == (int16_t)(GAME_WORLD_WIDTH - GAME_PLAYER_SIZE));
    assert(game.player_y == (int16_t)(GAME_WORLD_HEIGHT - GAME_PLAYER_SIZE));
}

static void firing_and_scoring_work(void) {
    survival_game_t game;
    uint32_t now;
    survival_game_reset(&game, 0u);
    game.next_spawn_ms = 100000u;
    game.enemies[0].x = game.player_x;
    game.enemies[0].y = (int16_t)(game.player_y - 96);
    game.enemies[0].active = 1u;
    for (now = 0; now < 700u; now += 16u)
        survival_game_step(&game, UART_KEY_FIRE, now);
    assert(game.score >= 10u);
    assert(game.frames > 0u);
    assert(game.max_sprites_seen >= 1u);
}

static void pause_and_restart_are_edge_triggered(void) {
    survival_game_t game;
    survival_game_reset(&game, 0u);
    survival_game_step(&game, UART_KEY_PAUSE, 16u);
    assert(game.paused == 1u);
    survival_game_step(&game, UART_KEY_PAUSE, 32u);
    assert(game.paused == 1u);
    survival_game_step(&game, 0u, 48u);
    survival_game_step(&game, UART_KEY_PAUSE, 64u);
    assert(game.paused == 0u);
    game.lives = 0u;
    game.game_over = 1u;
    survival_game_step(&game, UART_KEY_FIRE, 80u);
    assert(game.game_over == 0u);
    assert(game.lives == 3u);
    assert(game.score == 0u);
}

static void sprite_count_includes_transient_effects(void) {
    survival_game_t game;
    survival_game_reset(&game, 10u);
    game.enemies[0].active = 1u;
    game.bullets[0].active = 1u;
    game.effects[0].active = 1u;
    game.effects[0].expires_ms = 100u;
    assert(survival_game_sprite_count(&game, 50u) == 5u);
    assert(survival_game_sprite_count(&game, 100u) == 4u);
}

static void pause_preserves_remaining_time(uint32_t origin) {
    survival_game_t game;
    uint32_t resumed = origin + 3020u;
    int16_t initial_x;
    survival_game_reset(&game, origin);
    initial_x = game.player_x;
    game.next_spawn_ms = origin + 500u;
    game.next_fire_ms = origin + 700u;
    game.invulnerable = 1u;
    game.invulnerable_until_ms = origin + 600u;
    game.effects[0].active = 1u;
    game.effects[0].expires_ms = origin + 520u;
    survival_game_step(&game, UART_KEY_PAUSE | UART_KEY_RIGHT, origin + 20u);
    survival_game_step(&game, UART_KEY_PAUSE | UART_KEY_RIGHT, origin + 1020u);
    survival_game_step(&game, UART_KEY_RIGHT, origin + 2020u);
    assert(game.player_x == initial_x);
    assert(game.frames == 0u);
    assert(game.lives == 3u);
    survival_game_step(&game, UART_KEY_PAUSE, resumed);
    assert(game.paused == 0u);
    assert(game.started_ms == resumed); /* Difficulty did not advance. */
    assert(game.next_spawn_ms - resumed == 500u);
    assert(game.next_fire_ms - resumed == 700u);
    assert(game.invulnerable && game.invulnerable_until_ms - resumed == 600u);
    assert(game.effects[0].expires_ms - resumed == 520u);
    assert(survival_game_sprite_count(&game, resumed) == 3u);
    survival_game_step(&game, 0u, resumed + 520u);
    assert(game.enemies[0].active); /* Spawning resumes at its deadline. */
    assert(game.invulnerable);
    assert(survival_game_sprite_count(&game, resumed + 520u) == 3u);
    survival_game_step(&game, UART_KEY_FIRE, resumed + 704u); /* Next 16 ms tick. */
    assert(!game.invulnerable);
    assert(game.bullets[0].active);
}

static void enemy_wave_reaches_high_load(void) {
    survival_game_t game;
    uint32_t i;
    survival_game_reset(&game, 0u);
    game.lives = 255u; /* Keep the unattended stress wave running. */
    for (i = 0; i < 4000u; ++i)
        survival_game_step(&game, 0u, i * 16u);
    assert(game.max_sprites_seen >= 32u);
    assert(game.max_sprites_seen <= GAME_ENEMY_LIMIT + GAME_ENEMY_BULLET_LIMIT +
           GAME_BULLET_LIMIT + GAME_EFFECT_LIMIT + 2u);
}

static void automatic_restart_preserves_options(uint32_t origin) {
    survival_game_t game;
    survival_game_reset(&game, origin);
    survival_game_set_options(&game, 3000u, 450u, 5u, 0u);
    game.lives = 0u;
    survival_game_step(&game, 0u, origin + 16u);
    assert(game.game_over);
    survival_game_step(&game, 0u, origin + 3015u);
    assert(game.game_over);
    survival_game_step(&game, 0u, origin + 3016u);
    assert(!game.game_over && game.lives == 3u);
    assert(game.enemy_limit == 5u && game.enemy_fire_interval_ms == 450u);
    survival_game_set_options(&game, 0u, 450u, 5u, 0u);
    game.lives = 0u;
    survival_game_step(&game, 0u, origin + 3032u);
    survival_game_step(&game, 0u, origin + 10000u);
    assert(game.game_over); /* Disabled auto restart stays stopped. */
}

static void enemy_projectiles_hit_and_invincibility_works(void) {
    survival_game_t game;
    survival_game_reset(&game, 0u);
    game.next_spawn_ms = 100000u;
    game.enemies[0].x = game.player_x;
    game.enemies[0].y = game.player_y - 80;
    game.enemies[0].active = 1u;
    game.next_enemy_fire_ms = 16u;
    survival_game_step(&game, 0u, 16u);
    assert(game.enemy_bullets[0].active && game.enemy_bullets[0].vy > 0);
    game.enemy_bullets[0].x = game.player_x + 13;
    game.enemy_bullets[0].y = game.player_y + 13;
    game.enemy_bullets[0].vx = game.enemy_bullets[0].vy = 0;
    survival_game_step(&game, 0u, 32u);
    assert(game.lives == 2u && game.invulnerable);
    game.invulnerable = 0u;
    game.invincible_mode = 1u;
    game.enemy_bullets[0].active = 1u;
    survival_game_step(&game, 0u, 48u);
    assert(game.lives == 2u);
}

static void motion_is_independent_of_render_rate(void) {
    survival_game_t fast, slow;
    uint32_t now;
    survival_game_reset(&fast, 0u);
    survival_game_reset(&slow, 0u);
    for (now = 16u; now <= 1600u; now += 16u)
        survival_game_step(&fast, UART_KEY_RIGHT | UART_KEY_FIRE, now);
    for (now = 80u; now <= 1600u; now += 80u)
        survival_game_step(&slow, UART_KEY_RIGHT | UART_KEY_FIRE, now);
    assert(fast.player_x == slow.player_x && fast.frames == slow.frames);
    assert(fast.score == slow.score && fast.rng == slow.rng);
    assert(fast.enemies[0].x == slow.enemies[0].x && fast.enemies[0].y == slow.enemies[0].y);
    assert(survival_game_sprite_count(&fast, now) == survival_game_sprite_count(&slow, now));
}

static void parameter_bounds_and_pending_fire(void) {
    survival_game_t game;
    survival_game_reset(&game, 0u);
    survival_game_set_options(&game, UINT32_MAX, 0u, 255u, 1u);
    assert(game.auto_restart_ms == 60000u && game.enemy_fire_interval_ms == 150u);
    assert(game.enemy_limit == GAME_ENEMY_LIMIT && game.invincible_mode);
    survival_game_step(&game, UART_KEY_FIRE, 1u);
    survival_game_step(&game, 0u, 16u);
    assert(game.bullets[0].active);
    survival_game_step(&game, 0u, 10000u);
    assert(game.dropped_ms > 0u && game.frames <= 65u);
    survival_game_set_options(&game, 0u, UINT32_MAX, 1u, 0u);
    assert(game.enemy_fire_interval_ms == 10000u && game.enemy_limit == 1u);
    assert(!game.enemies[1].active);
}

int main(void) {
    movement_is_bounded();
    firing_and_scoring_work();
    pause_and_restart_are_edge_triggered();
    pause_preserves_remaining_time(100u);
    pause_preserves_remaining_time(UINT32_MAX - 500u);
    sprite_count_includes_transient_effects();
    enemy_wave_reaches_high_load();
    automatic_restart_preserves_options(0u);
    automatic_restart_preserves_options(UINT32_MAX - 1000u);
    enemy_projectiles_hit_and_invincibility_works();
    motion_is_independent_of_render_rate();
    parameter_bounds_and_pending_fire();
    return 0;
}
