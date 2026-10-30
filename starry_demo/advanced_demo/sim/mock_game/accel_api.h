#ifndef MOCK_GAME_ACCEL_API_H
#define MOCK_GAME_ACCEL_API_H
#include <stdint.h>

#define ACCEL_POLL_LIMIT 100u
#define ACCEL_CPU_DDR_STATUS 0xD0u
#define ACCEL_CPU_DDR_ERROR 0xD4u
#define ACCEL_CPU_DDR_CONTROL 0xCCu
#define ACCEL_SPRITE_STATUS 0xE4u
#define ACCEL_ASSET_STATUS 0xDCu
#define ACCEL_ASSET_CONTROL 0xD8u
#define ACCEL_DISPLAY_UNDERFLOW_COUNT 0xA4u
#define ACCEL_MISSED_BOUNDARY_COUNT 0x84u
#define ACCEL_COMMAND_COUNT 0x5Cu
#define ACCEL_WRITER_THROTTLE_CYCLES 0x8Cu
#define ACCEL_WRITER_BURSTS 0x90u
#define ACCEL_READER_AR_STALL_CYCLES 0x94u
#define ACCEL_READER_R_STALL_CYCLES 0x9Cu
#define ACCEL_SWAP_COUNT 0x80u
#define ACCEL_BOUNDARY_COUNT 0x7Cu
#define ACCEL_READER_ERROR 0x78u
#define ACCEL_CAPABILITIES 0x40u
#define ACCEL_CAP_ALPHA (1u << 8)
#define ACCEL_CAP_FULLSCREEN_BACKGROUND (1u << 9)
#define ACCEL_CAP_COMMAND_QUEUE (1u << 10)
#define ACCEL_CAP_DISPLAY_WINDOW (1u << 11)
#define ACCEL_CAP_DISPLAY_SCALE2 (1u << 14)
#define ACCEL_CAP_COLOR_KEY (1u << 7)
#define FRAME_FRONT_VALID (1u << 4)
#define FRAME_WRITER_OWNED (1u << 5)
#define FRAME_SWAP_PENDING (1u << 2)
#define ACCEL_STATUS 0x0cu
#define ACCEL_BUFFER_STATUS 0x64u
#define ACCEL_BUSY 1u

static uint32_t mock_game_fullscreen_fills, mock_game_swaps;
static uint32_t mock_game_display_op_count, mock_game_display_ops[4];
static uint32_t mock_game_fill_result, mock_game_swap_result;
static uint32_t mock_game_keys, mock_game_alphas, mock_game_sprite_x, mock_game_sprite_y;
static uint32_t mock_game_sprite_w, mock_game_sprite_h;

static inline uint32_t accel_read(uint32_t offset) {
#ifdef MOCK_GAME_REG_READ
    return MOCK_GAME_REG_READ(offset);
#else
    (void)offset; return 0u;
#endif
}
static inline void accel_write(uint32_t offset, uint32_t value) { (void)offset; (void)value; }
static inline uint32_t accel_error(void) { return 0u; }
static inline uint32_t accel_init(void) { return 0u; }
static inline uint32_t accel_command_batch_begin(void) { return 0u; }
static inline uint32_t accel_command_batch_end(void) { return 0u; }
static inline uint32_t display_wait_frames(uint32_t frames) { (void)frames; return 0u; }
static inline uint32_t accel_sprite_begin(void) { return 0u; }
static inline uint32_t accel_sprite_seal(void) { return 0u; }
static inline uint32_t accel_fill_rect(uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint32_t c) {
#ifdef MOCK_GAME_DRAW
    MOCK_GAME_DRAW(0u, 0u, 0u, x, y, w, h, c);
#endif
    if (x == 0u && y == 0u && w == 1920u && h == 1080u && c == 0x0007101cu)
        ++mock_game_fullscreen_fills;
    if (mock_game_display_op_count < 4u)
        mock_game_display_ops[mock_game_display_op_count++] = 1u;
    return mock_game_fill_result;
}
static inline uint32_t accel_wait_done(void) { return 0u; }
static uint32_t mock_game_blits, mock_game_blit_source, mock_game_blit_x, mock_game_blit_y;
static uint32_t mock_game_blit_width, mock_game_blit_height;
static inline uint32_t accel_blit(uint32_t s, uint32_t st, uint32_t x, uint32_t y,
                                uint32_t w, uint32_t h) {
#ifdef MOCK_GAME_DRAW
    MOCK_GAME_DRAW(1u, s, st, x, y, w, h, 0u);
#endif
    if (mock_game_display_op_count < 4u)
        mock_game_display_ops[mock_game_display_op_count++] = 3u;
    (void)st; ++mock_game_blits; mock_game_blit_source = s;
    mock_game_blit_x = x; mock_game_blit_y = y;
    mock_game_blit_width = w; mock_game_blit_height = h;
    return 0u;
}
static inline uint32_t accel_color_key_blit(uint32_t s, uint32_t st, uint32_t x, uint32_t y,
                                             uint32_t w, uint32_t h, uint32_t c) {
#ifdef MOCK_GAME_DRAW
    MOCK_GAME_DRAW(2u, s, st, x, y, w, h, c);
#endif
    (void)s; (void)st; (void)c; ++mock_game_keys;
    mock_game_sprite_x = x; mock_game_sprite_y = y;
    mock_game_sprite_w = w; mock_game_sprite_h = h; return 0u;
}
static inline uint32_t accel_alpha_blend(uint32_t s, uint32_t st, uint32_t x, uint32_t y,
                                         uint32_t w, uint32_t h, uint32_t a) {
#ifdef MOCK_GAME_DRAW
    MOCK_GAME_DRAW(3u, s, st, x, y, w, h, a);
#endif
    (void)s; (void)st; (void)a; ++mock_game_alphas;
    mock_game_sprite_x = x; mock_game_sprite_y = y;
    mock_game_sprite_w = w; mock_game_sprite_h = h; return 0u;
}
static inline uint32_t display_get_back_buffer(void) {
#ifdef MOCK_GAME_BACK_BUFFER
    return MOCK_GAME_BACK_BUFFER;
#else
    return 0x800000u;
#endif
}
static inline uint32_t display_get_front_buffer(void) { return display_get_back_buffer() ^ 0x800000u; }
static inline uint32_t display_swap_request(uint32_t *ticket) {
    *ticket = ++mock_game_swaps;
    if (mock_game_display_op_count < 4u)
        mock_game_display_ops[mock_game_display_op_count++] = 2u;
    return mock_game_swap_result;
}
static inline uint32_t display_wait_swap_done(uint32_t ticket) { (void)ticket; return 0u; }

#endif
