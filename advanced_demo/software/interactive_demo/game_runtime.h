#ifndef GAME_RUNTIME_H
#define GAME_RUNTIME_H
#include <stdint.h>
#define GAME_RUNTIME_MAGIC UINT32_C(0x47525431)
#define GAME_FRAME_BUDGET_US 16667u
#define GAME_RUNTIME_DIAG_HW_COUNTERS (1u << 0)
#define GAME_RUNTIME_DIAG_SUBMIT_TIMING (1u << 1)
#define GAME_BUILD_CONFIG_MAGIC UINT32_C(0x47424331)
typedef struct {
    uint32_t magic, version, fullscreen, view_x, view_y, view_width, view_height;
    uint32_t pixel_scale, flash_enabled, team_sprites, path_diagnostics, submit_timing;
    uint32_t require_queue, enemy_limit, enemy_bullet_limit, output_width, output_height;
} game_build_config_t;
extern const volatile game_build_config_t g_game_build_config;
/* Separate commit word: runtime.publication also covers the live frame, which
 * can be odd after the saved interval has already completed. */
extern volatile uint32_t g_game_measurement_complete;
/* Optional extension: the existing control/status ABI remains compatible. */
typedef struct {
    uint32_t magic, publication, campaign_stage, campaign_result, boss_hp;
    uint32_t render_us, frame_us, max_render_us, max_frame_us, over_budget_frames;
    uint32_t measurement_max_render_us, measurement_max_frame_us, measurement_over_budget_frames;
    uint32_t background_pixels, background_rectangles, sprite_pixels, glyph_blits;
    uint32_t stress_mode;
    uint32_t measurement_display_frames, measurement_repeated_frames;
    uint32_t measurement_writer_throttle_cycles_lo, measurement_writer_throttle_cycles_hi;
    uint32_t measurement_writer_bursts;
    uint32_t measurement_reader_ar_stall_cycles_lo, measurement_reader_ar_stall_cycles_hi;
    uint32_t measurement_reader_r_stall_cycles_lo, measurement_reader_r_stall_cycles_hi;
    uint32_t measurement_commands;
    uint32_t command_submit_us, command_wait_us;
    uint32_t measurement_command_submit_us, measurement_command_wait_us;
    uint32_t measurement_path_diagnostics;
} game_runtime_t;
extern volatile game_runtime_t g_game_runtime;
#endif
