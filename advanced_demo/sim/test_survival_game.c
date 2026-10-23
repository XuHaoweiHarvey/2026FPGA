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

static void enemy_wave_reaches_high_load(void) {
    survival_game_t game;
    uint32_t i;
    survival_game_reset(&game, 0u);
    game.lives = 255u; /* Keep the unattended stress wave running. */
    for (i = 0; i < 4000u; ++i)
        survival_game_step(&game, 0u, i * 16u);
    assert(game.max_sprites_seen >= 32u);
    assert(game.max_sprites_seen <= GAME_ENEMY_LIMIT + 2u);
}

int main(void) {
    movement_is_bounded();
    firing_and_scoring_work();
    pause_and_restart_are_edge_triggered();
    sprite_count_includes_transient_effects();
    enemy_wave_reaches_high_load();
    return 0;
}
