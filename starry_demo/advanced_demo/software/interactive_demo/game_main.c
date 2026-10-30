/* High-load keyboard survival game for the v7 queued Alpha/Color Key engine. */
#include <stdint.h>
#if defined(SURVIVAL_GAME_HOST_SYNTAX)
#include "../../sim/mock_game/accel_api.h"
#else
#include "../apb_reg_test/accel_api.h"
#endif
#include "../apb_reg_test/benchmark_clock.h"
#include "../m1b_compare/hud.h"
#include "game_logic.h"
#include "game_debug_abi.h"
#include "game_runtime.h"
#include "game_presentation.h"
#include "game_stress_tuning.h"
#include "uart_keyboard_input.h"
#ifndef GAME_FLASH_ENABLE
#define GAME_FLASH_ENABLE 1
#endif
#ifndef GAME_PATH_DIAGNOSTICS
#if GAME_FLASH_ENABLE
#define GAME_PATH_DIAGNOSTICS 0
#else
#define GAME_PATH_DIAGNOSTICS 1
#endif
#endif
#ifndef GAME_SUBMIT_TIMING
/* Per-command CLINT profiling changes the hot path; enable only for diagnosis. */
#define GAME_SUBMIT_TIMING 0
#endif
#ifndef GAME_TEAM_SPRITES
#define GAME_TEAM_SPRITES 1
#endif
#ifndef GAME_TEAM_BACKGROUND
/* Keep art selection independent from the size of the playable viewport. */
#define GAME_TEAM_BACKGROUND GAME_FULLSCREEN
#endif
#ifndef GAME_DISPLAY_WINDOW
#define GAME_DISPLAY_WINDOW 0
#endif
#ifndef GAME_WINDOW_HUD_CACHE
/* Opt in only in the separate window optimization ELF. */
#define GAME_WINDOW_HUD_CACHE 0
#endif
#if GAME_WINDOW_HUD_CACHE && (!GAME_DISPLAY_WINDOW || !GAME_TEAM_SPRITES)
#error "Window HUD cache requires the v8 window and hardware sprite/font configuration"
#endif
#if GAME_DISPLAY_WINDOW && (GAME_FULLSCREEN || !GAME_TEAM_BACKGROUND)
#error "Window scan requires the centered supplied-background configuration"
#endif
#if GAME_FULLSCREEN && !GAME_TEAM_BACKGROUND
#error "Fullscreen requires the supplied island background"
#endif
#ifndef GAME_REQUIRE_QUEUE
#define GAME_REQUIRE_QUEUE GAME_FULLSCREEN
#endif
#if GAME_FULLSCREEN && !GAME_TEAM_SPRITES
#error "Fullscreen uses the team sprites; set GAME_FULLSCREEN=0 for legacy art"
#endif
#if GAME_TEAM_SPRITES
#include "game_sprite_assets.h"
#include "game_hud_atlas.h"
#if GAME_EFFECT_LIFETIME_MS != GAME_TEAM_EXPLOSION_DURATION_MS
#error "Explosion animation and game effect lifetimes must match"
#endif
#endif
#if GAME_TEAM_BACKGROUND
#include "game_background_asset.h"
#endif
#if GAME_FULLSCREEN
#include "game_background_dirty.h"
#endif
#if GAME_FLASH_ENABLE
#include "../flash/game_flash.h"
#endif

#if defined(__GNUC__) && !defined(SURVIVAL_GAME_HOST_SYNTAX)
#define GAME_NORETURN __attribute__((noinline, noreturn))
#define GAME_NOINLINE __attribute__((noinline))
#define GAME_SETUP __attribute__((noinline, optimize("Os")))
#define GAME_FENCE() __asm__ volatile("fence iorw,iorw" ::: "memory")
#define GAME_DISABLE_INTERRUPTS() __asm__ volatile("csrci mstatus,8" ::: "memory")
#define GAME_IDLE() __asm__ volatile("nop" ::: "memory")
#else
#define GAME_NORETURN
#define GAME_NOINLINE
#define GAME_SETUP
#define GAME_FENCE() ((void)0)
#define GAME_DISABLE_INTERRUPTS() ((void)0)
#define GAME_IDLE() ((void)0)
#endif

#if !defined(SYSTEM_DDR_BMB) || SYSTEM_DDR_BMB != 0x1000
#error "The game requires the verified uncached DDR alias"
#endif

#if GAME_FULLSCREEN
#define VIEW_X 0u
#define VIEW_Y 0u
static game_background_dirty_t g_background_dirty[2];
static game_background_dirty_t *g_current_dirty;
#else
#define VIEW_X 640u
#define VIEW_Y 300u
#endif
#if GAME_TEAM_BACKGROUND
#define FULL_BACKGROUND_PHYS UINT32_C(0x02000000)
#endif
#if GAME_TEAM_BACKGROUND || GAME_REQUIRE_QUEUE
/* Retained symbol lets the desktop loader check the ELF's exact requirements. */
const volatile uint32_t g_game_required_caps =
    (GAME_TEAM_BACKGROUND ? ACCEL_CAP_FULLSCREEN_BACKGROUND : 0u) |
    (GAME_REQUIRE_QUEUE ? ACCEL_CAP_COMMAND_QUEUE : 0u) |
    (GAME_DISPLAY_WINDOW ? ACCEL_CAP_DISPLAY_WINDOW : 0u);
#endif
#define VIEW_W GAME_WORLD_WIDTH
#define VIEW_H GAME_WORLD_HEIGHT
const volatile game_build_config_t g_game_build_config = {
    GAME_BUILD_CONFIG_MAGIC, 1u, GAME_FULLSCREEN, VIEW_X, VIEW_Y, VIEW_W, VIEW_H,
    GAME_PIXEL_SCALE, GAME_FLASH_ENABLE, GAME_TEAM_SPRITES,
    GAME_PATH_DIAGNOSTICS, GAME_SUBMIT_TIMING, GAME_REQUIRE_QUEUE,
    GAME_ENEMY_LIMIT,
#if GAME_STRESS_TUNING
    GAME_ENEMY_BULLET_CAPACITY,
#else
    GAME_ENEMY_BULLET_LIMIT,
#endif
    1920u, 1080u
};
volatile uint32_t g_game_measurement_complete;
#if GAME_ALLOW_SCALE2
const volatile uint32_t g_game_scale2_compatible = UINT32_C(0x4000);
volatile game_presentation_t g_game_presentation;
static uint32_t g_presentation_measure_started;
#endif
#if GAME_SHOWCASE
const volatile uint32_t g_game_showcase_available = 1u;
#endif
#if GAME_WINDOW_HUD_CACHE
/* Optional retained build marker; existing status/config layouts stay intact. */
const volatile uint32_t g_game_window_hud_cache = GAME_WINDOW_HUD_CACHE;
/* Old window ELFs reject v9/v10 in accel_init; let the loader detect that. */
const volatile uint32_t g_game_alpha_hardware_compatible = UINT32_C(0x3000);
static uint32_t g_window_background_valid;
#endif
#if GAME_STRESS_TUNING
const volatile game_stress_limits_t g_game_stress_limits = {
    GAME_STRESS_MAGIC, 1u, GAME_ENEMY_LIMIT, GAME_ENEMY_BULLET_CAPACITY
};
volatile game_stress_request_t g_game_stress_request;
volatile game_stress_status_t g_game_stress_status;
#endif
#define SPRITE_PHYS UINT32_C(0x01384000)
#define SPRITE_STRIDE 2560u
#define SPRITE_PIXELS (640u * 480u)
#define ASSET_BASE UINT32_C(0x01000000)
#define ASSET_BYTES UINT32_C(0x0012c000)
#define ASSET_COUNT 3u
#define COLOR_KEY UINT32_C(0x00ff00ff)
#define BACKGROUND UINT32_C(0x0007101c)
#define PANEL UINT32_C(0x00101f30)
#define ERROR_SESSION UINT32_C(0xea01)
#define ERROR_ASSET UINT32_C(0xea02)
#define ERROR_SPRITE UINT32_C(0xea03)
#define ERROR_RENDER UINT32_C(0xea04)
#define ERROR_HEALTH UINT32_C(0xea05)

enum { PHASE_STARTUP = 1u, PHASE_ASSETS = 2u, PHASE_SPRITES = 3u,
       PHASE_PLAYING = 4u, PHASE_FAILED = 255u };

typedef struct {
    uint32_t magic, phase, error, frame, score, lives;
    uint32_t active_sprites, max_active_sprites, fps_x100;
    uint32_t command_delta, swap_delta, underflow_delta, missed_delta;
    uint32_t uart_accepted, uart_bad_crc, uart_bad_version, uart_bad_flags;
    uint32_t uart_stale, uart_timeout_releases;
    uint32_t buttons, player_x, player_y, sprite_status, asset_status;
} game_result_t;

volatile game_result_t g_game_result;
volatile game_debug_control_t g_debug_control;
volatile game_debug_status_t g_debug_status;
volatile game_debug_status_t g_debug_first_fault;
volatile game_runtime_t g_game_runtime;
static survival_game_t g_game;
static uart_keyboard_input_t g_keyboard;
static uint32_t g_underflow_base, g_missed_base, g_command_base, g_swap_base;
static uint32_t g_now_ms;
static uint32_t g_fps_window_ms, g_fps_window_frames;
static uint32_t g_projectile_alpha = 225u;
static uint32_t g_test_page;
static uint32_t g_rendered_sprites;
static uint32_t g_measure_start, g_measure_swap_base, g_measure_underflow_base, g_measure_missed_base;
static uint32_t g_measure_window_ms, g_measure_window_frames;
static uint32_t g_measure_boundary_base;
#if GAME_PATH_DIAGNOSTICS
static uint32_t g_measure_diag_sample_ms;
static uint32_t g_measure_writer_throttle_last, g_measure_writer_bursts_last;
static uint32_t g_measure_reader_ar_stall_last, g_measure_reader_r_stall_last;
static uint32_t g_measure_commands_last;
static uint64_t g_measure_writer_throttle_total, g_measure_reader_ar_stall_total;
static uint64_t g_measure_reader_r_stall_total;
static uint32_t g_measure_writer_bursts_total, g_measure_commands_total;
#endif
static uint64_t g_last_present_ticks;
static uint32_t g_scene_mode = UINT32_MAX;
#if GAME_TEAM_SPRITES
typedef struct {
    char lines[3][64];
    uint32_t refreshed_ms, boss_hp, overlay;
    uint8_t valid;
#if GAME_WINDOW_HUD_CACHE
    uint8_t paused;
#endif
} game_hud_cache_t;
static game_hud_cache_t g_hud_cache[2];
#if GAME_WINDOW_HUD_CACHE
/* One sampling clock for both physical buffers; each retains its pixel cache. */
static struct {
    char line[64];
    uint32_t refreshed_ms, mode;
    uint8_t valid;
} g_hud_metrics;
#endif
#endif

static void poll_keyboard(void);

static void publish_status(void) {
    ++g_debug_status.publication;
    GAME_FENCE();
    g_debug_status.magic = GAME_DEBUG_STATUS_MAGIC;
    g_debug_status.version = GAME_DEBUG_ABI_VERSION;
    g_debug_status.phase = g_game_result.phase;
    g_debug_status.error = g_game_result.error;
    g_debug_status.frame = g_game_result.frame;
    g_debug_status.score = g_game_result.score;
    g_debug_status.lives = g_game_result.lives;
    g_debug_status.active_sprites = g_game_result.active_sprites;
    g_debug_status.max_active_sprites = g_game_result.max_active_sprites;
    g_debug_status.fps_x100 = g_game_result.fps_x100;
    g_debug_status.command_delta = g_game_result.command_delta;
    g_debug_status.swap_delta = g_game_result.swap_delta;
    g_debug_status.underflow_delta = g_game_result.underflow_delta;
    g_debug_status.missed_delta = g_game_result.missed_delta;
    g_debug_status.uart_accepted = g_game_result.uart_accepted;
    g_debug_status.uart_bad_crc = g_game_result.uart_bad_crc;
    g_debug_status.buttons = g_game_result.buttons;
    g_debug_status.player_x = g_game_result.player_x;
    g_debug_status.player_y = g_game_result.player_y;
    g_debug_status.auto_restart_ms = g_game.auto_restart_ms;
    g_debug_status.enemy_fire_interval_ms = g_game.enemy_fire_interval_ms;
    g_debug_status.enemy_limit = g_game.enemy_limit;
#if GAME_STRESS_TUNING
    g_game_stress_status.magic = GAME_STRESS_MAGIC;
    g_game_stress_status.version = 1u;
    g_game_stress_status.enemies = g_game.enemy_limit;
    g_game_stress_status.enemy_bullets = survival_game_enemy_bullet_limit(&g_game);
#endif
    g_debug_status.invincible_mode = g_game.invincible_mode;
    g_debug_status.dropped_ms = g_game.dropped_ms;
    g_debug_status.hardware_error = accel_error();
    g_debug_status.reader_error = accel_read(ACCEL_READER_ERROR);
    g_debug_status.cpu_ddr_error = accel_read(ACCEL_CPU_DDR_ERROR);
    g_debug_status.cpu_ddr_status = accel_read(ACCEL_CPU_DDR_STATUS);
    g_debug_status.sprite_status = accel_read(ACCEL_SPRITE_STATUS);
    g_debug_status.asset_status = accel_read(ACCEL_ASSET_STATUS);
    g_debug_status.raw_commands = accel_read(ACCEL_COMMAND_COUNT);
    g_debug_status.raw_swaps = accel_read(ACCEL_SWAP_COUNT);
    g_debug_status.raw_underflows = accel_read(ACCEL_DISPLAY_UNDERFLOW_COUNT);
    g_debug_status.raw_missed = accel_read(ACCEL_MISSED_BOUNDARY_COUNT);
    g_debug_status.buffer_status = accel_read(ACCEL_BUFFER_STATUS);
    g_debug_status.front_base = display_get_front_buffer();
    g_debug_status.back_base = display_get_back_buffer();
    g_debug_status.wave = g_game.wave;
    g_debug_status.uart_bad_version = g_game_result.uart_bad_version;
    g_debug_status.uart_bad_flags = g_game_result.uart_bad_flags;
    g_debug_status.uart_stale = g_game_result.uart_stale;
    g_debug_status.uart_timeout_releases = g_game_result.uart_timeout_releases;
    GAME_FENCE();
    ++g_debug_status.publication;
}

static uint32_t read32(uintptr_t address) {
#if defined(SURVIVAL_GAME_HOST_SYNTAX) && defined(MOCK_GAME_MMIO_READ)
    return MOCK_GAME_MMIO_READ(address);
#else
    return *(volatile uint32_t *)address;
#endif
}

static uint64_t ticks(void) {
    uint64_t value;
    GAME_FENCE();
    value = benchmark_clock_read(read32);
    GAME_FENCE();
    return value;
}

static uint32_t milliseconds(void) {
    return (uint32_t)(ticks() / (SYSTEM_CLINT_HZ / 1000u));
}

static volatile uint32_t *ddr(uint32_t physical) {
    return (volatile uint32_t *)(uintptr_t)(SYSTEM_DDR_BMB + physical);
}

GAME_NORETURN void game_demo_done(void) {
    uint32_t last_publish = 0u;
    /* A fault remains inspectable; commands are acknowledged as rejected.
       Never clear sticky hardware errors or restart a possibly owned buffer. */
    for (;;) {
        poll_keyboard();
        if (g_debug_control.magic == GAME_DEBUG_CONTROL_MAGIC &&
            g_debug_control.sequence != g_debug_status.acknowledged_sequence) {
            g_debug_status.command_result = UINT32_C(0xed01);
            g_debug_status.acknowledged_sequence = g_debug_control.sequence;
        }
        if ((uint32_t)(g_now_ms - last_publish) >= 100u) {
            publish_status();
            last_publish = g_now_ms;
        }
        GAME_IDLE();
    }
}

static void fail(uint32_t error) {
    g_game_result.error = error;
    g_game_result.phase = PHASE_FAILED;
    g_game_result.sprite_status = accel_read(ACCEL_SPRITE_STATUS);
    g_game_result.asset_status = accel_read(ACCEL_ASSET_STATUS);
    g_game_result.underflow_delta = accel_read(ACCEL_DISPLAY_UNDERFLOW_COUNT) - g_underflow_base;
    g_game_result.missed_delta = accel_read(ACCEL_MISSED_BOUNDARY_COUNT) - g_missed_base;
    publish_status();
    if (!g_debug_first_fault.magic) g_debug_first_fault = g_debug_status;
    game_demo_done();
}

static void require(uint32_t error) {
    if (error) fail(error);
}

static void check_health(void) {
    uint32_t underflow = accel_read(ACCEL_DISPLAY_UNDERFLOW_COUNT) - g_underflow_base;
    uint32_t missed = accel_read(ACCEL_MISSED_BOUNDARY_COUNT) - g_missed_base;
    g_game_result.underflow_delta = underflow;
    g_game_result.missed_delta = missed;
    if (accel_error() || accel_read(ACCEL_READER_ERROR) ||
        accel_read(ACCEL_CPU_DDR_ERROR) || (accel_read(ACCEL_CPU_DDR_STATUS) & 7u) ||
        underflow || missed)
        fail(ERROR_HEALTH);
}

static void cpu_session_begin(void) {
    uint32_t i, status = accel_read(ACCEL_CPU_DDR_STATUS);
    if ((status & 7u) || accel_read(ACCEL_CPU_DDR_ERROR)) fail(ERROR_SESSION);
    accel_write(ACCEL_CPU_DDR_CONTROL, 1u);
    for (i = 0; i < ACCEL_POLL_LIMIT; ++i) {
        status = accel_read(ACCEL_CPU_DDR_STATUS);
        if (status & 4u) fail(ERROR_SESSION);
        if (status & 1u) return;
    }
    fail(ERROR_SESSION);
}

static void cpu_session_end(void) {
    uint32_t i, status;
    GAME_FENCE();
    for (i = 0; i < ACCEL_POLL_LIMIT; ++i) {
        status = accel_read(ACCEL_CPU_DDR_STATUS);
        if (!(status & 2u)) break;
    }
    if (i == ACCEL_POLL_LIMIT || accel_read(ACCEL_CPU_DDR_ERROR) || (status & 4u))
        fail(ERROR_SESSION);
    accel_write(ACCEL_CPU_DDR_CONTROL, 2u);
    for (i = 0; i < ACCEL_POLL_LIMIT; ++i)
        if (!(accel_read(ACCEL_CPU_DDR_STATUS) & 1u)) return;
    fail(ERROR_SESSION);
}

#if GAME_TEAM_BACKGROUND || !GAME_FLASH_ENABLE
static uint32_t asset_pixel(uint32_t image, uint32_t x, uint32_t y) {
    uint32_t r, g, b, band;
    if (image == 0u) {
        r = (x + (y >> 1)) & 255u; g = (y + (x >> 2)) & 255u;
        b = (((x + y) >> 5) & 1u) ? 0xe0u : 0x28u;
    } else if (image == 1u) {
        band = ((x >> 5) ^ (y >> 5)) & 1u; r = band ? 0xf0u : 0x20u;
        g = ((x >> 2) ^ (y >> 1)) & 255u; b = band ? 0x30u : 0xe8u;
    } else {
        band = ((x + (y << 1)) >> 4) & 7u; r = band * 29u + 28u;
        g = ((x ^ y) >> 1) & 255u; b = 255u - (((y * 3u + x) >> 3) & 255u);
    }
    return (r << 16) | (g << 8) | b;
}

static uint32_t asset_hash(uint32_t image, int write_pixels) {
    uint32_t x, y, pixel, hash = UINT32_C(2166136261);
    volatile uint32_t *base = ddr(ASSET_BASE + image * ASSET_BYTES);
    for (y = 0; y < 480u; ++y) {
        if (!(y & 31u)) poll_keyboard();
        for (x = 0; x < 640u; ++x) {
            pixel = write_pixels ? asset_pixel(image, x, y) : base[y * 640u + x];
            if (write_pixels) base[y * 640u + x] = pixel;
            else if (pixel != asset_pixel(image, x, y)) fail(ERROR_ASSET);
            hash = (hash ^ pixel) * UINT32_C(16777619);
        }
    }
    return hash;
}

#if GAME_TEAM_BACKGROUND
static uint32_t display_background_pixel(uint32_t x, uint32_t y) {
#if GAME_SHOWCASE && GAME_DISPLAY_WINDOW
    /* Fit the supplied island into the showcase viewport at upload time.
       The sealed DDR address/stride and every per-frame BLIT stay unchanged. */
    if (x >= VIEW_X && x < VIEW_X + VIEW_W && y >= VIEW_Y && y < VIEW_Y + VIEW_H)
        return game_background_pixel((x - VIEW_X) * 3u, (y - VIEW_Y) * 9u / 4u);
#endif
    return game_background_pixel(x, y);
}

static void fullscreen_background_assets(int write_pixels) {
    uint32_t x, y;
    volatile uint32_t *dst = ddr(FULL_BACKGROUND_PHYS);
    for (y = 0u; y < 1080u; ++y) {
        if (!(y & 31u)) poll_keyboard();
        for (x = 0u; x < 1920u; ++x) {
            uint32_t pixel = display_background_pixel(x, y);
            if (write_pixels) dst[y * 1920u + x] = pixel;
            else if (dst[y * 1920u + x] != pixel) fail(ERROR_ASSET);
        }
    }
}
#endif

static GAME_SETUP void initialize_assets(void) {
    uint32_t i, status = accel_read(ACCEL_ASSET_STATUS);
    g_game_result.phase = PHASE_ASSETS;
    publish_status();
    if (!(status & UINT32_C(0x80000000))) fail(ERROR_ASSET);
    if (!(status & 2u)) {
        if (!(status & 1u)) {
            accel_write(ACCEL_ASSET_CONTROL, 1u);
            if (!(accel_read(ACCEL_ASSET_STATUS) & 1u)) fail(ERROR_ASSET);
        }
        cpu_session_begin();
        for (i = 0; i < ASSET_COUNT; ++i) (void)asset_hash(i, 1);
#if GAME_TEAM_BACKGROUND
        fullscreen_background_assets(1);
#endif
        GAME_FENCE();
        for (i = 0; i < ASSET_COUNT; ++i) (void)asset_hash(i, 0);
#if GAME_TEAM_BACKGROUND
        fullscreen_background_assets(0);
#endif
        cpu_session_end();
        accel_write(ACCEL_ASSET_CONTROL, 2u);
        if (!(accel_read(ACCEL_ASSET_STATUS) & 2u)) fail(ERROR_ASSET);
    } else {
        cpu_session_begin();
        for (i = 0; i < ASSET_COUNT; ++i) (void)asset_hash(i, 0);
#if GAME_TEAM_BACKGROUND
        fullscreen_background_assets(0);
#endif
        cpu_session_end();
    }
    g_game_result.asset_status = accel_read(ACCEL_ASSET_STATUS);
}
#endif

#if GAME_TEAM_SPRITES
static uint32_t team_atlas_pixel(uint32_t x, uint32_t y) {
    if (x < 64u && y < 64u) {
        int32_t dx = (int32_t)x - 31, dy = (int32_t)y - 31;
        uint32_t dist2 = (uint32_t)(dx * dx + dy * dy);
        uint32_t alpha = dist2 >= 1024u ? 0u : 24u + (1023u - dist2) * 220u / 1023u;
        return (alpha << 24) | UINT32_C(0x0048aaff);
    }
    return game_team_sprite_pixel(x, y);
}
static uint32_t atlas_pixel(uint32_t x, uint32_t y) {
#if GAME_SHOWCASE
    if (x >= 160u && x < 256u && y < 16u) {
        uint32_t frame = (x - 160u) / 16u;
        return team_atlas_pixel(frame * 32u + ((x - 160u) % 16u) * 2u, 64u + y * 2u);
    }
    if (x >= 144u && x < 160u && y < 16u) {
        int32_t dx = (int32_t)x - 151, dy = (int32_t)y - 7;
        uint32_t d2 = (uint32_t)(dx * dx + dy * dy);
        uint32_t a = d2 >= 49u ? 0u : 255u - d2 * 4u;
        return (a << 24) | (d2 < 6u ? 0x00fff1d0u : 0x00ff6038u);
    }
#endif
    if (y >= GAME_FONT_Y && y < GAME_FONT_Y + 72u) return game_font_pixel(x, y);
    if (y >= 320u && y < 320u + GAME_BOSS_SIZE && x < GAME_BOSS_SIZE)
        return team_atlas_pixel(96u + x / (2u * GAME_PIXEL_SCALE), (y - 320u) / (2u * GAME_PIXEL_SCALE));
#if GAME_FULLSCREEN
    if (y < 128u && x < 128u) return team_atlas_pixel(x / 2u, y / 2u);
    if (y < 64u && x >= 128u && x < 320u) return team_atlas_pixel(x / 2u, y / 2u);
    if (y >= 128u && y < 192u && x < 384u)
        return team_atlas_pixel(x / 2u, 64u + (y - 128u) / 2u);
    return COLOR_KEY;
#else
    return team_atlas_pixel(x, y);
#endif
}
#elif !GAME_FLASH_ENABLE
static uint32_t atlas_pixel(uint32_t x, uint32_t y) {
    int32_t dx, dy;
    uint32_t dist2, alpha;
    if (x < 64u && y < 64u) {
        dx = (int32_t)x - 31; dy = (int32_t)y - 31;
        dist2 = (uint32_t)(dx * dx + dy * dy);
        alpha = dist2 >= 1024u ? 0u : 24u + (1023u - dist2) * 220u / 1023u;
        return (alpha << 24) | UINT32_C(0x00ff7430);
    }
    if (x >= 128u && x < 144u && y < 16u) {
        dx = (int32_t)x - 136; dy = (int32_t)y - 8;
        dist2 = (uint32_t)(dx * dx + dy * dy);
        alpha = dist2 > 64u ? 0u : 80u + (64u - dist2) * 160u / 64u;
        return (alpha << 24) | UINT32_C(0x0030e8ff);
    }
    if (x >= 64u && x < 96u && y < 32u) {
        uint32_t sx = x - 64u, sy = y;
        uint32_t body = sy >= 4u && sy <= 28u && sx >= (sy < 12u ? 12u : 5u + sy / 5u) &&
                        sx < (sy < 12u ? 20u : 27u - sy / 5u);
        uint32_t wing = sy >= 16u && sy <= 25u && (sx < 7u || sx >= 25u);
        if (body || wing) {
            if (sy >= 8u && sy <= 15u && sx >= 13u && sx <= 18u)
                return UINT32_C(0x0000eaff);
            return sy < 16u ? UINT32_C(0x00f4f8ff) : UINT32_C(0x0027aaff);
        }
        return COLOR_KEY;
    }
    if (x >= 96u && x < 128u && y < 32u) {
        uint32_t sx = x - 96u, sy = y;
        dx = (int32_t)sx - 16; dy = (int32_t)sy - 15;
        if ((uint32_t)(dx * dx + dy * dy) < 190u &&
            !(sy < 8u && (sx < 11u || sx > 20u)))
            return ((sx / 4u + sy / 4u) & 1u) ? UINT32_C(0x00ffb020) : UINT32_C(0x00e84050);
        if (sy >= 10u && sy <= 13u && (sx == 8u || sx == 23u))
            return UINT32_C(0x00ffffff);
        return COLOR_KEY;
    }
    return COLOR_KEY;
}
#else
static uint32_t atlas_pixel(uint32_t x, uint32_t y) {
    /* Self-test uses the verified Flash atlas inside a CPU DDR session. */
    return ddr(SPRITE_PHYS)[y * 640u + x];
}
#endif

#if GAME_TEAM_SPRITES || !GAME_FLASH_ENABLE
static GAME_SETUP void initialize_sprite_atlas(void) {
    uint32_t x, y, pixel, hash = UINT32_C(2166136261);
    volatile uint32_t *dst = ddr(SPRITE_PHYS);
    uint32_t status = accel_read(ACCEL_SPRITE_STATUS);
    g_game_result.phase = PHASE_SPRITES;
    publish_status();
    if (!(status & UINT32_C(0x80000000))) fail(ERROR_SPRITE);
    if (!(status & 2u)) {
        require(accel_sprite_begin());
        cpu_session_begin();
        for (y = 0; y < 480u; ++y) {
            if (!(y & 31u)) poll_keyboard();
            for (x = 0; x < 640u; ++x) {
                pixel = atlas_pixel(x, y);
                dst[y * 640u + x] = pixel;
                hash = (hash ^ pixel) * UINT32_C(16777619);
            }
        }
        GAME_FENCE();
        for (y = 0; y < 480u; ++y) {
            if (!(y & 31u)) poll_keyboard();
            for (x = 0; x < 640u; ++x)
                if (dst[y * 640u + x] != atlas_pixel(x, y)) fail(ERROR_SPRITE);
        }
        cpu_session_end();
        require(accel_sprite_seal());
    } else {
        cpu_session_begin();
        for (y = 0; y < 480u; ++y) {
            if (!(y & 31u)) poll_keyboard();
            for (x = 0; x < 640u; ++x) {
                pixel = dst[y * 640u + x];
                if (pixel != atlas_pixel(x, y)) fail(ERROR_SPRITE);
                hash = (hash ^ pixel) * UINT32_C(16777619);
            }
        }
        cpu_session_end();
    }
    (void)hash;
    g_game_result.sprite_status = accel_read(ACCEL_SPRITE_STATUS);
}
#endif

#if GAME_FLASH_ENABLE && !GAME_TEAM_BACKGROUND
/* Flash is a storage device; rendering always reads the existing guarded DDR.
 * Verify both the incoming bytes and the DDR readback before sealing windows. */
static uint32_t flash_line[640];
static void flash_load_window(uint32_t index, uint32_t physical, int write_pixels) {
    uint32_t y,x,crc=0,readback=0;
    uint8_t bytes[4];
    volatile uint32_t *dst=ddr(physical);
    cpu_session_begin();
    for(y=0;y<480;y++) {
        int rc=game_flash_row(index,y,flash_line);
        if (!(y & 31u)) poll_keyboard();
        if(rc) fail(ERROR_ASSET);
        crc=flash_crc32(crc,flash_line,sizeof(flash_line));
        for(x=0;x<640;x++) {
            if(write_pixels) dst[y*640+x]=flash_line[x];
            else if(dst[y*640+x]!=flash_line[x]) fail(ERROR_ASSET);
        }
    }
    GAME_FENCE();
    for(y=0;y<480;y++) {
        if (!(y & 31u)) poll_keyboard();
        for(x=0;x<640;x++) {
            flash_put32(bytes,dst[y*640+x]);
            readback=flash_crc32(readback,bytes,4);
        }
    }
    cpu_session_end();
    g_flash_result.asset_crc=crc;
    if(crc!=game_flash_expected_crc(index) || readback!=crc) {
        g_flash_result.error=FLASH_CRC;fail(ERROR_ASSET);
    }
}
static GAME_SETUP void initialize_assets(void) {
    uint32_t i,status=accel_read(ACCEL_ASSET_STATUS);
    int write_pixels=!(status&2u);
    g_game_result.phase=PHASE_ASSETS;
    publish_status();
    if(!(status&0x80000000u))fail(ERROR_ASSET);
    if(write_pixels && !(status&1u)) {
        accel_write(ACCEL_ASSET_CONTROL,1u);
        if(!(accel_read(ACCEL_ASSET_STATUS)&1u))fail(ERROR_ASSET);
    }
    for(i=0;i<3;i++)flash_load_window(i,ASSET_BASE+i*ASSET_BYTES,write_pixels);
    if(write_pixels)accel_write(ACCEL_ASSET_CONTROL,2u);
    if(!(accel_read(ACCEL_ASSET_STATUS)&2u))fail(ERROR_ASSET);
    g_game_result.asset_status=accel_read(ACCEL_ASSET_STATUS);
}
#if !GAME_TEAM_SPRITES
static GAME_SETUP void initialize_sprite_atlas(void) {
    uint32_t status=accel_read(ACCEL_SPRITE_STATUS);
    g_game_result.phase=PHASE_SPRITES;
    publish_status();
    if(!(status&0x80000000u))fail(ERROR_SPRITE);
    if(!(status&2u))require(accel_sprite_begin());
    flash_load_window(3,SPRITE_PHYS,!(status&2u));
    if(!(status&2u))require(accel_sprite_seal());
    g_game_result.sprite_status=accel_read(ACCEL_SPRITE_STATUS);
}
#endif
#endif

static void poll_keyboard(void) {
    g_now_ms = milliseconds();
    (void)uart_keyboard_input_poll(&g_keyboard, g_now_ms);
    g_game_result.uart_accepted = g_keyboard.parser.accepted_frames;
    g_game_result.uart_bad_crc = g_keyboard.parser.bad_crc_frames;
    g_game_result.uart_bad_version = g_keyboard.parser.bad_version_frames;
    g_game_result.uart_bad_flags = g_keyboard.parser.bad_flags_frames;
    g_game_result.uart_stale = g_keyboard.parser.stale_frames;
    g_game_result.uart_timeout_releases = g_keyboard.parser.timeout_releases;
    g_game_result.buttons = g_keyboard.parser.buttons;
}

/* Keep one MMIO wait/health path for every drawing command. */
#if GAME_SUBMIT_TIMING
static GAME_NOINLINE void issue_command_finish(uint32_t result, uint32_t measuring,
                                               uint64_t started) {
    uint64_t submitted = 0u;
    require(result);
    if (measuring) {
        submitted = ticks();
        uint32_t submit_us = (uint32_t)((submitted - started) / (SYSTEM_CLINT_HZ / 1000000u));
        g_game_runtime.command_submit_us += submit_us;
    }
}

/* Enable GAME_SUBMIT_TIMING only for a diagnostic build. */
#define issue_command(expression) do { \
    uint32_t _game_measure = g_debug_status.measurement_state == 1u; \
    uint64_t _game_started = _game_measure ? ticks() : 0u; \
    uint32_t _game_result = (expression); \
    issue_command_finish(_game_result, _game_measure, _game_started); \
} while (0)
#else
static GAME_NOINLINE void issue_command(uint32_t result) {
    require(result);
}
#endif

/* Queue-capable hardware drains the frame's descriptors here. On older v6
 * hardware each submit is already synchronous, so this returns immediately. */
static GAME_NOINLINE void finish_command_batch(void) {
#if GAME_PATH_DIAGNOSTICS
    uint32_t measuring = g_debug_status.measurement_state == 1u;
    uint64_t started = measuring ? ticks() : 0u;
    require(accel_command_batch_end());
    if (measuring)
        g_game_runtime.command_wait_us +=
            (uint32_t)((ticks() - started) / (SYSTEM_CLINT_HZ / 1000000u));
#else
    require(accel_command_batch_end());
#endif
}

static GAME_SETUP void initialize_display_background(void) {
    uint32_t i, ticket;
    /* TPG initializes only Front0. Clear each Back and present it so both
       double buffers start identical before assets and gameplay are ready. */
    for (i = 0; i < 2u; ++i) {
        require(accel_fill_rect(GAME_DISPLAY_WINDOW ? VIEW_X : 0u,
                               GAME_DISPLAY_WINDOW ? VIEW_Y : 0u,
                               GAME_DISPLAY_WINDOW ? VIEW_W : 1920u,
                               GAME_DISPLAY_WINDOW ? VIEW_H : 1080u, BACKGROUND));
        require(accel_wait_done());
        check_health();
        require(display_swap_request(&ticket));
        require(display_wait_swap_done(ticket));
        check_health();
    }
}

#if GAME_TEAM_BACKGROUND && !GAME_FULLSCREEN
static GAME_SETUP void initialize_centered_island_background(void) {
    uint32_t i, ticket;
    /* The sealed island is copied to each physical Back once. Only the
       viewport is restored during gameplay; the surrounding art stays still. */
    for (i = 0u; i < 2u; ++i) {
        require(accel_blit(FULL_BACKGROUND_PHYS +
                              (GAME_DISPLAY_WINDOW ? VIEW_Y*7680u+VIEW_X*4u : 0u),
                          7680u, GAME_DISPLAY_WINDOW ? VIEW_X : 0u,
                          GAME_DISPLAY_WINDOW ? VIEW_Y : 0u,
                          GAME_DISPLAY_WINDOW ? VIEW_W : 1920u,
                          GAME_DISPLAY_WINDOW ? VIEW_H : 1080u));
        require(accel_wait_done());
        check_health();
        require(display_swap_request(&ticket));
        require(display_wait_swap_done(ticket));
        check_health();
    }
}

static void restore_centered_island_background(uint32_t back) {
    uint32_t top = 0u;
#if GAME_WINDOW_HUD_CACHE
    uint32_t slot = back == 0u ? 0u : 1u;
    uint32_t bit = 1u << slot;
    if (g_window_background_valid & bit) top = GAME_WORLD_TOP;
    else {
        /* Recover all pixels after restart/self-test, including the gap
           between the HUD panel and gameplay; track each physical Back. */
        g_window_background_valid |= bit;
        g_hud_cache[slot].valid = 0u;
    }
#else
    (void)back;
#endif
    issue_command(accel_blit(FULL_BACKGROUND_PHYS + (VIEW_Y + top) * 7680u + VIEW_X * 4u,
                            7680u, VIEW_X, VIEW_Y + top, VIEW_W, VIEW_H - top));
    g_game_runtime.background_pixels += VIEW_W * (VIEW_H - top);
    ++g_game_runtime.background_rectangles;
}
#endif

#if GAME_FULLSCREEN
static void restore_game_background(uint32_t back) {
    uint32_t x, y, w, h, row, word, count = 0u;
    g_current_dirty = &g_background_dirty[back == 0u ? 0u : 1u];
    for (row = 0u; row < GAME_DIRTY_ROWS; ++row) for (word = 0u; word < GAME_DIRTY_WORDS; ++word) {
        uint32_t mask = g_current_dirty->rows[row][word];
        while (mask) { mask &= mask - 1u; ++count; }
    }
    if (!g_current_dirty->valid || count > GAME_DIRTY_ROWS * GAME_DIRTY_COLS / 2u) {
        issue_command(accel_blit(FULL_BACKGROUND_PHYS, 7680u, 0u, 0u, 1920u, 1080u));
        for (row = 0u; row < GAME_DIRTY_ROWS; ++row) for (word = 0u; word < GAME_DIRTY_WORDS; ++word)
            g_current_dirty->rows[row][word] = 0u;
        g_current_dirty->valid = 1u;
        g_game_runtime.background_pixels += 1920u * 1080u;
        ++g_game_runtime.background_rectangles;
#if GAME_TEAM_SPRITES
        g_hud_cache[back == 0u ? 0u : 1u].valid = 0u;
#endif
    } else {
        while (game_background_next(g_current_dirty, &x, &y, &w, &h)) {
            issue_command(accel_blit(FULL_BACKGROUND_PHYS + y * 7680u + x * 4u,
                                     7680u, x, y, w, h));
            g_game_runtime.background_pixels += w * h;
            ++g_game_runtime.background_rectangles;
        }
    }
}
#endif

static uint32_t aligned_x(int32_t x) {
    if (x < 0) x = 0;
    return (uint32_t)x & ~UINT32_C(3);
}

static uint32_t aligned_y(int32_t y) {
    if (y < 0) y = 0;
    return (uint32_t)y & ~UINT32_C(3);
}

static void draw_key_sprite(uint32_t atlas_x, uint32_t atlas_y,
                            int32_t x, int32_t y, uint32_t size) {
    uint32_t width = size, height = size, src, trim, dest_x;
    if (x < 0) {
        trim = ((uint32_t)(-x) + 3u) & ~UINT32_C(3);
        if (trim >= width) return;
        atlas_x += trim; width -= trim; x = 0;
    }
    dest_x = aligned_x(x);
    if (dest_x >= VIEW_W) return;
    if (width > VIEW_W - dest_x) width = VIEW_W - dest_x;
    if (y < (int32_t)GAME_WORLD_TOP) {
        trim = GAME_WORLD_TOP - (uint32_t)y;
        if (trim >= height) return;
        atlas_y += trim; height -= trim; y = (int32_t)GAME_WORLD_TOP;
    }
    if ((uint32_t)y >= VIEW_H) return;
    if (height > VIEW_H - (uint32_t)y) height = VIEW_H - (uint32_t)y;
    src = SPRITE_PHYS + atlas_y * SPRITE_STRIDE + atlas_x * 4u;
    issue_command(accel_color_key_blit(src, SPRITE_STRIDE,
        VIEW_X + dest_x, VIEW_Y + (uint32_t)y, width, height, COLOR_KEY));
#if GAME_FULLSCREEN
    game_background_mark(g_current_dirty, dest_x, (uint32_t)y, width, height);
#endif
    g_game_runtime.sprite_pixels += width * height;
    ++g_rendered_sprites;
}

static void draw_alpha_sprite(uint32_t atlas_x, uint32_t atlas_y,
                              int32_t x, int32_t y, uint32_t size, uint32_t alpha) {
    uint32_t source_x = atlas_x, source_y = atlas_y;
    uint32_t width = size, height = size, dest_x, dest_y, trim;
    uint32_t src;

    if (x < 0) {
        trim = ((uint32_t)(-x) + 3u) & ~UINT32_C(3);
        if (trim >= width) return;
        source_x += trim;
        width -= trim;
        dest_x = 0u;
    } else {
        dest_x = aligned_x(x);
    }
    if (dest_x >= VIEW_W) return;
    if (width > VIEW_W - dest_x) width = VIEW_W - dest_x;

    if (y < (int32_t)GAME_WORLD_TOP) {
        trim = GAME_WORLD_TOP - (uint32_t)y;
        if (trim >= height) return;
        source_y += trim;
        height -= trim;
        dest_y = GAME_WORLD_TOP;
    } else {
        dest_y = aligned_y(y);
    }
    if (dest_y >= VIEW_H) return;
    if (height > VIEW_H - dest_y) height = VIEW_H - dest_y;
    src = SPRITE_PHYS + source_y * SPRITE_STRIDE + source_x * 4u;
    issue_command(accel_alpha_blend(src, SPRITE_STRIDE,
        VIEW_X + dest_x, VIEW_Y + dest_y, width, height, alpha));
#if GAME_FULLSCREEN
    game_background_mark(g_current_dirty, dest_x, dest_y, width, height);
#endif
    g_game_runtime.sprite_pixels += width * height;
    ++g_rendered_sprites;
}

static char *append(char *out, const char *text) {
    while (*text) *out++ = *text++;
    return out;
}

static char *append_u32(char *out, uint32_t value, uint32_t digits) {
    char temp[10];
    uint32_t used = 0;
    do { temp[used++] = (char)('0' + value % 10u); value /= 10u; } while (value && used < sizeof(temp));
    while (used < digits) temp[used++] = '0';
    while (used) *out++ = temp[--used];
    return out;
}

#if GAME_TEAM_SPRITES
static void draw_text(uint32_t x, uint32_t y, const char *line, uint32_t color) {
    while (*line && x + 16u <= VIEW_W) {
        uint32_t index = game_font_index(*line++);
        if (index < 40u) {
            issue_command(accel_color_key_blit(SPRITE_PHYS + (GAME_FONT_Y + color * 24u) * SPRITE_STRIDE + index * 64u,
                SPRITE_STRIDE, VIEW_X + x, VIEW_Y + y, 16u, 21u, COLOR_KEY));
            ++g_game_runtime.glyph_blits;
        }
        x += 16u;
    }
}

static void cached_hud_line(game_hud_cache_t *cache, uint32_t row, const char *line, uint32_t color) {
    uint32_t i = 0u, same = cache->valid;
    while (line[i] || cache->lines[row][i]) {
        if (line[i] != cache->lines[row][i]) { same = 0u; break; }
        ++i;
    }
    if (same) return;
    /* Only the text region is cleared; the full-width panel stays cached. */
    issue_command(accel_fill_rect(VIEW_X + 12u, VIEW_Y + 6u + row * 24u,
        VIEW_W < 1024u ? VIEW_W - 24u : 1008u, 21u, PANEL));
    draw_text(12u, 6u + row * 24u, line, color);
    i = 0u;
    do { cache->lines[row][i] = line[i]; } while (line[i++]);
}

static void centered_text(uint32_t y, const char *line, uint32_t color) {
    uint32_t length = 0u;
    while (line[length]) ++length;
    draw_text(((VIEW_W - length * 16u) / 2u) & ~3u, y, line, color);
}

static void render_hud(uint32_t back, uint32_t now_ms) {
    game_hud_cache_t *cache = &g_hud_cache[back == 0u ? 0u : 1u];
    char line[64], *p;
#if !GAME_FULLSCREEN && !GAME_WINDOW_HUD_CACHE
    cache->valid = 0u; /* The legacy view restores its whole background. */
#endif
    if (!cache->valid) {
        issue_command(accel_fill_rect(VIEW_X, VIEW_Y, VIEW_W, GAME_WORLD_TOP - 8u, PANEL));
        cache->boss_hp = UINT32_MAX;
        cache->overlay = UINT32_MAX;
    }
    p = line; p = append(p, g_game.stress_mode ? "LOAD:" : "WAVE:");
    p = append_u32(p, g_game.wave, 2u); p = append(p, " SCORE:");
    p = append_u32(p, g_game.score % 100000u, 5u); p = append(p, " HP:");
    p = append_u32(p, g_game.lives, 1u); *p = 0;
#if GAME_SHOWCASE
    if (g_game.showcase && g_game.boss.active) {
        p = line; p = append(p, "BOSS:"); p = append_u32(p, g_game.boss.attack_phase, 1u);
        p = append(p, " SCORE:"); p = append_u32(p, g_game.score % 100000u, 5u);
        p = append(p, " HP:"); p = append_u32(p, g_game.lives, 1u); *p = 0;
    }
    if (g_game.showcase && g_game.invincible_mode) {
        p = append(p, " INV"); *p = 0;
    }
#endif
    cached_hud_line(cache, 0u, line, 0u);
#if GAME_WINDOW_HUD_CACHE
    {
        uint32_t mode = g_game.campaign_stage == GAME_CAMPAIGN_TITLE ? 1u :
            g_game.paused ? 2u : g_game.game_over ? 3u + g_game.campaign_result : 0u;
#if GAME_SHOWCASE
        if (g_game.showcase) mode |= (uint32_t)g_game.showcase_state << 4 |
            (uint32_t)g_game.boss.attack_phase << 8;
#endif
        if (!g_hud_metrics.valid || g_hud_metrics.mode != mode ||
            (uint32_t)(now_ms - g_hud_metrics.refreshed_ms) >= 250u) {
#else
    if (!cache->valid || (uint32_t)(now_ms - cache->refreshed_ms) >= 250u ||
        g_game.paused || g_game.game_over || g_game.campaign_stage == GAME_CAMPAIGN_TITLE) {
#endif
        p = line;
        if (g_game.campaign_stage == GAME_CAMPAIGN_TITLE) p = append(p, "FIRE TO START");
        else if (g_game.paused) p = append(p, "PAUSED P TO CONTINUE");
        else if (g_game.game_over) p = append(p, g_game.campaign_result == 1u ?
#if GAME_SHOWCASE
            "VICTORY FIRE TO RESTART" :
#else
            "MISSION CLEAR FIRE TO RESTART" :
#endif
            "GAME OVER FIRE TO RESTART");
        else {
#if GAME_SHOWCASE
            if (g_game.showcase && g_game.boss.active) {
                p = append(p, g_game.boss.attack_phase == 1u ? "ROTATING ARMS" :
                    g_game.boss.attack_phase == 2u ? "CROSSING FANS" : "RING BURST");
                p = append(p, ((now_ms - g_game.boss_phase_ms) % 5000u) < 3000u ? " MOVE" : " FIRE");
            } else {
#endif
            p = append(p, "FPS:"); p = m1b_fixed2(p, g_game_result.fps_x100);
            p = append(p, " SPR:"); p = append_u32(p, g_game_result.active_sprites, 1u);
            p = append(p, " MAX:"); p = append_u32(p, g_game_result.max_active_sprites, 1u);
#if GAME_SHOWCASE
            }
#endif
        }
        *p = 0;
#if GAME_WINDOW_HUD_CACHE
        { uint32_t i = 0u; do { g_hud_metrics.line[i] = line[i]; } while (line[i++]); }
        g_hud_metrics.refreshed_ms = now_ms;
        g_hud_metrics.mode = mode;
        g_hud_metrics.valid = 1u;
        }
        cached_hud_line(cache, 1u, g_hud_metrics.line, 1u);
#else
        cached_hud_line(cache, 1u, line, 1u);
        cache->refreshed_ms = now_ms;
#endif
    }
#if GAME_FULLSCREEN
    p = line;
    if (g_game.boss.active) {
        p = append(p, "BOSS PHASE:"); p = append_u32(p, g_game.boss.attack_phase, 1u);
        p = append(p, " HP:"); p = append_u32(p, g_game.boss.hp, 2u);
        p = append(p, "/90");
    } else if (g_game.campaign_stage > 0u && g_game.campaign_stage <= 3u) {
        p = append(p, "STAGE:"); p = append_u32(p, g_game.campaign_stage, 1u);
        p = append(p, "/3 TIME:"); p = append_u32(p, (now_ms - g_game.started_ms) / 1000u, 2u);
        p = append(p, "S");
    } else if (g_game.stress_mode) {
        p = append(p, "STRESS "); p = append_u32(p, g_game.enemy_limit, 1u);
        p = append(p, " ENEMIES 64 SHOTS");
    } else p = append(p, "ARROWS MOVE SPACE FIRE P PAUSE");
#if GAME_FLASH_ENABLE
    p = append(p, " BEST:"); p = append_u32(p, g_flash_result.high_score % 100000u, 1u);
    p = append(p, g_flash_result.error ? " ERR" : "");
#endif
    *p = 0; cached_hud_line(cache, 2u, line, 2u);
    if (cache->boss_hp != (g_game.boss.active ? g_game.boss.hp : 0u)) {
        uint32_t hp = g_game.boss.active ? g_game.boss.hp : 0u;
        issue_command(accel_fill_rect(1104u, 12u, 480u, 12u, PANEL));
        if (hp) issue_command(accel_fill_rect(1104u, 12u, (hp * 480u / GAME_BOSS_MAX_HP) & ~3u, 12u, 0x00e85a70u));
        cache->boss_hp = hp;
    }
#endif
#if GAME_SHOWCASE
    if (g_game.showcase && cache->boss_hp != (g_game.boss.active ? g_game.boss.hp : 0u)) {
        uint32_t hp = g_game.boss.active ? g_game.boss.hp : 0u;
        issue_command(accel_fill_rect(VIEW_X + 12u, VIEW_Y + 55u, VIEW_W - 24u, 8u, PANEL));
        if (hp) {
            uint32_t width = ((VIEW_W - 24u) * hp / GAME_SHOWCASE_BOSS_HP) & ~3u;
            if (width) issue_command(accel_fill_rect(VIEW_X + 12u, VIEW_Y + 55u, width, 8u, 0x00e85a70u));
        }
        cache->boss_hp = hp;
    }
    if (g_game.showcase && !g_game.game_over) {
        if (g_game.showcase_state == GAME_SHOWCASE_INTRO ||
            (g_game.showcase_state == GAME_SHOWCASE_BOSS &&
             (int32_t)(g_game.boss_warning_until_ms - now_ms) > 0))
            centered_text(VIEW_H / 2u - 12u, "WARNING", 2u);
        else if (g_game.showcase_state == GAME_SHOWCASE_WAVES &&
            (now_ms - g_game.started_ms) % GAME_SHOWCASE_WAVE_MS < 400u) {
            p = line; p = append(p, "WAVE "); p = append_u32(p, g_game.campaign_stage, 1u); *p = 0;
            centered_text(VIEW_H / 2u - 12u, line, 2u);
        }
    }
#endif
    if (cache->overlay != g_scene_mode || (GAME_WINDOW_HUD_CACHE && g_scene_mode != 0u)) {
        /* Window gameplay is restored every frame, including center overlays. */
        uint32_t y = VIEW_H / 2u - 48u;
        if (g_scene_mode == 1u) {
            centered_text(y, "SKY SURVIVOR", 0u);
            centered_text(y + 40u, "3 WAVES THEN BOSS", 2u);
            centered_text(y + 80u, "FIRE TO START", 1u);
        } else if (g_scene_mode == 2u || g_scene_mode == 3u) {
            centered_text(y, g_scene_mode == 2u ?
#if GAME_SHOWCASE
                "VICTORY" :
#else
                "MISSION CLEAR" :
#endif
                "GAME OVER", 2u);
            p = line; p = append(p, "SCORE:"); p = append_u32(p, g_game.score, 1u); *p = 0;
            centered_text(y + 40u, line, 0u);
            centered_text(y + 80u, "FIRE TO RESTART", 1u);
        }
        cache->overlay = g_scene_mode;
    }
    cache->valid = 1u;
#if GAME_WINDOW_HUD_CACHE
    cache->paused = g_game.paused;
#endif
}
#else
static void render_hud(uint32_t back, uint32_t now_ms) {
    char line[48];
    char *p;
    uint32_t score = g_game.score % 100000u;
    volatile uint32_t *dst = ddr(back);
    issue_command(accel_fill_rect(VIEW_X, VIEW_Y, VIEW_W, GAME_WORLD_TOP - 8u, PANEL));
    cpu_session_begin();
    p = line; p = append(p, "WAVE:"); p = append_u32(p, g_game.wave % 100u, 2u);
    p = append(p, " SCORE:"); p = append_u32(p, score, 5u);
    p = append(p, " HP:"); p = append_u32(p, g_game.lives, 2u); *p = 0;
    m1b_hud_text(dst, VIEW_X + 12u, VIEW_Y + 7u, line, UINT32_C(0x00f5f8ff));
    if (g_game.paused || g_game.game_over) {
        if (g_game.game_over && g_game.auto_restart_ms) {
            uint32_t remaining = (int32_t)(g_game.auto_restart_at_ms - now_ms) > 0 ?
                g_game.auto_restart_at_ms - now_ms : 0u;
            p = line; p = append(p, "GAME OVER RESTART IN ");
            p = append_u32(p, (remaining + 999u) / 1000u, 1u); p = append(p, "S"); *p = 0;
        } else {
            p = line; p = append(p, g_game.game_over ?
                "GAME OVER FIRE TO RESTART" : "PAUSED P TO CONTINUE"); *p = 0;
        }
        m1b_hud_text(dst, VIEW_X + 12u, VIEW_Y + 34u, line, UINT32_C(0x00ffd878));
    } else {
        p = line; p = append(p, "FPS:");
        p = m1b_fixed2(p, g_game_result.fps_x100);
        p = append(p, " SPR:"); p = append_u32(p, g_game_result.active_sprites, 2u);
        p = append(p, " MAX:"); p = append_u32(p, g_game_result.max_active_sprites, 2u); *p = 0;
        m1b_hud_text(dst, VIEW_X + 12u, VIEW_Y + 34u, line, UINT32_C(0x004bd9ef));
    }
#if GAME_FLASH_ENABLE
    p=line;p=append(p,"BEST:");p=append_u32(p,g_flash_result.high_score,1u);
    p=append(p," D:");p=append_u32(p,g_flash_result.difficulty,1u);
    p=append(p,g_flash_result.error?" SAVE ERROR":" FLASH OK");*p=0;
    m1b_hud_text(dst,VIEW_X+12u,VIEW_Y+52u,line,UINT32_C(0x00ffd878));
#endif
    cpu_session_end();
    (void)now_ms;
}
#endif

static void update_metrics(uint32_t now_ms) {
    uint32_t active = g_rendered_sprites;
    g_game_result.active_sprites = active;
    if (active > g_game_result.max_active_sprites)
        g_game_result.max_active_sprites = active;
    if ((uint32_t)(now_ms - g_fps_window_ms) >= 1000u) {
        uint32_t elapsed = now_ms - g_fps_window_ms;
        g_game_result.fps_x100 = (uint32_t)((uint64_t)g_fps_window_frames * 100000u / elapsed);
        g_fps_window_ms = now_ms;
        g_fps_window_frames = 0u;
    }
}

static void measure_frame(uint32_t now_ms) {
    uint32_t elapsed, fps;
    if (g_debug_status.measurement_state != 1u) return;
    elapsed = now_ms - g_measure_start;
    g_debug_status.measurement_elapsed_ms = elapsed;
    ++g_debug_status.measurement_frames;
#if GAME_ALLOW_SCALE2
    {
        uint32_t boundary = accel_read(ACCEL_BOUNDARY_COUNT);
        if (g_presentation_measure_started) {
            uint32_t gap = boundary - g_game_presentation.last_boundary;
            ++g_game_presentation.presentation_intervals;
            if (gap > 1u) g_game_presentation.missing_boundaries += gap - 1u;
            if (gap > g_game_presentation.max_boundary_gap) g_game_presentation.max_boundary_gap = gap;
        } else {
            g_game_presentation.first_boundary = boundary;
            g_presentation_measure_started = 1u;
        }
        g_game_presentation.last_boundary = boundary;
    }
#endif
    g_game_runtime.measurement_display_frames = accel_read(ACCEL_BOUNDARY_COUNT) - g_measure_boundary_base;
    g_game_runtime.measurement_repeated_frames =
        g_game_runtime.measurement_display_frames > g_debug_status.measurement_frames ?
        g_game_runtime.measurement_display_frames - g_debug_status.measurement_frames : 0u;
    g_debug_status.measurement_swaps = accel_read(ACCEL_SWAP_COUNT) - g_measure_swap_base;
    g_debug_status.measurement_underflows = accel_read(ACCEL_DISPLAY_UNDERFLOW_COUNT) - g_measure_underflow_base;
    g_debug_status.measurement_missed = accel_read(ACCEL_MISSED_BOUNDARY_COUNT) - g_measure_missed_base;
    if (g_rendered_sprites < g_debug_status.measurement_min_sprites)
        g_debug_status.measurement_min_sprites = g_rendered_sprites;
    if (g_rendered_sprites > g_debug_status.measurement_max_sprites)
        g_debug_status.measurement_max_sprites = g_rendered_sprites;
#if GAME_STRESS_TUNING
    if (g_game_stress_status.rendered_enemies < g_game_stress_status.measurement_min_enemies)
        g_game_stress_status.measurement_min_enemies = g_game_stress_status.rendered_enemies;
    if (g_game_stress_status.rendered_enemies > g_game_stress_status.measurement_max_enemies)
        g_game_stress_status.measurement_max_enemies = g_game_stress_status.rendered_enemies;
    if (g_game_stress_status.rendered_enemy_bullets < g_game_stress_status.measurement_min_enemy_bullets)
        g_game_stress_status.measurement_min_enemy_bullets = g_game_stress_status.rendered_enemy_bullets;
    if (g_game_stress_status.rendered_enemy_bullets > g_game_stress_status.measurement_max_enemy_bullets)
        g_game_stress_status.measurement_max_enemy_bullets = g_game_stress_status.rendered_enemy_bullets;
#endif
    ++g_measure_window_frames;
    if ((uint32_t)(now_ms-g_measure_window_ms) >= 1000u) {
        fps = (uint32_t)((uint64_t)g_measure_window_frames * 100000u / (now_ms-g_measure_window_ms));
        if (fps < g_debug_status.measurement_min_fps_x100)
            g_debug_status.measurement_min_fps_x100 = fps;
        g_measure_window_ms = now_ms;
        g_measure_window_frames = 0u;
    }
    /* Sample monotonic hardware counters once per second so 32-bit wrap is
       unambiguous even on a fast AXI clock, and keep the render path untouched. */
#if GAME_PATH_DIAGNOSTICS
    if (elapsed - g_measure_diag_sample_ms >= 1000u || elapsed >= 60000u) {
        uint32_t value;
        value = accel_read(ACCEL_WRITER_THROTTLE_CYCLES);
        g_measure_writer_throttle_total += (uint32_t)(value - g_measure_writer_throttle_last);
        g_measure_writer_throttle_last = value;
        value = accel_read(ACCEL_WRITER_BURSTS);
        g_measure_writer_bursts_total += (uint32_t)(value - g_measure_writer_bursts_last);
        g_measure_writer_bursts_last = value;
        value = accel_read(ACCEL_READER_AR_STALL_CYCLES);
        g_measure_reader_ar_stall_total += (uint32_t)(value - g_measure_reader_ar_stall_last);
        g_measure_reader_ar_stall_last = value;
        value = accel_read(ACCEL_READER_R_STALL_CYCLES);
        g_measure_reader_r_stall_total += (uint32_t)(value - g_measure_reader_r_stall_last);
        g_measure_reader_r_stall_last = value;
        value = accel_read(ACCEL_COMMAND_COUNT);
        g_measure_commands_total += (uint32_t)(value - g_measure_commands_last);
        g_measure_commands_last = value;
        g_measure_diag_sample_ms = elapsed;
    }
    if (elapsed >= 60000u) {
        g_game_runtime.measurement_writer_throttle_cycles_lo = (uint32_t)g_measure_writer_throttle_total;
        g_game_runtime.measurement_writer_throttle_cycles_hi = (uint32_t)(g_measure_writer_throttle_total >> 32);
        g_game_runtime.measurement_writer_bursts = g_measure_writer_bursts_total;
        g_game_runtime.measurement_reader_ar_stall_cycles_lo = (uint32_t)g_measure_reader_ar_stall_total;
        g_game_runtime.measurement_reader_ar_stall_cycles_hi = (uint32_t)(g_measure_reader_ar_stall_total >> 32);
        g_game_runtime.measurement_reader_r_stall_cycles_lo = (uint32_t)g_measure_reader_r_stall_total;
        g_game_runtime.measurement_reader_r_stall_cycles_hi = (uint32_t)(g_measure_reader_r_stall_total >> 32);
        g_game_runtime.measurement_commands = g_measure_commands_total;
        g_debug_status.measurement_state = 2u;
    }
#else
    if (elapsed >= 60000u) g_debug_status.measurement_state = 2u;
#endif
    if (g_debug_status.measurement_state == 2u) {
        GAME_FENCE();
        g_game_measurement_complete = 1u;
    }
}

static void render_frame(uint32_t now_ms) {
    uint32_t i, back = display_get_back_buffer(), front = display_get_front_buffer(), ticket;
    uint32_t mode = g_game.campaign_stage == GAME_CAMPAIGN_TITLE ? 1u :
        (g_game.game_over ? (g_game.campaign_result == 1u ? 2u : 3u) : 0u);
    uint64_t began = ticks(), rendered, presented;
    ++g_game_runtime.publication;
#if GAME_ALLOW_SCALE2
    ++g_game_presentation.publication;
#endif
    GAME_FENCE();
    g_game_runtime.background_pixels = g_game_runtime.background_rectangles = 0u;
    g_game_runtime.sprite_pixels = g_game_runtime.glyph_blits = 0u;
    g_game_runtime.command_submit_us = g_game_runtime.command_wait_us = 0u;
    if (mode != g_scene_mode) {
        g_scene_mode = mode;
#if GAME_FULLSCREEN
        g_background_dirty[0].valid = g_background_dirty[1].valid = 0u;
#endif
#if GAME_TEAM_SPRITES
        g_hud_cache[0].valid = g_hud_cache[1].valid = 0u;
#endif
    }
    if (back == front || (back != 0u && back != UINT32_C(0x00800000)) ||
        (front != 0u && front != UINT32_C(0x00800000))) fail(ERROR_RENDER);
    require(accel_command_batch_begin());

    g_rendered_sprites = 0u;
#if GAME_STRESS_TUNING
    g_game_stress_status.rendered_enemies = g_game_stress_status.rendered_enemy_bullets = 0u;
#endif
#if GAME_FULLSCREEN
    restore_game_background(back);
#elif GAME_TEAM_BACKGROUND
    restore_centered_island_background(back);
#elif GAME_FLASH_ENABLE
    issue_command(accel_blit(ASSET_BASE+((g_game.score/1000u)%3u)*ASSET_BYTES,
                            2560u,VIEW_X,VIEW_Y,VIEW_W,VIEW_H));
#else
    issue_command(accel_fill_rect(VIEW_X, VIEW_Y, VIEW_W, VIEW_H, BACKGROUND));
#endif
    if (mode == 0u) {
    for (i = 0; i < GAME_EFFECT_LIMIT; ++i) {
        const game_effect_t *effect = &g_game.effects[i];
        if (effect->active && (int32_t)(effect->expires_ms - now_ms) > 0) {
#if GAME_SHOWCASE
            if (effect->kind == GAME_EFFECT_HIT) continue;
#endif
#if GAME_TEAM_SPRITES
            uint32_t frame = game_team_explosion_frame(now_ms, effect->expires_ms);
            draw_alpha_sprite(frame * GAME_TEAM_EXPLOSION_SIZE * GAME_PIXEL_SCALE,
                GAME_TEAM_EXPLOSION_Y * GAME_PIXEL_SCALE,
                effect->x, effect->y, GAME_TEAM_EXPLOSION_SIZE * GAME_PIXEL_SCALE,
                game_team_explosion_alpha(now_ms, effect->expires_ms));
#else
            draw_alpha_sprite(0u, 0u, effect->x - 16, effect->y - 16, 64u, 210u);
#endif
        }
    }
    if (g_game.boss.active) {
#if GAME_TEAM_SPRITES
        draw_key_sprite(0u, 320u, g_game.boss.x, g_game.boss.y, GAME_BOSS_SIZE);
#else
        draw_key_sprite(96u, 0u, g_game.boss.x, g_game.boss.y, GAME_PLAYER_SIZE);
#endif
    }
    for (i = 0; i < GAME_ENEMY_LIMIT; ++i) {
        const game_enemy_t *enemy = &g_game.enemies[i];
#if GAME_STRESS_TUNING
        uint32_t before = g_rendered_sprites;
#endif
        if (enemy->active) draw_key_sprite(96u * GAME_PIXEL_SCALE, 0u, enemy->x, enemy->y, GAME_PLAYER_SIZE);
#if GAME_STRESS_TUNING
        g_game_stress_status.rendered_enemies += g_rendered_sprites - before;
#endif
    }
    for (i = 0; i < GAME_BULLET_LIMIT; ++i) {
        const game_bullet_t *bullet = &g_game.bullets[i];
        if (bullet->active) draw_alpha_sprite(128u * GAME_PIXEL_SCALE, 0u,
            bullet->x, bullet->y, GAME_PROJECTILE_SIZE, g_projectile_alpha);
    }
    for (i = 0; i < survival_game_enemy_bullet_limit(&g_game); ++i) {
        const game_enemy_bullet_t *bullet = &g_game.enemy_bullets[i];
#if GAME_STRESS_TUNING
        uint32_t before = g_rendered_sprites;
#endif
        if (bullet->active) {
#if GAME_TEAM_SPRITES
            draw_alpha_sprite(GAME_TEAM_ENEMY_BULLET_X * GAME_PIXEL_SCALE, 0u,
                bullet->x, bullet->y, GAME_PROJECTILE_SIZE, g_projectile_alpha);
#else
            draw_alpha_sprite(24u, 24u, bullet->x, bullet->y, 16u, g_projectile_alpha);
#endif
        }
#if GAME_STRESS_TUNING
        g_game_stress_status.rendered_enemy_bullets += g_rendered_sprites - before;
#endif
    }
    if (!g_game.game_over) {
        draw_alpha_sprite(16u * GAME_PIXEL_SCALE, 16u * GAME_PIXEL_SCALE,
                          g_game.player_x, g_game.player_y, GAME_PLAYER_SIZE,
                          g_game.invulnerable ? 110u : 150u);
        if (!g_game.invulnerable || ((now_ms / 90u) & 1u))
            draw_key_sprite(64u * GAME_PIXEL_SCALE, 0u, g_game.player_x, g_game.player_y, GAME_PLAYER_SIZE);
        /* The 6x6 logical hitbox is visible at the center of the ship. */
        {
            uint32_t hx = aligned_x(g_game.player_x + 13 * (int32_t)GAME_PIXEL_SCALE);
            uint32_t hy = (uint32_t)g_game.player_y + 13u * GAME_PIXEL_SCALE;
            issue_command(accel_fill_rect(VIEW_X + hx, VIEW_Y + hy, 4u * GAME_PIXEL_SCALE,
                4u * GAME_PIXEL_SCALE, g_game.invulnerable ? 0x00ffd878u : 0x00ffffffu));
#if GAME_FULLSCREEN
            game_background_mark(g_current_dirty, hx, hy, 4u * GAME_PIXEL_SCALE, 4u * GAME_PIXEL_SCALE);
#endif
        }
    }
    }
#if GAME_SHOWCASE
    if (mode == 0u) for (i = 0; i < GAME_EFFECT_LIMIT; ++i) {
        const game_effect_t *effect = &g_game.effects[i];
        if (effect->active && effect->kind == GAME_EFFECT_HIT &&
            (int32_t)(effect->expires_ms - now_ms) > 0) {
            uint32_t age = GAME_SHOWCASE_HIT_MS - (effect->expires_ms - now_ms);
            uint32_t frame = age * 6u / GAME_SHOWCASE_HIT_MS;
            draw_alpha_sprite(160u + frame * 16u, 0u, effect->x, effect->y, 16u, 255u);
        }
    }
#endif
    update_metrics(now_ms);
    render_hud(back, now_ms);
    /* Drain queued work before checking or publishing the completed Back. */
    finish_command_batch();
    check_health();
    rendered = ticks();
    require(display_swap_request(&ticket));
    require(display_wait_swap_done(ticket));
    presented = ticks();
    g_game_runtime.magic = GAME_RUNTIME_MAGIC;
    g_game_runtime.campaign_stage = g_game.campaign_stage;
    g_game_runtime.campaign_result = g_game.campaign_result;
    g_game_runtime.boss_hp = g_game.boss.hp;
    g_game_runtime.stress_mode = g_game.stress_mode;
    g_game_runtime.render_us = (uint32_t)((rendered - began) / (SYSTEM_CLINT_HZ / 1000000u));
    g_game_runtime.frame_us = g_last_present_ticks ?
        (uint32_t)((presented - g_last_present_ticks) / (SYSTEM_CLINT_HZ / 1000000u)) : 0u;
    g_last_present_ticks = presented;
    if (g_game_runtime.render_us > g_game_runtime.max_render_us) g_game_runtime.max_render_us = g_game_runtime.render_us;
    if (g_game_runtime.frame_us > g_game_runtime.max_frame_us) g_game_runtime.max_frame_us = g_game_runtime.frame_us;
    if (g_game_runtime.render_us > GAME_FRAME_BUDGET_US) ++g_game_runtime.over_budget_frames;
    if (g_debug_status.measurement_state == 1u) {
        if (g_game_runtime.render_us > g_game_runtime.measurement_max_render_us)
            g_game_runtime.measurement_max_render_us = g_game_runtime.render_us;
        if (g_game_runtime.frame_us > g_game_runtime.measurement_max_frame_us)
            g_game_runtime.measurement_max_frame_us = g_game_runtime.frame_us;
        if (g_game_runtime.render_us > GAME_FRAME_BUDGET_US) ++g_game_runtime.measurement_over_budget_frames;
#if GAME_PATH_DIAGNOSTICS
        g_game_runtime.measurement_command_wait_us += g_game_runtime.command_wait_us;
#endif
#if GAME_SUBMIT_TIMING
        g_game_runtime.measurement_command_submit_us += g_game_runtime.command_submit_us;
#endif
    }
    measure_frame(milliseconds());
#if GAME_ALLOW_SCALE2
    g_game_presentation.showcase = GAME_SHOWCASE;
#if GAME_SHOWCASE
    g_game_presentation.showcase = g_game.showcase;
    g_game_presentation.state = g_game.campaign_stage == GAME_CAMPAIGN_TITLE ? 0u : g_game.showcase_state;
    g_game_presentation.boss_phase = g_game.boss.attack_phase;
    g_game_presentation.boss_moving = g_game.showcase_state == GAME_SHOWCASE_BOSS &&
        ((now_ms - g_game.boss_phase_ms) % 5000u) < 3000u;
#endif
    GAME_FENCE(); ++g_game_presentation.publication;
#endif
    GAME_FENCE();
    ++g_game_runtime.publication;
    ++g_game_result.frame;
    ++g_fps_window_frames;
    g_game_result.score = g_game.score;
    g_game_result.lives = g_game.lives;
    g_game_result.player_x = (uint32_t)g_game.player_x;
    g_game_result.player_y = (uint32_t)g_game.player_y;
    g_game_result.command_delta = accel_read(ACCEL_COMMAND_COUNT) - g_command_base;
    g_game_result.swap_delta = accel_read(ACCEL_SWAP_COUNT) - g_swap_base;
    check_health();
    g_game_result.phase = g_game.game_over ? GAME_DEBUG_PHASE_GAME_OVER :
        (g_game.paused ? GAME_DEBUG_PHASE_PAUSED : GAME_DEBUG_PHASE_PLAYING);
    publish_status();
}

static void restart_game(uint32_t now_ms) {
    /* Preserve only options already accepted by the firmware. A partially
       written or rejected mailbox command must not change restart behavior. */
    uint32_t delay = g_game.enemy_limit ? g_game.auto_restart_ms : g_debug_control.auto_restart_ms;
    uint32_t interval = g_game.enemy_limit ? g_game.enemy_fire_interval_ms : g_debug_control.enemy_fire_interval_ms;
    uint8_t limit = g_game.enemy_limit ? g_game.enemy_limit :
        (uint8_t)(g_debug_control.enemy_limit > GAME_ENEMY_LIMIT ? GAME_ENEMY_LIMIT : g_debug_control.enemy_limit);
    uint8_t invincible = g_game.enemy_limit ? g_game.invincible_mode : (uint8_t)(g_debug_control.flags & 1u);
    survival_game_reset(&g_game, now_ms);
    survival_game_set_options(&g_game, delay, interval, limit, invincible);
#if GAME_SHOWCASE
    survival_game_begin_showcase(&g_game, now_ms);
#else
    survival_game_begin_campaign(&g_game, now_ms);
#endif
    g_test_page = 0u;
#if GAME_FULLSCREEN
    g_background_dirty[0].valid = g_background_dirty[1].valid = 0u;
#endif
    g_fps_window_ms = now_ms;
    g_fps_window_frames = 0u;
    g_last_present_ticks = 0u;
#if GAME_WINDOW_HUD_CACHE
    g_window_background_valid = 0u;
    g_hud_metrics.valid = 0u;
#endif
#if GAME_TEAM_SPRITES
    g_hud_cache[0].valid = g_hud_cache[1].valid = 0u;
#endif
}

static uint32_t alpha_reference(uint32_t src, uint32_t dst, uint32_t alpha) {
    uint32_t a = ((src >> 24) * alpha + 127u) / 255u;
    uint32_t r = (((src >> 16) & 255u) * a + ((dst >> 16) & 255u) * (255u-a) + 127u) / 255u;
    uint32_t g = (((src >> 8) & 255u) * a + ((dst >> 8) & 255u) * (255u-a) + 127u) / 255u;
    uint32_t b = ((src & 255u) * a + (dst & 255u) * (255u-a) + 127u) / 255u;
    return (dst & UINT32_C(0xff000000)) | (r << 16) | (g << 8) | b;
}

static GAME_SETUP void run_self_test(void) {
    uint32_t back = display_get_back_buffer(), ticket, x, y, failed = 0u;
    const uint32_t color = UINT32_C(0xa52b4671);
    volatile uint32_t *dst = ddr(back);
    g_game_result.phase = GAME_DEBUG_PHASE_TESTING;
    g_debug_status.self_test_result = 0u;
    publish_status();
    if ((back != 0u && back != UINT32_C(0x00800000)) ||
        back == display_get_front_buffer()) fail(ERROR_RENDER);
    issue_command(accel_fill_rect(VIEW_X, VIEW_Y, VIEW_W, VIEW_H, color));
    require(accel_wait_done());
    check_health();
    cpu_session_begin();
    for (y = 0; y < 16u; ++y) for (x = 0; x < 16u; ++x)
        if (dst[(VIEW_Y+y)*1920u+VIEW_X+x] != color) failed |= 1u;
    cpu_session_end();
    issue_command(accel_color_key_blit(SPRITE_PHYS+64u*GAME_PIXEL_SCALE*4u, SPRITE_STRIDE,
        VIEW_X, VIEW_Y, GAME_PLAYER_SIZE, GAME_PLAYER_SIZE, COLOR_KEY));
    require(accel_wait_done());
    check_health();
    cpu_session_begin();
    for (y = 0; y < GAME_PLAYER_SIZE; ++y) for (x = 0; x < GAME_PLAYER_SIZE; ++x) {
        uint32_t src = atlas_pixel(64u*GAME_PIXEL_SCALE+x, y);
        uint32_t expected = (src & UINT32_C(0xffffff)) == COLOR_KEY ? color : src;
        if (dst[(VIEW_Y+y)*1920u+VIEW_X+x] != expected) failed |= 2u;
    }
    cpu_session_end();
    issue_command(accel_alpha_blend(SPRITE_PHYS+128u*GAME_PIXEL_SCALE*4u, SPRITE_STRIDE,
        VIEW_X+128u, VIEW_Y, GAME_PROJECTILE_SIZE, GAME_PROJECTILE_SIZE, g_projectile_alpha));
    require(accel_wait_done());
    check_health();
    cpu_session_begin();
    for (y = 0; y < GAME_PROJECTILE_SIZE; ++y) for (x = 0; x < GAME_PROJECTILE_SIZE; ++x)
        if (dst[(VIEW_Y+y)*1920u+VIEW_X+128u+x] !=
            alpha_reference(atlas_pixel(128u*GAME_PIXEL_SCALE+x,y), color, g_projectile_alpha)) failed |= 4u;
    m1b_hud_text(dst, VIEW_X+12u, VIEW_Y+100u,
        failed ? "SELF TEST FAILED CHECK STATUS" : "FILL KEY ALPHA READBACK PASS", UINT32_C(0x00ffffff));
    m1b_hud_text(dst, VIEW_X+12u, VIEW_Y+140u,
        "USE ENTER GAME IN DEBUG WINDOW", UINT32_C(0x00ffffff));
    cpu_session_end();
    require(display_swap_request(&ticket));
    require(display_wait_swap_done(ticket));
    if (display_get_front_buffer() != back) failed |= 8u;
    check_health();
    /* Low 16 bits: passed; high 16 bits: readback mismatches. */
    g_debug_status.self_test_result = ((15u & ~failed) | (failed << 16));
#if GAME_WINDOW_HUD_CACHE
    g_window_background_valid = 0u;
    g_hud_metrics.valid = 0u;
    g_hud_cache[0].valid = g_hud_cache[1].valid = 0u;
#endif
    g_test_page = 1u;
    g_game_result.phase = GAME_DEBUG_PHASE_TEST_RESULT;
}

static void service_debug_command(uint32_t now_ms) {
    uint32_t sequence = g_debug_control.sequence, command;
    if (g_debug_control.magic != GAME_DEBUG_CONTROL_MAGIC ||
        sequence == g_debug_status.acknowledged_sequence) return;
    GAME_FENCE();
    command = g_debug_control.command;
    g_debug_status.command_result = 0u;
    /* Commands run only after the preceding frame/swap and CPU session end. */
    check_health();
    if (g_debug_status.measurement_state == 1u) {
        g_debug_status.command_result = UINT32_C(0xed04);
    } else if ((accel_read(ACCEL_STATUS) & ACCEL_BUSY) ||
        (accel_read(ACCEL_BUFFER_STATUS) & (FRAME_SWAP_PENDING | FRAME_WRITER_OWNED))) {
        g_debug_status.command_result = UINT32_C(0xed02);
    } else if (command == GAME_DEBUG_CMD_RESTART || command == GAME_DEBUG_CMD_ENTER_GAME
#if GAME_SHOWCASE
               || command == GAME_DEBUG_CMD_SHOWCASE
#endif
               ) {
        restart_game(now_ms);
    } else if (command == GAME_DEBUG_CMD_PAUSE || command == GAME_DEBUG_CMD_RESUME) {
        uint8_t should_pause = command == GAME_DEBUG_CMD_PAUSE;
        if (g_game.paused != should_pause) {
            g_game.previous_buttons = (uint8_t)(g_keyboard.parser.buttons &
                (uint8_t)~UART_KEY_PAUSE);
            survival_game_step(&g_game, UART_KEY_PAUSE, now_ms);
            g_game.previous_buttons = g_keyboard.parser.buttons;
        }
    } else if (command == GAME_DEBUG_CMD_APPLY_OPTIONS) {
        survival_game_set_options(&g_game, g_debug_control.auto_restart_ms,
            g_debug_control.enemy_fire_interval_ms,
            (uint8_t)(g_debug_control.enemy_limit > GAME_ENEMY_LIMIT ? GAME_ENEMY_LIMIT :
                g_debug_control.enemy_limit), (uint8_t)(g_debug_control.flags & 1u));
        if (g_game.game_over) g_game.auto_restart_at_ms = now_ms + g_game.auto_restart_ms;
        g_projectile_alpha = g_debug_control.projectile_alpha > 255u ? 255u :
                             g_debug_control.projectile_alpha;
    } else if (command == GAME_DEBUG_CMD_SELF_TEST) {
        run_self_test();
    } else if (command == GAME_DEBUG_CMD_STRESS) {
        restart_game(now_ms);
        survival_game_begin_stress(&g_game, now_ms);
#if GAME_STRESS_TUNING
    } else if (command == GAME_DEBUG_CMD_STRESS_LOAD) {
        uint32_t enemies = g_game_stress_request.enemies;
        uint32_t bullets = g_game_stress_request.enemy_bullets;
        if (enemies < 1u || enemies > GAME_ENEMY_LIMIT ||
            bullets < 1u || bullets > GAME_ENEMY_BULLET_CAPACITY) {
            g_debug_status.command_result = UINT32_C(0xed05);
        } else {
            restart_game(now_ms);
            (void)survival_game_begin_stress_load(&g_game, now_ms, enemies, bullets);
            g_game_result.max_active_sprites = 0u;
            g_debug_status.measurement_state = 0u;
            g_game_measurement_complete = 0u;
        }
#endif
    } else if (command == GAME_DEBUG_CMD_MEASURE_60S && !g_test_page && !g_game.paused &&
               !g_game.game_over && g_game.invincible_mode && g_game.stress_mode &&
               (GAME_STRESS_TUNING || g_game.enemy_limit == GAME_ENEMY_LIMIT)) {
        g_game_measurement_complete = 0u;
        g_measure_start = milliseconds();
        g_measure_window_ms = g_measure_start;
        g_measure_window_frames = 0u;
        g_measure_swap_base = accel_read(ACCEL_SWAP_COUNT);
        g_measure_underflow_base = accel_read(ACCEL_DISPLAY_UNDERFLOW_COUNT);
        g_measure_missed_base = accel_read(ACCEL_MISSED_BOUNDARY_COUNT);
        g_measure_boundary_base = accel_read(ACCEL_BOUNDARY_COUNT);
        g_debug_status.measurement_state = 1u;
        g_debug_status.measurement_elapsed_ms = 0u;
        g_debug_status.measurement_frames = 0u;
        g_debug_status.measurement_swaps = 0u;
        g_debug_status.measurement_underflows = 0u;
        g_debug_status.measurement_missed = 0u;
        g_debug_status.measurement_min_fps_x100 = UINT32_MAX;
        g_debug_status.measurement_min_sprites = UINT32_MAX;
        g_debug_status.measurement_max_sprites = 0u;
#if GAME_STRESS_TUNING
        g_game_stress_status.measurement_enemies = g_game.enemy_limit;
        g_game_stress_status.measurement_enemy_bullets = survival_game_enemy_bullet_limit(&g_game);
        g_game_stress_status.measurement_min_enemies = UINT32_MAX;
        g_game_stress_status.measurement_max_enemies = 0u;
        g_game_stress_status.measurement_min_enemy_bullets = UINT32_MAX;
        g_game_stress_status.measurement_max_enemy_bullets = 0u;
#endif
        g_game_runtime.measurement_max_render_us = 0u;
        g_game_runtime.measurement_max_frame_us = 0u;
        g_game_runtime.measurement_over_budget_frames = 0u;
        g_game_runtime.measurement_display_frames = g_game_runtime.measurement_repeated_frames = 0u;
#if GAME_ALLOW_SCALE2
        g_presentation_measure_started = 0u;
        g_game_presentation.first_boundary = g_game_presentation.last_boundary = 0u;
        g_game_presentation.presentation_intervals = g_game_presentation.missing_boundaries = 0u;
        g_game_presentation.max_boundary_gap = 0u;
#endif
        g_game_runtime.measurement_path_diagnostics =
            (GAME_PATH_DIAGNOSTICS ? GAME_RUNTIME_DIAG_HW_COUNTERS : 0u) |
            (GAME_SUBMIT_TIMING ? GAME_RUNTIME_DIAG_SUBMIT_TIMING : 0u);
#if GAME_PATH_DIAGNOSTICS
        g_game_runtime.measurement_writer_throttle_cycles_lo = 0u;
        g_game_runtime.measurement_writer_throttle_cycles_hi = 0u;
        g_game_runtime.measurement_writer_bursts = 0u;
        g_game_runtime.measurement_reader_ar_stall_cycles_lo = 0u;
        g_game_runtime.measurement_reader_ar_stall_cycles_hi = 0u;
        g_game_runtime.measurement_reader_r_stall_cycles_lo = 0u;
        g_game_runtime.measurement_reader_r_stall_cycles_hi = 0u;
        g_game_runtime.measurement_commands = 0u;
        g_measure_writer_throttle_total = 0u;
        g_measure_reader_ar_stall_total = 0u;
        g_measure_reader_r_stall_total = 0u;
        g_measure_writer_bursts_total = 0u;
        g_measure_commands_total = 0u;
        g_measure_writer_throttle_last = accel_read(ACCEL_WRITER_THROTTLE_CYCLES);
        g_measure_writer_bursts_last = accel_read(ACCEL_WRITER_BURSTS);
        g_measure_reader_ar_stall_last = accel_read(ACCEL_READER_AR_STALL_CYCLES);
        g_measure_reader_r_stall_last = accel_read(ACCEL_READER_R_STALL_CYCLES);
        g_measure_commands_last = accel_read(ACCEL_COMMAND_COUNT);
        g_measure_diag_sample_ms = 0u;
#endif
        g_game_runtime.measurement_command_wait_us = 0u;
        g_game_runtime.measurement_command_submit_us = 0u;
        /* Exclude the submitting JTAG halt from the first presentation gap. */
        g_last_present_ticks = 0u;
    } else if (command != GAME_DEBUG_CMD_NONE) {
        g_debug_status.command_result = UINT32_C(0xed03);
    }
    GAME_FENCE();
    g_debug_status.acknowledged_sequence = sequence;
    publish_status();
}

int main(void) {
    uint32_t now_ms;
#if GAME_FLASH_ENABLE
    uint32_t saved_game_over=0;
#endif
    GAME_DISABLE_INTERRUPTS();
    g_game_result.magic = UINT32_C(0x53555256);
    g_game_result.phase = PHASE_STARTUP;
    uart_keyboard_input_init(&g_keyboard);
    g_debug_control.magic = GAME_DEBUG_CONTROL_MAGIC;
    g_debug_control.auto_restart_ms = 0u;
    g_debug_control.enemy_fire_interval_ms = 900u;
    g_debug_control.enemy_limit = GAME_ENEMY_LIMIT;
    g_debug_control.projectile_alpha = 225u;
#if GAME_STRESS_TUNING
    g_game_stress_request.enemies = GAME_ENEMY_LIMIT;
    g_game_stress_request.enemy_bullets = GAME_ENEMY_BULLET_LIMIT;
    if (g_game_stress_limits.magic != GAME_STRESS_MAGIC) fail(ERROR_RENDER);
    g_game_stress_status.magic = GAME_STRESS_MAGIC;
    g_game_stress_status.version = 1u;
#endif
    publish_status();
    require(accel_init());
    if (g_game_build_config.magic != GAME_BUILD_CONFIG_MAGIC) fail(ERROR_RENDER);
#if GAME_SHOWCASE
    if (g_game_showcase_available != 1u) fail(ERROR_RENDER);
#endif
#if GAME_ALLOW_SCALE2
    if (g_game_scale2_compatible != UINT32_C(0x4000)) fail(ERROR_RENDER);
    g_game_presentation.magic = UINT32_C(0x47505231);
    g_game_presentation.scale = (accel_read(ACCEL_CAPABILITIES) & ACCEL_CAP_DISPLAY_SCALE2) ? 2u : 1u;
    g_game_presentation.display_x = g_game_presentation.scale == 2u ? 320u : 640u;
    g_game_presentation.display_y = g_game_presentation.scale == 2u ? 60u : 300u;
    g_game_presentation.display_width = 640u * g_game_presentation.scale;
    g_game_presentation.display_height = 480u * g_game_presentation.scale;
#endif
#if GAME_WINDOW_HUD_CACHE
    if (g_game_window_hud_cache != 1u) fail(ERROR_RENDER);
    if (g_game_alpha_hardware_compatible != UINT32_C(0x3000)) fail(ERROR_RENDER);
#endif
#if GAME_TEAM_BACKGROUND || GAME_REQUIRE_QUEUE
    if ((accel_read(ACCEL_CAPABILITIES) & g_game_required_caps) != g_game_required_caps)
        fail(ERROR_RENDER);
#endif
    if (!(accel_read(ACCEL_CPU_DDR_STATUS) & 16u) ||
        !(accel_read(ACCEL_CAPABILITIES) & ACCEL_CAP_ALPHA) ||
        !(accel_read(ACCEL_CAPABILITIES) & ACCEL_CAP_COLOR_KEY)) fail(ERROR_RENDER);
    require(display_wait_frames(3u));
    g_underflow_base = accel_read(ACCEL_DISPLAY_UNDERFLOW_COUNT);
    g_missed_base = accel_read(ACCEL_MISSED_BOUNDARY_COUNT);
    initialize_display_background();
    g_command_base = accel_read(ACCEL_COMMAND_COUNT);
    g_swap_base = accel_read(ACCEL_SWAP_COUNT);
#if GAME_FLASH_ENABLE
    if(game_flash_begin())fail(ERROR_ASSET);
#endif
    initialize_assets();
    initialize_sprite_atlas();
#if GAME_TEAM_BACKGROUND && !GAME_FULLSCREEN
    initialize_centered_island_background();
#endif

    now_ms = milliseconds();
    restart_game(now_ms);
    g_game.campaign_stage = GAME_CAMPAIGN_TITLE;
    g_now_ms = now_ms;
    g_fps_window_ms = now_ms;
    g_game_result.phase = PHASE_PLAYING;
    for (;;) {
        uint8_t buttons;
        poll_keyboard();
        service_debug_command(g_now_ms);
        if (g_test_page) {
            publish_status();
            continue;
        }
        buttons = uart_keyboard_input_consume_buttons(&g_keyboard);
        if (g_debug_status.measurement_state == 1u) buttons &= (uint8_t)~UART_KEY_PAUSE;
#if GAME_FLASH_ENABLE
        g_game.difficulty=(uint8_t)g_flash_result.difficulty;
#endif
        survival_game_step(&g_game, buttons, g_now_ms);
#if GAME_FLASH_ENABLE
        /* One attempt per game-over transition; no repeated erase after errors. */
        if(g_game.game_over && !saved_game_over) {
            (void)game_flash_update_score(g_game.score);saved_game_over=1;
        }
        if(!g_game.game_over)saved_game_over=0;
#endif
        render_frame(g_now_ms);
    }
}
