#ifndef GAME_HUD_ATLAS_H
#define GAME_HUD_ATLAS_H
#include <stdint.h>

/* 40 glyphs * 16 pixels = one atlas row; three cached HUD colors. */
#define GAME_FONT_Y 224u
static inline uint32_t game_font_index(char ch) {
    if (ch >= 'A' && ch <= 'Z') return (uint32_t)(ch - 'A');
    if (ch >= '0' && ch <= '9') return 26u + (uint32_t)(ch - '0');
    if (ch == ':') return 36u;
    if (ch == '.') return 37u;
    if (ch == '/') return 38u;
    if (ch == '-') return 39u;
    return 40u;
}
static inline uint32_t game_font_pixel(uint32_t x, uint32_t y) {
    static const uint32_t colors[3] = {0x00f5f8ffu, 0x004bd9efu, 0x00ffd878u};
    uint32_t index = x / 16u, row = (y - GAME_FONT_Y) / 24u;
    uint32_t px = x % 16u, py = (y - GAME_FONT_Y) % 24u;
    char ch = index < 26u ? (char)('A' + index) :
        (index < 36u ? (char)('0' + index - 26u) : ":./-"[index - 36u]);
    if (px < 15u && py < 21u && (m1b_hud_row(ch, py / 3u) & (1u << (4u - px / 3u))))
        return colors[row];
    return UINT32_C(0x00ff00ff);
}
#endif
