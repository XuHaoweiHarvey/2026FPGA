/* High-load keyboard survival game for the v6 Alpha/Color Key engine. */
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
#include "uart_keyboard_input.h"

#if defined(__GNUC__) && !defined(SURVIVAL_GAME_HOST_SYNTAX)
#define GAME_NORETURN __attribute__((noinline, noreturn))
#define GAME_FENCE() __asm__ volatile("fence iorw,iorw" ::: "memory")
#define GAME_DISABLE_INTERRUPTS() __asm__ volatile("csrci mstatus,8" ::: "memory")
#define GAME_IDLE() __asm__ volatile("nop" ::: "memory")
#else
#define GAME_NORETURN
#define GAME_FENCE() ((void)0)
#define GAME_DISABLE_INTERRUPTS() ((void)0)
#define GAME_IDLE() ((void)0)
#endif

#if !defined(SYSTEM_DDR_BMB) || SYSTEM_DDR_BMB != 0x1000
#error "The game requires the verified uncached DDR alias"
#endif

#define VIEW_X 640u
#define VIEW_Y 300u
#define VIEW_W GAME_WORLD_WIDTH
#define VIEW_H GAME_WORLD_HEIGHT
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
    return *(volatile uint32_t *)address;
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

static void initialize_assets(void) {
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
        GAME_FENCE();
        for (i = 0; i < ASSET_COUNT; ++i) (void)asset_hash(i, 0);
        cpu_session_end();
        accel_write(ACCEL_ASSET_CONTROL, 2u);
        if (!(accel_read(ACCEL_ASSET_STATUS) & 2u)) fail(ERROR_ASSET);
    } else {
        cpu_session_begin();
        for (i = 0; i < ASSET_COUNT; ++i) (void)asset_hash(i, 0);
        cpu_session_end();
    }
    g_game_result.asset_status = accel_read(ACCEL_ASSET_STATUS);
}

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

static void initialize_sprite_atlas(void) {
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

static void issue_command(uint32_t result) {
    require(result);
    require(accel_wait_done());
    check_health();
    poll_keyboard();
}

static void initialize_display_background(void) {
    uint32_t i, ticket;
    /* TPG initializes only Front0. Clear each Back and present it so both
       double buffers start identical before the game draws its small viewport. */
    for (i = 0; i < 2u; ++i) {
        require(accel_fill_rect(0u, 0u, 1920u, 1080u, BACKGROUND));
        require(accel_wait_done());
        check_health();
        require(display_swap_request(&ticket));
        require(display_wait_swap_done(ticket));
        check_health();
    }
}

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
    uint32_t height, src;
    if (y < 0) y = 0;
    if ((uint32_t)y >= VIEW_H) return;
    height = VIEW_H - (uint32_t)y;
    if (height > size) height = size;
    src = SPRITE_PHYS + atlas_y * SPRITE_STRIDE + atlas_x * 4u;
    issue_command(accel_color_key_blit(src, SPRITE_STRIDE,
        VIEW_X + aligned_x(x), VIEW_Y + (uint32_t)y, size, height, COLOR_KEY));
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

    if (y < 0) {
        trim = (uint32_t)(-y);
        if (trim >= height) return;
        source_y += trim;
        height -= trim;
        dest_y = 0u;
    } else {
        dest_y = aligned_y(y);
    }
    if (dest_y >= VIEW_H) return;
    if (height > VIEW_H - dest_y) height = VIEW_H - dest_y;
    src = SPRITE_PHYS + source_y * SPRITE_STRIDE + source_x * 4u;
    issue_command(accel_alpha_blend(src, SPRITE_STRIDE,
        VIEW_X + dest_x, VIEW_Y + dest_y, width, height, alpha));
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

static void render_hud(uint32_t back, uint32_t now_ms) {
    char line[48];
    char *p;
    uint32_t score = g_game.score % 100000u;
    volatile uint32_t *dst = ddr(back);
    issue_command(accel_fill_rect(VIEW_X, VIEW_Y, VIEW_W, 64u, PANEL));
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
    cpu_session_end();
    (void)now_ms;
}

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
    g_debug_status.measurement_swaps = accel_read(ACCEL_SWAP_COUNT) - g_measure_swap_base;
    g_debug_status.measurement_underflows = accel_read(ACCEL_DISPLAY_UNDERFLOW_COUNT) - g_measure_underflow_base;
    g_debug_status.measurement_missed = accel_read(ACCEL_MISSED_BOUNDARY_COUNT) - g_measure_missed_base;
    if (g_rendered_sprites < g_debug_status.measurement_min_sprites)
        g_debug_status.measurement_min_sprites = g_rendered_sprites;
    if (g_rendered_sprites > g_debug_status.measurement_max_sprites)
        g_debug_status.measurement_max_sprites = g_rendered_sprites;
    ++g_measure_window_frames;
    if ((uint32_t)(now_ms-g_measure_window_ms) >= 1000u) {
        fps = (uint32_t)((uint64_t)g_measure_window_frames * 100000u / (now_ms-g_measure_window_ms));
        if (fps < g_debug_status.measurement_min_fps_x100)
            g_debug_status.measurement_min_fps_x100 = fps;
        g_measure_window_ms = now_ms;
        g_measure_window_frames = 0u;
    }
    if (elapsed >= 60000u) g_debug_status.measurement_state = 2u;
}

static void render_frame(uint32_t now_ms) {
    uint32_t i, back = display_get_back_buffer(), front = display_get_front_buffer(), ticket;
    if (back == front || (back != 0u && back != UINT32_C(0x00800000)) ||
        (front != 0u && front != UINT32_C(0x00800000))) fail(ERROR_RENDER);

    g_rendered_sprites = 0u;
    issue_command(accel_fill_rect(VIEW_X, VIEW_Y, VIEW_W, VIEW_H, BACKGROUND));
    for (i = 0; i < GAME_EFFECT_LIMIT; ++i) {
        const game_effect_t *effect = &g_game.effects[i];
        if (effect->active && (int32_t)(effect->expires_ms - now_ms) > 0)
            draw_alpha_sprite(0u, 0u, effect->x - 16, effect->y - 16, 64u, 210u);
    }
    for (i = 0; i < GAME_ENEMY_LIMIT; ++i) {
        const game_enemy_t *enemy = &g_game.enemies[i];
        if (enemy->active) draw_key_sprite(96u, 0u, enemy->x, enemy->y, 32u);
    }
    for (i = 0; i < GAME_BULLET_LIMIT; ++i) {
        const game_bullet_t *bullet = &g_game.bullets[i];
        if (bullet->active) draw_alpha_sprite(128u, 0u, bullet->x, bullet->y, 16u, g_projectile_alpha);
    }
    for (i = 0; i < GAME_ENEMY_BULLET_LIMIT; ++i) {
        const game_enemy_bullet_t *bullet = &g_game.enemy_bullets[i];
        /* Reuse the orange glow tile so sealed v6 atlases remain compatible. */
        if (bullet->active) draw_alpha_sprite(24u, 24u, bullet->x, bullet->y, 16u, g_projectile_alpha);
    }
    if (!g_game.game_over) {
        draw_alpha_sprite(0u, 0u, g_game.player_x - 16, g_game.player_y - 16, 64u,
                          g_game.invulnerable ? 110u : 150u);
        draw_key_sprite(64u, 0u, g_game.player_x, g_game.player_y, GAME_PLAYER_SIZE);
    }
    update_metrics(now_ms);
    render_hud(back, now_ms);
    require(display_swap_request(&ticket));
    require(display_wait_swap_done(ticket));
    measure_frame(milliseconds());
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
    g_test_page = 0u;
    g_fps_window_ms = now_ms;
    g_fps_window_frames = 0u;
}

static uint32_t alpha_reference(uint32_t src, uint32_t dst, uint32_t alpha) {
    uint32_t a = ((src >> 24) * alpha + 127u) / 255u;
    uint32_t r = (((src >> 16) & 255u) * a + ((dst >> 16) & 255u) * (255u-a) + 127u) / 255u;
    uint32_t g = (((src >> 8) & 255u) * a + ((dst >> 8) & 255u) * (255u-a) + 127u) / 255u;
    uint32_t b = ((src & 255u) * a + (dst & 255u) * (255u-a) + 127u) / 255u;
    return (dst & UINT32_C(0xff000000)) | (r << 16) | (g << 8) | b;
}

static void run_self_test(void) {
    uint32_t back = display_get_back_buffer(), ticket, x, y, failed = 0u;
    const uint32_t color = UINT32_C(0xa52b4671);
    volatile uint32_t *dst = ddr(back);
    g_game_result.phase = GAME_DEBUG_PHASE_TESTING;
    g_debug_status.self_test_result = 0u;
    publish_status();
    if ((back != 0u && back != UINT32_C(0x00800000)) ||
        back == display_get_front_buffer()) fail(ERROR_RENDER);
    issue_command(accel_fill_rect(VIEW_X, VIEW_Y, VIEW_W, VIEW_H, color));
    cpu_session_begin();
    for (y = 0; y < 16u; ++y) for (x = 0; x < 16u; ++x)
        if (dst[(VIEW_Y+y)*1920u+VIEW_X+x] != color) failed |= 1u;
    cpu_session_end();
    issue_command(accel_color_key_blit(SPRITE_PHYS+64u*4u, SPRITE_STRIDE,
        VIEW_X, VIEW_Y, 32u, 32u, COLOR_KEY));
    cpu_session_begin();
    for (y = 0; y < 32u; ++y) for (x = 0; x < 32u; ++x) {
        uint32_t src = atlas_pixel(64u+x, y);
        uint32_t expected = (src & UINT32_C(0xffffff)) == COLOR_KEY ? color : src;
        if (dst[(VIEW_Y+y)*1920u+VIEW_X+x] != expected) failed |= 2u;
    }
    cpu_session_end();
    issue_command(accel_alpha_blend(SPRITE_PHYS+128u*4u, SPRITE_STRIDE,
        VIEW_X+64u, VIEW_Y, 16u, 16u, g_projectile_alpha));
    cpu_session_begin();
    for (y = 0; y < 16u; ++y) for (x = 0; x < 16u; ++x)
        if (dst[(VIEW_Y+y)*1920u+VIEW_X+64u+x] !=
            alpha_reference(atlas_pixel(128u+x,y), color, g_projectile_alpha)) failed |= 4u;
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
    } else if (command == GAME_DEBUG_CMD_RESTART || command == GAME_DEBUG_CMD_ENTER_GAME) {
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
    } else if (command == GAME_DEBUG_CMD_MEASURE_60S && !g_test_page && !g_game.paused &&
               !g_game.game_over && g_game.invincible_mode) {
        g_measure_start = milliseconds();
        g_measure_window_ms = g_measure_start;
        g_measure_window_frames = 0u;
        g_measure_swap_base = accel_read(ACCEL_SWAP_COUNT);
        g_measure_underflow_base = accel_read(ACCEL_DISPLAY_UNDERFLOW_COUNT);
        g_measure_missed_base = accel_read(ACCEL_MISSED_BOUNDARY_COUNT);
        g_debug_status.measurement_state = 1u;
        g_debug_status.measurement_elapsed_ms = 0u;
        g_debug_status.measurement_frames = 0u;
        g_debug_status.measurement_swaps = 0u;
        g_debug_status.measurement_underflows = 0u;
        g_debug_status.measurement_missed = 0u;
        g_debug_status.measurement_min_fps_x100 = UINT32_MAX;
        g_debug_status.measurement_min_sprites = UINT32_MAX;
        g_debug_status.measurement_max_sprites = 0u;
    } else if (command != GAME_DEBUG_CMD_NONE) {
        g_debug_status.command_result = UINT32_C(0xed03);
    }
    GAME_FENCE();
    g_debug_status.acknowledged_sequence = sequence;
    publish_status();
}

int main(void) {
    uint32_t now_ms;
    GAME_DISABLE_INTERRUPTS();
    g_game_result.magic = UINT32_C(0x53555256);
    g_game_result.phase = PHASE_STARTUP;
    uart_keyboard_input_init(&g_keyboard);
    g_debug_control.magic = GAME_DEBUG_CONTROL_MAGIC;
    g_debug_control.auto_restart_ms = 3000u;
    g_debug_control.enemy_fire_interval_ms = 900u;
    g_debug_control.enemy_limit = GAME_ENEMY_LIMIT;
    g_debug_control.projectile_alpha = 225u;
    publish_status();
    require(accel_init());
    if (!(accel_read(ACCEL_CPU_DDR_STATUS) & 16u) ||
        !(accel_read(ACCEL_CAPABILITIES) & ACCEL_CAP_ALPHA) ||
        !(accel_read(ACCEL_CAPABILITIES) & ACCEL_CAP_COLOR_KEY)) fail(ERROR_RENDER);
    require(display_wait_frames(3u));
    g_underflow_base = accel_read(ACCEL_DISPLAY_UNDERFLOW_COUNT);
    g_missed_base = accel_read(ACCEL_MISSED_BOUNDARY_COUNT);
    initialize_display_background();
    g_command_base = accel_read(ACCEL_COMMAND_COUNT);
    g_swap_base = accel_read(ACCEL_SWAP_COUNT);
    initialize_assets();
    initialize_sprite_atlas();

    now_ms = milliseconds();
    restart_game(now_ms);
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
        survival_game_step(&g_game, buttons, g_now_ms);
        render_frame(g_now_ms);
    }
}
