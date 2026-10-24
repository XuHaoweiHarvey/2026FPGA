#include <assert.h>
#include <stdint.h>

static uint32_t mock_engine_status, mock_buffer_status, mock_swaps, mock_underflows, mock_missed;
static uint32_t mock_read(uint32_t offset) {
    if (offset == 0x0cu) return mock_engine_status;
    if (offset == 0x64u) return mock_buffer_status;
    if (offset == 0x80u) return mock_swaps;
    if (offset == 0xa4u) return mock_underflows;
    if (offset == 0x84u) return mock_missed;
    return 0u;
}

#define MOCK_GAME_REG_READ mock_read
#define SURVIVAL_GAME_HOST_SYNTAX
#define GAME_FLASH_ENABLE 0
#define main board_game_main
#include "../software/interactive_demo/game_main.c"
#undef main

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
    for (i = 1u; i <= 3600u; ++i) {
        mock_swaps = 50u+i;
        mock_underflows = 8u;
        mock_missed = 9u;
        g_rendered_sprites = i & 1u ? 80u : 96u;
        measure_frame(i*1000u/60u);
    }
    assert(g_debug_status.measurement_state == 2u);
    assert(g_debug_status.measurement_elapsed_ms == 60000u);
    assert(g_debug_status.measurement_frames == 3600u && g_debug_status.measurement_swaps == 3600u);
    assert(g_debug_status.measurement_min_fps_x100 == 6000u);
    assert(g_debug_status.measurement_min_sprites == 80u && g_debug_status.measurement_max_sprites == 96u);
    assert(!g_debug_status.measurement_underflows && !g_debug_status.measurement_missed);
    publish_status();
    assert(g_debug_status.raw_swaps == 3650u && g_debug_status.raw_underflows == 8u);
    assert(g_debug_status.raw_missed == 9u);
    assert(!(g_debug_status.publication & 1u));
}

int main(void) {
    both_display_buffers_start_with_the_same_fullscreen_background();
    control_commands_run_once_and_preserve_configuration();
    owned_hardware_and_measurement_reject_transitions();
    measurement_uses_completed_frames_and_keeps_raw_counters();
    return 0;
}
