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
#define ACCEL_SWAP_COUNT 0x80u
#define ACCEL_READER_ERROR 0x78u
#define ACCEL_CAPABILITIES 0x40u
#define ACCEL_CAP_ALPHA (1u << 8)
#define ACCEL_CAP_COLOR_KEY (1u << 7)
#define FRAME_FRONT_VALID (1u << 4)
#define FRAME_WRITER_OWNED (1u << 5)

static inline uint32_t accel_read(uint32_t offset) { (void)offset; return 0u; }
static inline void accel_write(uint32_t offset, uint32_t value) { (void)offset; (void)value; }
static inline uint32_t accel_error(void) { return 0u; }
static inline uint32_t accel_init(void) { return 0u; }
static inline uint32_t display_wait_frames(uint32_t frames) { (void)frames; return 0u; }
static inline uint32_t accel_sprite_begin(void) { return 0u; }
static inline uint32_t accel_sprite_seal(void) { return 0u; }
static inline uint32_t accel_fill_rect(uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint32_t c) {
    (void)x; (void)y; (void)w; (void)h; (void)c; return 0u;
}
static inline uint32_t accel_wait_done(void) { return 0u; }
static inline uint32_t accel_color_key_blit(uint32_t s, uint32_t st, uint32_t x, uint32_t y,
                                             uint32_t w, uint32_t h, uint32_t c) {
    (void)s; (void)st; (void)x; (void)y; (void)w; (void)h; (void)c; return 0u;
}
static inline uint32_t accel_alpha_blend(uint32_t s, uint32_t st, uint32_t x, uint32_t y,
                                         uint32_t w, uint32_t h, uint32_t a) {
    (void)s; (void)st; (void)x; (void)y; (void)w; (void)h; (void)a; return 0u;
}
static inline uint32_t display_get_back_buffer(void) { return 0x800000u; }
static inline uint32_t display_get_front_buffer(void) { return 0u; }
static inline uint32_t display_swap_request(uint32_t *ticket) { *ticket = 1u; return 0u; }
static inline uint32_t display_wait_swap_done(uint32_t ticket) { (void)ticket; return 0u; }

#endif
