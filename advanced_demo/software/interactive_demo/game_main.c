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
#include "uart_keyboard_input.h"
#ifndef GAME_FLASH_ENABLE
#define GAME_FLASH_ENABLE 1
#endif
#if GAME_FLASH_ENABLE
#include "../flash/game_flash.h"
#endif

#if defined(__GNUC__)
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
static survival_game_t g_game;
static uart_keyboard_input_t g_keyboard;
static uint32_t g_underflow_base, g_missed_base, g_command_base, g_swap_base;
static uint32_t g_now_ms;
static uint32_t g_fps_window_ms, g_fps_window_frames;

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
    for (;;) GAME_IDLE();
}

static void fail(uint32_t error) {
    g_game_result.error = error;
    g_game_result.phase = PHASE_FAILED;
    g_game_result.sprite_status = accel_read(ACCEL_SPRITE_STATUS);
    g_game_result.asset_status = accel_read(ACCEL_ASSET_STATUS);
    g_game_result.underflow_delta = accel_read(ACCEL_DISPLAY_UNDERFLOW_COUNT) - g_underflow_base;
    g_game_result.missed_delta = accel_read(ACCEL_MISSED_BOUNDARY_COUNT) - g_missed_base;
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

#if !GAME_FLASH_ENABLE
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
    for (y = 0; y < 480u; ++y) for (x = 0; x < 640u; ++x) {
        pixel = write_pixels ? asset_pixel(image, x, y) : base[y * 640u + x];
        if (write_pixels) base[y * 640u + x] = pixel;
        else if (pixel != asset_pixel(image, x, y)) fail(ERROR_ASSET);
        hash = (hash ^ pixel) * UINT32_C(16777619);
    }
    return hash;
}

static void initialize_assets(void) {
    uint32_t i, status = accel_read(ACCEL_ASSET_STATUS);
    g_game_result.phase = PHASE_ASSETS;
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
    if (!(status & UINT32_C(0x80000000))) fail(ERROR_SPRITE);
    if (!(status & 2u)) {
        require(accel_sprite_begin());
        cpu_session_begin();
        for (y = 0; y < 480u; ++y) for (x = 0; x < 640u; ++x) {
            pixel = atlas_pixel(x, y);
            dst[y * 640u + x] = pixel;
            hash = (hash ^ pixel) * UINT32_C(16777619);
        }
        GAME_FENCE();
        for (y = 0; y < 480u; ++y) for (x = 0; x < 640u; ++x)
            if (dst[y * 640u + x] != atlas_pixel(x, y)) fail(ERROR_SPRITE);
        cpu_session_end();
        require(accel_sprite_seal());
    } else {
        cpu_session_begin();
        for (y = 0; y < 480u; ++y) for (x = 0; x < 640u; ++x) {
            pixel = dst[y * 640u + x];
            if (pixel != atlas_pixel(x, y)) fail(ERROR_SPRITE);
            hash = (hash ^ pixel) * UINT32_C(16777619);
        }
        cpu_session_end();
    }
    (void)hash;
    g_game_result.sprite_status = accel_read(ACCEL_SPRITE_STATUS);
}

#else
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
        if(rc) fail(ERROR_ASSET);
        crc=flash_crc32(crc,flash_line,sizeof(flash_line));
        for(x=0;x<640;x++) {
            if(write_pixels) dst[y*640+x]=flash_line[x];
            else if(dst[y*640+x]!=flash_line[x]) fail(ERROR_ASSET);
        }
    }
    GAME_FENCE();
    for(y=0;y<480;y++) for(x=0;x<640;x++) {
        flash_put32(bytes,dst[y*640+x]);
        readback=flash_crc32(readback,bytes,4);
    }
    cpu_session_end();
    g_flash_result.asset_crc=crc;
    if(crc!=game_flash_expected_crc(index) || readback!=crc) {
        g_flash_result.error=FLASH_CRC;fail(ERROR_ASSET);
    }
}
static void initialize_assets(void) {
    uint32_t i,status=accel_read(ACCEL_ASSET_STATUS);
    int write_pixels=!(status&2u);
    g_game_result.phase=PHASE_ASSETS;
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
static void initialize_sprite_atlas(void) {
    uint32_t status=accel_read(ACCEL_SPRITE_STATUS);
    g_game_result.phase=PHASE_SPRITES;
    if(!(status&0x80000000u))fail(ERROR_SPRITE);
    if(!(status&2u))require(accel_sprite_begin());
    flash_load_window(3,SPRITE_PHYS,!(status&2u));
    if(!(status&2u))require(accel_sprite_seal());
    g_game_result.sprite_status=accel_read(ACCEL_SPRITE_STATUS);
}
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

static void issue_command(uint32_t result) {
    require(result);
    require(accel_wait_done());
    check_health();
    poll_keyboard();
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
    p = line; p = append(p, "SURVIVAL SCORE:"); p = append_u32(p, score, 5u);
    p = append(p, " HP:"); p = append_u32(p, g_game.lives, 2u); *p = 0;
    m1b_hud_text(dst, VIEW_X + 12u, VIEW_Y + 7u, line, UINT32_C(0x00f5f8ff));
    if (g_game.paused || g_game.game_over) {
        const char *status = g_game.game_over ? "GAME OVER FIRE TO RESTART" : "PAUSED P TO CONTINUE";
        m1b_hud_text(dst, VIEW_X + 12u, VIEW_Y + 34u, status, UINT32_C(0x00ffd878));
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

static void update_metrics(uint32_t now_ms) {
    uint32_t active = survival_game_sprite_count(&g_game, now_ms);
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

static void render_frame(uint32_t now_ms) {
    uint32_t i, back = display_get_back_buffer(), front = display_get_front_buffer(), ticket;
    if (back == front || (back != 0u && back != UINT32_C(0x00800000)) ||
        (front != 0u && front != UINT32_C(0x00800000))) fail(ERROR_RENDER);

#if GAME_FLASH_ENABLE
    issue_command(accel_blit(ASSET_BASE+((g_game.score/1000u)%3u)*ASSET_BYTES,
                            2560u,VIEW_X,VIEW_Y,VIEW_W,VIEW_H));
#else
    issue_command(accel_fill_rect(VIEW_X, VIEW_Y, VIEW_W, VIEW_H, BACKGROUND));
#endif
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
        if (bullet->active) draw_alpha_sprite(128u, 0u, bullet->x, bullet->y, 16u, 225u);
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
    ++g_game_result.frame;
    ++g_fps_window_frames;
    g_game_result.score = g_game.score;
    g_game_result.lives = g_game.lives;
    g_game_result.player_x = (uint32_t)g_game.player_x;
    g_game_result.player_y = (uint32_t)g_game.player_y;
    g_game_result.command_delta = accel_read(ACCEL_COMMAND_COUNT) - g_command_base;
    g_game_result.swap_delta = accel_read(ACCEL_SWAP_COUNT) - g_swap_base;
    check_health();
    g_game_result.phase = PHASE_PLAYING;
}

int main(void) {
    uint32_t now_ms;
#if GAME_FLASH_ENABLE
    uint32_t saved_game_over=0;
#endif
    GAME_DISABLE_INTERRUPTS();
    g_game_result.magic = UINT32_C(0x53555256);
    g_game_result.phase = PHASE_STARTUP;
    require(accel_init());
    if (!(accel_read(ACCEL_CPU_DDR_STATUS) & 16u) ||
        !(accel_read(ACCEL_CAPABILITIES) & ACCEL_CAP_ALPHA) ||
        !(accel_read(ACCEL_CAPABILITIES) & ACCEL_CAP_COLOR_KEY)) fail(ERROR_RENDER);
    require(display_wait_frames(3u));
    g_underflow_base = accel_read(ACCEL_DISPLAY_UNDERFLOW_COUNT);
    g_missed_base = accel_read(ACCEL_MISSED_BOUNDARY_COUNT);
    g_command_base = accel_read(ACCEL_COMMAND_COUNT);
    g_swap_base = accel_read(ACCEL_SWAP_COUNT);
#if GAME_FLASH_ENABLE
    if(game_flash_begin())fail(ERROR_ASSET);
#endif
    initialize_assets();
    initialize_sprite_atlas();

    uart_keyboard_input_init(&g_keyboard);
    now_ms = milliseconds();
    survival_game_reset(&g_game, now_ms);
    g_now_ms = now_ms;
    g_fps_window_ms = now_ms;
    g_game_result.phase = PHASE_PLAYING;
    for (;;) {
        uint8_t buttons;
        poll_keyboard();
        buttons = uart_keyboard_input_consume_buttons(&g_keyboard);
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
