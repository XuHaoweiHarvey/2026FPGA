#ifndef GAME_DEBUG_ABI_H
#define GAME_DEBUG_ABI_H

#include <stdint.h>

#define GAME_DEBUG_CONTROL_MAGIC UINT32_C(0x47444331)
#define GAME_DEBUG_STATUS_MAGIC UINT32_C(0x47445331)
#define GAME_DEBUG_ABI_VERSION 1u

enum {
    GAME_DEBUG_CMD_NONE = 0u,
    GAME_DEBUG_CMD_RESTART = 1u,
    GAME_DEBUG_CMD_PAUSE = 2u,
    GAME_DEBUG_CMD_RESUME = 3u,
    GAME_DEBUG_CMD_APPLY_OPTIONS = 4u,
    GAME_DEBUG_CMD_SELF_TEST = 5u,
    GAME_DEBUG_CMD_ENTER_GAME = 6u,
    GAME_DEBUG_CMD_MEASURE_60S = 7u,
    GAME_DEBUG_CMD_STRESS = 8u,
    GAME_DEBUG_CMD_STRESS_LOAD = 9u
};

enum {
    GAME_DEBUG_PHASE_STARTUP = 1u,
    GAME_DEBUG_PHASE_ASSETS = 2u,
    GAME_DEBUG_PHASE_SPRITES = 3u,
    GAME_DEBUG_PHASE_PLAYING = 4u,
    GAME_DEBUG_PHASE_PAUSED = 5u,
    GAME_DEBUG_PHASE_GAME_OVER = 6u,
    GAME_DEBUG_PHASE_TESTING = 7u,
    GAME_DEBUG_PHASE_TEST_RESULT = 8u,
    GAME_DEBUG_PHASE_FAULT = 255u
};

typedef struct {
    uint32_t magic;
    uint32_t sequence;
    uint32_t command;
    uint32_t auto_restart_ms;       /* 0 disables; otherwise 1..60000 */
    uint32_t enemy_fire_interval_ms;/* clamped by firmware to 150..10000 */
    uint32_t enemy_limit;           /* clamped to 1..48 */
    uint32_t flags;                 /* bit 0: invincible mode */
    uint32_t projectile_alpha;      /* 0..255 */
} game_debug_control_t;

typedef struct {
    uint32_t magic, version, acknowledged_sequence, phase, error;
    uint32_t frame, score, lives, active_sprites, max_active_sprites, fps_x100;
    uint32_t command_delta, swap_delta, underflow_delta, missed_delta;
    uint32_t uart_accepted, uart_bad_crc, buttons, player_x, player_y;
    uint32_t auto_restart_ms, enemy_fire_interval_ms, enemy_limit, invincible_mode;
    uint32_t dropped_ms, hardware_error, reader_error, cpu_ddr_error, cpu_ddr_status;
    uint32_t sprite_status, asset_status, self_test_result;
    uint32_t command_result, publication;
    uint32_t measurement_state, measurement_elapsed_ms, measurement_frames;
    uint32_t measurement_swaps, measurement_min_fps_x100;
    uint32_t measurement_min_sprites, measurement_max_sprites;
    uint32_t measurement_underflows, measurement_missed;
    uint32_t raw_commands, raw_swaps, raw_underflows, raw_missed;
    uint32_t buffer_status, front_base, back_base, wave;
    uint32_t uart_bad_version, uart_bad_flags, uart_stale, uart_timeout_releases;
} game_debug_status_t;

extern volatile game_debug_control_t g_debug_control;
extern volatile game_debug_status_t g_debug_status;
extern volatile game_debug_status_t g_debug_first_fault;

#endif
