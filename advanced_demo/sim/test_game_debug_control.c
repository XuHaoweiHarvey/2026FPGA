#include <assert.h>
#include <stdint.h>

static uint32_t mock_engine_status, mock_buffer_status, mock_swaps, mock_underflows, mock_missed, mock_boundaries;
static uint32_t mock_writer_throttle, mock_writer_bursts, mock_reader_ar_stall, mock_reader_r_stall, mock_commands;
static uint32_t mock_read(uint32_t offset) {
    if (offset == 0x0cu) return mock_engine_status;
    if (offset == 0x64u) return mock_buffer_status;
    if (offset == 0x80u) return mock_swaps;
    if (offset == 0xa4u) return mock_underflows;
    if (offset == 0x84u) return mock_missed;
    if (offset == 0x7cu) return mock_boundaries;
    if (offset == 0x8cu) return mock_writer_throttle;
    if (offset == 0x90u) return mock_writer_bursts;
    if (offset == 0x94u) return mock_reader_ar_stall;
    if (offset == 0x9cu) return mock_reader_r_stall;
    if (offset == 0x5cu) return mock_commands;
    return 0u;
}

#define MOCK_GAME_REG_READ mock_read
static uint32_t mock_mmio_read(uintptr_t address) { (void)address; return 0u; }
#define MOCK_GAME_MMIO_READ mock_mmio_read
#define UART_KEY_READ32 mock_mmio_read
#define SURVIVAL_GAME_HOST_SYNTAX
#define GAME_FLASH_ENABLE 0
#define main board_game_main
#include "../software/interactive_demo/game_main.c"
#undef main

static void compact_sprites_decode_to_expected_pixels(void) {
    static const uint32_t expected[] = {
        3436895652u, 2416158720u, 412690895u, 588307204u, 3107072876u,
        3544371140u, 2740635802u, 3481704964u, 1409077671u, 474391060u
    };
    uint32_t i, x, y, shift, dx, dy;
    assert(GAME_TEAM_SPRITE_COUNT == sizeof(expected) / sizeof(expected[0]));
    for (i = 0u; i < GAME_TEAM_SPRITE_COUNT; ++i) {
        const game_team_sprite_t *s = &game_team_sprites[i];
        uint32_t hash = UINT32_C(2166136261), clear = 0u, opaque = 0u, partial = 0u;
        assert(s->x + s->size <= 640u && s->y + s->size <= 480u);
        for (y = 0u; y < s->size; ++y) for (x = 0u; x < s->size; ++x) {
            uint32_t pixel = game_team_sprite_pixel(s->x + x, s->y + y);
            uint32_t alpha = pixel >> 24;
            for (dy = 0u; dy < GAME_PIXEL_SCALE; ++dy)
                for (dx = 0u; dx < GAME_PIXEL_SCALE; ++dx)
                    assert(atlas_pixel((s->x + x) * GAME_PIXEL_SCALE + dx,
                                       (s->y + y) * GAME_PIXEL_SCALE + dy) == pixel);
            for (shift = 0u; shift < 32u; shift += 8u)
                hash = (hash ^ ((pixel >> shift) & 255u)) * UINT32_C(16777619);
            if (!alpha) {
                ++clear;
                if (i < 2u) assert(pixel == COLOR_KEY);
            } else if (alpha == 255u) ++opaque;
            else ++partial;
            if (i < 2u && alpha) assert((pixel & UINT32_C(0x00ffffff)) != COLOR_KEY);
        }
        assert(hash == expected[i] && clear && opaque);
        if (i < 2u) assert(!partial);
        if (i == 2u || i == 3u || i >= 7u) assert(partial);
    }
    assert(game_team_sprite_pixel(639u, 479u) == COLOR_KEY);
    assert(game_team_sprite_pixel(64u, 32u) == COLOR_KEY);
    assert(game_team_sprite_pixel(192u, 64u) == COLOR_KEY);
    assert(game_team_sprite_pixel(UINT32_MAX, UINT32_MAX) == COLOR_KEY);
    assert((atlas_pixel(31u, 31u) >> 24) > 0u); /* Retained player halo. */
}

#if GAME_TEAM_BACKGROUND
static void island_background_matches_the_supplied_image(void) {
    uint32_t hash = UINT32_C(2166136261), x, y, shift;
    for (y = 0u; y < 90u; ++y) for (x = 0u; x < 160u; ++x) {
        uint32_t pixel = game_background_pixel(x * 12u, y * 12u);
        assert(game_background_pixel(x * 12u + 11u, y * 12u + 11u) == pixel);
        for (shift = 0u; shift < 32u; shift += 8u)
            hash = (hash ^ ((pixel >> shift) & 255u)) * UINT32_C(16777619);
    }
    assert(hash == UINT32_C(533667732));
}
#endif

#if GAME_TEAM_BACKGROUND && !GAME_FULLSCREEN
static void centered_game_keeps_the_island_and_only_restores_the_viewport(void) {
    uint32_t i;
    mock_game_blits = mock_game_swaps = mock_game_display_op_count = 0u;
    initialize_centered_island_background();
    assert(mock_game_blits == 2u && mock_game_swaps == 2u);
    assert(mock_game_display_op_count == 4u);
    assert(mock_game_display_ops[0] == 3u && mock_game_display_ops[1] == 2u);
    assert(mock_game_display_ops[2] == 3u && mock_game_display_ops[3] == 2u);
    assert(mock_game_blit_source == FULL_BACKGROUND_PHYS);
    assert(mock_game_blit_x == 0u && mock_game_blit_y == 0u);
    assert(mock_game_blit_width == 1920u && mock_game_blit_height == 1080u);
    survival_game_reset(&g_game, 0u);
    for (i = 0u; i < 3u; ++i) {
        uint32_t before = mock_game_blits;
        render_frame(i * 17u);
        assert(mock_game_blits == before + 1u);
        assert(mock_game_blit_source == FULL_BACKGROUND_PHYS + 300u * 7680u + 640u * 4u);
        assert(mock_game_blit_x == 640u && mock_game_blit_y == 300u);
        assert(mock_game_blit_width == 640u && mock_game_blit_height == 480u);
        assert(g_game_runtime.background_pixels == 640u * 480u);
        assert(g_game_runtime.background_rectangles == 1u);
    }
    g_game.enemy_limit = 0u;
}
#endif

#if GAME_FULLSCREEN
static void background_restore_tracks_the_actual_back_slot(void) {
    uint32_t i;
    mock_game_blits = 0u;
    g_background_dirty[0].valid = g_background_dirty[1].valid = 0u;
    restore_game_background(0u);
    assert(mock_game_blits == 1u && mock_game_blit_source == FULL_BACKGROUND_PHYS);
    assert(mock_game_blit_width == 1920u && mock_game_blit_height == 1080u);
    assert(g_current_dirty == &g_background_dirty[0]);
    draw_key_sprite(128u, 0u, 128, 192, 64u);
    assert(g_background_dirty[0].rows[12][0] == 0x0f00u);
    restore_game_background(UINT32_C(0x00800000));
    assert(mock_game_blits == 2u && g_current_dirty == &g_background_dirty[1]);
    assert(g_background_dirty[0].rows[12][0] == 0x0f00u); /* Old slot is retained. */
    draw_alpha_sprite(256u, 0u, 1912, 1072, 32u, 225u);
    restore_game_background(0u);
    assert(mock_game_blits == 3u);
    assert(mock_game_blit_source == FULL_BACKGROUND_PHYS + 192u * 7680u + 128u * 4u);
    assert(mock_game_blit_x == 128u && mock_game_blit_y == 192u);
    assert(mock_game_blit_width == 64u && mock_game_blit_height == 64u);
    restore_game_background(UINT32_C(0x00800000));
    assert(mock_game_blits == 4u);
    assert(mock_game_blit_x == 1904u && mock_game_blit_y == 1072u);
    assert(mock_game_blit_width == 16u && mock_game_blit_height == 8u);
    restore_game_background(0u);
    assert(mock_game_blits == 4u); /* Nothing drawn since its previous restore. */
    game_background_mark(g_current_dirty, 0u, 0u, 1920u, 1080u);
    restore_game_background(0u);
    assert(mock_game_blits == 5u && mock_game_blit_source == FULL_BACKGROUND_PHYS);
    assert(mock_game_blit_width == 1920u && mock_game_blit_height == 1080u);
    for (i = 0u; i < GAME_DIRTY_ROWS * GAME_DIRTY_WORDS; ++i)
        assert(!g_current_dirty->rows[i / GAME_DIRTY_WORDS][i % GAME_DIRTY_WORDS]);
    restart_game(0u);
    assert(!g_background_dirty[0].valid && !g_background_dirty[1].valid);
    g_current_dirty = 0;
    g_game.enemy_limit = 0u; /* Restore the startup fixture for command tests. */
}

static void background_pixels_and_dirty_rectangles_cover_damage(void) {
    game_background_dirty_t slots[2] = {0};
    uint8_t expected[GAME_DIRTY_ROWS][GAME_DIRTY_COLS] = {{0}};
    uint8_t restored[GAME_DIRTY_ROWS][GAME_DIRTY_COLS] = {{0}};
    uint32_t hash = UINT32_C(2166136261), x, y, w, h, i, row, col, shift;
    uint32_t seed = 419u, rectangles = 0u;
    /* Independently calculated from the committed RGB PNG in B,G,R,0 order. */
    for (y = 0u; y < 90u; ++y) for (x = 0u; x < 160u; ++x) {
        uint32_t pixel = game_background_pixel(x * 12u, y * 12u);
        assert(game_background_pixel(x * 12u + 11u, y * 12u + 11u) == pixel);
        for (shift = 0u; shift < 32u; shift += 8u)
            hash = (hash ^ ((pixel >> shift) & 255u)) * UINT32_C(16777619);
    }
    assert(hash == UINT32_C(533667732));
    game_background_mark(&slots[0], 1919u, 1079u, UINT32_MAX, UINT32_MAX);
    assert(game_background_bit(&slots[0], 67u, 119u));
    assert(!game_background_bit(&slots[1], 67u, 119u));
    assert(game_background_next(&slots[0], &x, &y, &w, &h));
    assert(x == 1904u && y == 1072u && w == 16u && h == 8u);
    assert(!game_background_next(&slots[0], &x, &y, &w, &h));
    game_background_mark(&slots[0], 1920u, 0u, 8u, 8u);
    game_background_mark(&slots[0], 0u, 1080u, 8u, 8u);
    game_background_mark(&slots[0], 0u, 0u, 0u, 8u);
    assert(!game_background_next(&slots[0], &x, &y, &w, &h));
    for (i = 0u; i < 160u; ++i) {
        seed = seed * UINT32_C(1664525) + UINT32_C(1013904223); x = seed % 1930u;
        seed = seed * UINT32_C(1664525) + UINT32_C(1013904223); y = seed % 1090u;
        w = 1u + (seed >> 16) % 128u; h = 1u + (seed >> 24) % 128u;
        game_background_mark(&slots[0], x, y, w, h);
        if (x >= 1920u || y >= 1080u) continue;
        if (w > 1920u - x) w = 1920u - x;
        if (h > 1080u - y) h = 1080u - y;
        for (row = 0u; row < GAME_DIRTY_ROWS; ++row) for (col = 0u; col < GAME_DIRTY_COLS; ++col)
            if (col * GAME_DIRTY_TILE < x + w && (col + 1u) * GAME_DIRTY_TILE > x &&
                row * GAME_DIRTY_TILE < y + h && (row + 1u) * GAME_DIRTY_TILE > y) expected[row][col] = 1u;
    }
    while (game_background_next(&slots[0], &x, &y, &w, &h)) {
        ++rectangles;
        assert(x % GAME_DIRTY_TILE == 0u && y % GAME_DIRTY_TILE == 0u && w % GAME_DIRTY_TILE == 0u);
        assert(x + w <= 1920u && y + h <= 1080u && w && h);
        for (row = y / GAME_DIRTY_TILE; row <= (y + h - 1u) / GAME_DIRTY_TILE; ++row)
            for (col = x / GAME_DIRTY_TILE; col < (x + w) / GAME_DIRTY_TILE; ++col) {
                assert(!restored[row][col]);
                restored[row][col] = 1u;
            }
    }
    assert(rectangles);
    for (row = 0u; row < GAME_DIRTY_ROWS; ++row) for (col = 0u; col < GAME_DIRTY_COLS; ++col) {
        assert(!expected[row][col] || restored[row][col]);
        assert(!game_background_bit(&slots[1], row, col));
    }
    {
        game_background_dirty_t merge = {0};
        game_background_mark(&merge, 0u, 0u, 48u, 16u);
        game_background_mark(&merge, 64u, 0u, 48u, 16u);
        assert(game_background_next(&merge, &x, &y, &w, &h));
        assert(x == 0u && y == 0u && w == 112u && h == 16u);
        assert(!game_background_next(&merge, &x, &y, &w, &h));
    }
    game_background_mark(&slots[0], 0u, 0u, 1920u, 1080u);
    assert(game_background_next(&slots[0], &x, &y, &w, &h));
    assert(x == 0u && y == 0u && w == 1920u && h == 1080u);
    assert(!game_background_next(&slots[0], &x, &y, &w, &h));
}
#endif

static void explosion_frames_and_fade_follow_game_time(uint32_t origin) {
    uint32_t elapsed, previous = 255u;
    uint32_t expires = origin + GAME_EFFECT_LIFETIME_MS;
    survival_game_t game;
    assert(GAME_EFFECT_LIFETIME_MS == GAME_TEAM_EXPLOSION_DURATION_MS);
    for (elapsed = 0u; elapsed < GAME_EFFECT_LIFETIME_MS; ++elapsed) {
        uint32_t alpha = game_team_explosion_alpha(origin + elapsed, expires);
        assert(game_team_explosion_frame(origin + elapsed, expires) == elapsed / 70u);
        assert(alpha <= previous);
        previous = alpha;
    }
    assert(game_team_explosion_frame(expires, expires) == GAME_TEAM_EXPLOSION_FRAMES);
    assert(game_team_explosion_frame(expires + 1u, expires) == GAME_TEAM_EXPLOSION_FRAMES);
    assert(game_team_explosion_alpha(expires, expires) == 0u);
    assert(game_team_explosion_alpha(expires + 1u, expires) == 0u);
    assert(game_team_explosion_alpha(origin, expires) == 255u);
    assert(game_team_explosion_alpha(origin + 210u, expires) == 127u);
    survival_game_reset(&game, origin);
    game.effects[0].active = 1u;
    game.effects[0].expires_ms = expires;
    survival_game_step(&game, 0u, origin + 140u);
    survival_game_step(&game, UART_KEY_PAUSE, origin + 140u);
    survival_game_step(&game, 0u, origin + 1140u);
    assert(game.paused);
    assert(game_team_explosion_frame(origin + 1140u, game.effects[0].expires_ms) == 2u);
    assert(game_team_explosion_alpha(origin + 1140u, game.effects[0].expires_ms) == 170u);
    survival_game_step(&game, UART_KEY_PAUSE, origin + 2140u);
    assert(!game.paused);
    assert(game_team_explosion_frame(origin + 2140u, game.effects[0].expires_ms) == 2u);
}

static void both_display_buffers_start_with_the_same_fullscreen_background(void) {
    mock_game_fullscreen_fills = 0u;
    mock_game_swaps = 0u;
    mock_game_display_op_count = 0u;
    mock_game_fill_result = 0u;
    mock_game_swap_result = 0u;
    mock_underflows = 0u;
    mock_missed = 0u;
    initialize_display_background();
    assert(mock_game_fullscreen_fills == 2u);
    assert(mock_game_swaps == 2u);
    assert(mock_game_display_op_count == 4u);
    assert(mock_game_display_ops[0] == 1u && mock_game_display_ops[1] == 2u);
    assert(mock_game_display_ops[2] == 1u && mock_game_display_ops[3] == 2u);
    assert(g_game_result.error == 0u);
}

static void send_command(uint32_t command, uint32_t now_ms) {
    g_debug_control.command = command;
    ++g_debug_control.sequence;
    service_debug_command(now_ms);
    assert(g_debug_status.acknowledged_sequence == g_debug_control.sequence);
}

static void control_commands_run_once_and_preserve_configuration(void) {
    g_debug_control.magic = GAME_DEBUG_CONTROL_MAGIC;
    g_debug_control.auto_restart_ms = 0u;
    g_debug_control.enemy_fire_interval_ms = 350u;
    g_debug_control.enemy_limit = 7u;
    g_debug_control.flags = 1u;
    g_debug_control.projectile_alpha = 90u;
    send_command(GAME_DEBUG_CMD_RESTART, 100u);
    assert(g_game.lives == 3u && g_game.enemy_limit == 7u && g_game.invincible_mode);
    g_game.score = 40u;
    service_debug_command(200u); /* Already acknowledged; no second reset. */
    assert(g_game.score == 40u);
    send_command(GAME_DEBUG_CMD_APPLY_OPTIONS, 200u);
    assert(g_projectile_alpha == 90u && g_game.auto_restart_ms == 0u);
    send_command(GAME_DEBUG_CMD_PAUSE, 200u);
    assert(g_game.paused);
    survival_game_step(&g_game, 0u, 1200u);
    send_command(GAME_DEBUG_CMD_RESUME, 2200u);
    assert(!g_game.paused && g_game.started_ms == 2200u);
    assert(g_game.next_spawn_ms == 2200u);
    g_debug_control.enemy_limit = UINT32_MAX;
    g_debug_control.projectile_alpha = UINT32_MAX;
    send_command(GAME_DEBUG_CMD_APPLY_OPTIONS, 2200u);
    assert(g_game.enemy_limit == GAME_ENEMY_LIMIT && g_projectile_alpha == 255u);
}

static void hardware_hud_is_cached_and_gameplay_cannot_erase_it(void) {
    uint32_t first, i;
    survival_game_reset(&g_game, 0u);
    g_scene_mode = 0u;
    g_hud_cache[0].valid = g_hud_cache[1].valid = 0u;
    mock_game_keys = 0u;
    render_hud(0u, 0u);
    first = mock_game_keys;
    assert(first > 20u);
    render_hud(0u, 20u);
#if GAME_FULLSCREEN
    assert(mock_game_keys == first); /* No glyph writes for unchanged slot. */
    render_hud(0x00800000u, 20u);
    assert(mock_game_keys == 2u * first); /* Independent physical-slot cache. */
    g_game.lives = 2u;
    render_hud(0u, 40u);
    assert(mock_game_keys > 2u * first);
    g_current_dirty = &g_background_dirty[0];
    for (i = 0u; i < GAME_DIRTY_ROWS * GAME_DIRTY_WORDS; ++i)
        g_current_dirty->rows[i / GAME_DIRTY_WORDS][i % GAME_DIRTY_WORDS] = 0u;
#else
    (void)i;
#endif
    draw_alpha_sprite(0u, 0u, 0, (int32_t)GAME_WORLD_TOP - 4, 32u, 225u);
    assert(mock_game_sprite_y == VIEW_Y + GAME_WORLD_TOP && mock_game_sprite_h == 28u);
    draw_key_sprite(128u, 0u, (int32_t)VIEW_W - 8, (int32_t)GAME_WORLD_TOP - 8, 32u);
    assert(mock_game_sprite_y == VIEW_Y + GAME_WORLD_TOP && mock_game_sprite_h == 24u);
    assert(mock_game_sprite_w == 8u);
#if GAME_FULLSCREEN
    for (i = 0u; i < GAME_WORLD_TOP / GAME_DIRTY_TILE; ++i)
        assert(g_current_dirty->rows[i][0] == 0u); /* Gameplay never dirties HUD. */
    g_current_dirty = 0;
#endif
    g_game.enemy_limit = 0u;
}

static void stress_command_and_measurement_preconditions_are_enforced(void) {
    send_command(GAME_DEBUG_CMD_MEASURE_60S, 2500u);
    assert(g_debug_status.command_result == 0xed03u); /* Campaign is not a fixed-load test. */
    send_command(GAME_DEBUG_CMD_STRESS, 2600u);
    assert(!g_debug_status.command_result && g_game.stress_mode && g_game.invincible_mode);
    assert(g_game.enemy_limit == 48u && !g_game.campaign_stage);
    assert(survival_game_sprite_count(&g_game, 2600u) == 114u);
    send_command(GAME_DEBUG_CMD_MEASURE_60S, 2700u);
    assert(!g_debug_status.command_result && g_debug_status.measurement_state == 1u);
    send_command(GAME_DEBUG_CMD_APPLY_OPTIONS, 2800u);
    assert(g_debug_status.command_result == 0xed04u);
    g_debug_status.measurement_state = 0u;
}

static void owned_hardware_and_measurement_reject_transitions(void) {
    uint32_t score = g_game.score;
    mock_engine_status = ACCEL_BUSY;
    send_command(GAME_DEBUG_CMD_RESTART, 2300u);
    assert(g_debug_status.command_result == 0xed02u && g_game.score == score);
    mock_engine_status = 0u;
    mock_buffer_status = FRAME_SWAP_PENDING;
    send_command(GAME_DEBUG_CMD_RESTART, 2300u);
    assert(g_debug_status.command_result == 0xed02u);
    mock_buffer_status = 0u;
    g_debug_status.measurement_state = 1u;
    send_command(GAME_DEBUG_CMD_RESTART, 2300u);
    assert(g_debug_status.command_result == 0xed04u);
    g_debug_status.measurement_state = 0u;
    send_command(99u, 2300u);
    assert(g_debug_status.command_result == 0xed03u);
    g_debug_control.enemy_limit = 2u; /* Unapplied mailbox data. */
    send_command(GAME_DEBUG_CMD_RESTART, 2400u);
    assert(g_game.enemy_limit == GAME_ENEMY_LIMIT);
}

static void measurement_uses_completed_frames_and_keeps_raw_counters(void) {
    uint32_t i;
    g_debug_status.measurement_state = 1u;
    g_debug_status.measurement_frames = 0u;
    g_debug_status.measurement_min_fps_x100 = UINT32_MAX;
    g_debug_status.measurement_min_sprites = UINT32_MAX;
    g_debug_status.measurement_max_sprites = 0u;
    g_measure_start = g_measure_window_ms = 0u;
    g_measure_window_frames = 0u;
    g_measure_swap_base = 50u;
    g_measure_underflow_base = 8u;
    g_measure_missed_base = 9u;
    g_measure_boundary_base = 50u;
    mock_writer_throttle = g_measure_writer_throttle_last = UINT32_MAX - 5u;
    mock_writer_bursts = g_measure_writer_bursts_last = UINT32_MAX - 5u;
    mock_reader_ar_stall = g_measure_reader_ar_stall_last = UINT32_MAX - 5u;
    mock_reader_r_stall = g_measure_reader_r_stall_last = UINT32_MAX - 5u;
    mock_commands = g_measure_commands_last = UINT32_MAX - 5u;
    g_measure_diag_sample_ms = 0u;
    g_measure_writer_throttle_total = g_measure_reader_ar_stall_total = 0u;
    g_measure_reader_r_stall_total = 0u;
    g_measure_writer_bursts_total = g_measure_commands_total = 0u;
    for (i = 1u; i <= 3600u; ++i) {
        mock_swaps = 50u+i;
        mock_boundaries = 50u+i;
        mock_underflows = 8u;
        mock_missed = 9u;
        mock_writer_throttle += 3u;
        mock_writer_bursts += 2u;
        mock_reader_ar_stall += 4u;
        mock_reader_r_stall += 5u;
        mock_commands += 6u;
        g_rendered_sprites = i & 1u ? 80u : 96u;
        measure_frame(i*1000u/60u);
    }
    assert(g_debug_status.measurement_state == 2u);
    assert(g_debug_status.measurement_elapsed_ms == 60000u);
    assert(g_debug_status.measurement_frames == 3600u && g_debug_status.measurement_swaps == 3600u);
    assert(g_debug_status.measurement_min_fps_x100 == 6000u);
    assert(g_debug_status.measurement_min_sprites == 80u && g_debug_status.measurement_max_sprites == 96u);
    assert(!g_debug_status.measurement_underflows && !g_debug_status.measurement_missed);
    assert(g_game_runtime.measurement_display_frames == 3600u && !g_game_runtime.measurement_repeated_frames);
    assert(g_game_runtime.measurement_writer_throttle_cycles_lo == 10800u &&
           !g_game_runtime.measurement_writer_throttle_cycles_hi);
    assert(g_game_runtime.measurement_writer_bursts == 7200u);
    assert(g_game_runtime.measurement_reader_ar_stall_cycles_lo == 14400u &&
           g_game_runtime.measurement_reader_r_stall_cycles_lo == 18000u);
    assert(g_game_runtime.measurement_commands == 21600u);
    publish_status();
    assert(g_debug_status.raw_swaps == 3650u && g_debug_status.raw_underflows == 8u);
    assert(g_debug_status.raw_missed == 9u);
    assert(!(g_debug_status.publication & 1u));
    g_debug_status.measurement_state = 1u;
    mock_boundaries += 2u; /* A display boundary repeated the old Front. */
    ++mock_swaps;
    measure_frame(60034u);
    assert(g_game_runtime.measurement_repeated_frames == 1u);
}

int main(void) {
    compact_sprites_decode_to_expected_pixels();
#if GAME_TEAM_BACKGROUND
    island_background_matches_the_supplied_image();
#endif
#if GAME_TEAM_BACKGROUND && !GAME_FULLSCREEN
    centered_game_keeps_the_island_and_only_restores_the_viewport();
#endif
#if GAME_FULLSCREEN
    background_pixels_and_dirty_rectangles_cover_damage();
    background_restore_tracks_the_actual_back_slot();
#endif
    explosion_frames_and_fade_follow_game_time(1000u);
    explosion_frames_and_fade_follow_game_time(UINT32_MAX - 200u);
    both_display_buffers_start_with_the_same_fullscreen_background();
    hardware_hud_is_cached_and_gameplay_cannot_erase_it();
    control_commands_run_once_and_preserve_configuration();
    owned_hardware_and_measurement_reject_transitions();
    stress_command_and_measurement_preconditions_are_enforced();
    measurement_uses_completed_frames_and_keeps_raw_counters();
    return 0;
}
