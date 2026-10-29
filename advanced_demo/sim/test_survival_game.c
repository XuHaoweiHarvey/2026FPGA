#include <assert.h>
#include <stdint.h>
#include <string.h>
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
    game.enemy_bullets[0].x = game.player_x + 13 * GAME_PIXEL_SCALE;
    game.enemy_bullets[0].y = game.player_y + 13 * GAME_PIXEL_SCALE;
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

static void campaign_reaches_both_boss_phases_and_restarts(uint32_t origin) {
    survival_game_t game;
    uint32_t elapsed, i, before;
    survival_game_reset(&game, origin);
    survival_game_set_options(&game, 0u, 350u, 48u, 1u);
    game.difficulty = 2u;
    game.campaign_stage = GAME_CAMPAIGN_TITLE;
    survival_game_step(&game, 0u, origin + 1000u);
    assert(game.frames == 0u && !game.enemies[0].active);
    origin += 1000u;
    survival_game_step(&game, UART_KEY_FIRE, origin);
    assert(game.campaign_stage == 1u && game.difficulty == 2u);
    for (elapsed = 16u; elapsed <= 66000u; elapsed += 16u) {
        survival_game_step(&game, 0u, origin + elapsed);
        if (elapsed < 22000u) assert(game.campaign_stage == 1u);
        else if (elapsed < 44000u) assert(game.campaign_stage == 2u);
        else if (elapsed < 66000u) assert(game.campaign_stage == 3u);
    }
    /* 66000 is not a multiple of 16: the first Boss tick is 66000 rounded up. */
    survival_game_step(&game, 0u, origin + elapsed);
    assert(game.campaign_stage == 4u && game.boss.active && game.boss.hp == 90u);
    for (i = 0u; i < GAME_ENEMY_LIMIT; ++i) assert(!game.enemies[i].active);
    before = game.boss_next_fire_ms;
    survival_game_step(&game, UART_KEY_PAUSE, origin + elapsed + 10u);
    survival_game_step(&game, 0u, origin + elapsed + 1010u);
    survival_game_step(&game, UART_KEY_PAUSE, origin + elapsed + 2010u);
    assert(!game.paused && game.boss_next_fire_ms == before + 2010u);
    elapsed += 2010u;
    game.boss.hp = 45u;
    game.boss_next_fire_ms = origin + elapsed;
    survival_game_step(&game, 0u, origin + elapsed + 16u);
    elapsed += 16u;
    assert(game.boss.attack_phase == 2u);
    assert(game.enemy_bullets[0].active && game.enemy_bullets[15].active);
    game.boss.hp = 2u;
    for (i = 0u; i < 2u; ++i) {
        game.bullets[0].active = 1u;
        game.bullets[0].x = (int16_t)(game.boss.x + GAME_BOSS_SIZE / 2u);
        game.bullets[0].y = (int16_t)(game.boss.y + 24u * GAME_PIXEL_SCALE);
        survival_game_step(&game, 0u, origin + elapsed + 16u);
        elapsed += 16u;
    }
    assert(game.game_over && game.campaign_result == 1u && !game.boss.active);
    assert(game.boss.hp == 0u && game.score >= 1010u);
    for (i = 0u; i < GAME_ENEMY_BULLET_LIMIT; ++i) assert(!game.enemy_bullets[i].active);
    before = game.score;
    survival_game_step(&game, 0u, origin + elapsed + 5000u);
    assert(game.game_over && game.score == before); /* Results remain visible. */
    survival_game_step(&game, UART_KEY_FIRE, origin + elapsed + 5016u);
    assert(!game.game_over && game.campaign_stage == 1u && game.lives == 3u);
    assert(game.enemy_fire_interval_ms == 350u && game.invincible_mode && game.difficulty == 2u);
}

static void campaign_failure_and_stress_remain_distinct(void) {
    survival_game_t game;
    uint32_t now, sprites, minimum = UINT32_MAX;
    survival_game_reset(&game, 0u);
    survival_game_set_options(&game, 0u, 350u, 12u, 0u);
    survival_game_begin_campaign(&game, 0u);
    game.lives = 0u;
    survival_game_step(&game, 0u, 16u);
    assert(game.game_over && game.campaign_result == 2u);
    survival_game_step(&game, UART_KEY_FIRE, 32u);
    assert(game.campaign_stage == 1u && !game.game_over && !game.invincible_mode);
    survival_game_begin_stress(&game, 32u);
    assert(survival_game_sprite_count(&game, 32u) == 114u);
    for (now = 48u; now <= 100032u; now += 16u) {
        survival_game_step(&game, 0u, now);
        sprites = survival_game_sprite_count(&game, now);
        if (sprites < minimum) minimum = sprites;
        assert(game.campaign_stage == 0u && !game.game_over && game.invincible_mode);
    }
    assert(game.stress_mode && game.enemy_limit == 48u && minimum >= 114u);
}

#if GAME_STRESS_TUNING
static void dynamic_stress_loads_resize_and_stay_visible(uint32_t origin) {
    static const uint32_t loads[] = {1u, 64u, 128u, 256u, 512u, 17u};
    survival_game_t game, saved;
    uint32_t load, i, step, now = origin;
    survival_game_reset(&game, now);
    for (load = 0u; load < sizeof(loads)/sizeof(loads[0]); ++load) {
        uint32_t enemies = load & 1u ? 1u : GAME_ENEMY_LIMIT;
        assert(survival_game_begin_stress_load(&game, now, enemies, loads[load]));
        assert(game.enemy_limit == enemies && game.invincible_mode && game.stress_mode);
        assert(survival_game_enemy_bullet_limit(&game) == loads[load]);
        assert(survival_game_sprite_count(&game, now) == enemies + loads[load] + 2u);
        for (i = 0u; i < loads[load]; ++i) {
            assert(game.enemy_bullets[i].x >= 0 && game.enemy_bullets[i].y >= (int32_t)GAME_WORLD_TOP);
            assert((uint32_t)game.enemy_bullets[i].x + GAME_PROJECTILE_SIZE <= GAME_WORLD_WIDTH);
            assert((uint32_t)game.enemy_bullets[i].y + GAME_PROJECTILE_SIZE <= GAME_WORLD_HEIGHT);
        }
        for (step = 0u; step < 400u; ++step) {
            now += GAME_TICK_MS;
            survival_game_step(&game, UART_KEY_FIRE, now);
            for (i = 0u; i < GAME_ENEMY_LIMIT; ++i)
                assert((game.enemies[i].active != 0u) == (i < enemies));
            for (i = 0u; i < GAME_ENEMY_BULLET_CAPACITY; ++i)
                assert((game.enemy_bullets[i].active != 0u) == (i < loads[load]));
        }
    }
    saved = game;
    assert(!survival_game_begin_stress_load(&game, now, 0u, 64u));
    assert(!survival_game_begin_stress_load(&game, now, 49u, 64u));
    assert(!survival_game_begin_stress_load(&game, now, 48u, 0u));
    assert(!survival_game_begin_stress_load(&game, now, 48u, GAME_ENEMY_BULLET_CAPACITY + 1u));
    assert(!memcmp(&game, &saved, sizeof(game)));
    survival_game_begin_stress(&game, now);
    assert(survival_game_sprite_count(&game, now) == 114u);
    survival_game_begin_campaign(&game, now);
    assert(!game.stress_mode && survival_game_enemy_bullet_limit(&game) == 64u);
    for (i = 0u; i < GAME_ENEMY_BULLET_CAPACITY; ++i) assert(!game.enemy_bullets[i].active);
}
#endif

int main(void) {
    survival_game_t easy,normal,hard;
    survival_game_reset(&easy,0);survival_game_reset(&normal,0);survival_game_reset(&hard,0);
    easy.difficulty=0;hard.difficulty=2;
    assert(normal.difficulty == 1u);
    survival_game_step(&easy,0,GAME_TICK_MS);
    survival_game_step(&normal,0,GAME_TICK_MS);
    survival_game_step(&hard,0,GAME_TICK_MS);
    assert(easy.next_spawn_ms>normal.next_spawn_ms && normal.next_spawn_ms>hard.next_spawn_ms);
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
    campaign_reaches_both_boss_phases_and_restarts(0u);
    campaign_reaches_both_boss_phases_and_restarts(UINT32_MAX - 10000u);
    campaign_failure_and_stress_remain_distinct();
#if GAME_STRESS_TUNING
    dynamic_stress_loads_resize_and_stay_visible(0u);
    dynamic_stress_loads_resize_and_stay_visible(UINT32_MAX - 1000u);
#endif
    return 0;
}
