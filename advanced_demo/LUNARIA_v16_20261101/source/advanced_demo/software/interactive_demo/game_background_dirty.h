#ifndef GAME_BACKGROUND_DIRTY_H
#define GAME_BACKGROUND_DIRTY_H
#include <stdint.h>

/* Separate coverage per physical slot. Small tiles avoid restoring a 64x64
 * block for a moving 32x32 projectile. All rectangles remain DMA aligned. */
#define GAME_DIRTY_TILE 16u
#define GAME_DIRTY_COLS 120u
#define GAME_DIRTY_ROWS 68u
#define GAME_DIRTY_WORDS 4u
/* The blit engines write at most 32 128-bit beats per AXI transaction.
 * Four pixels fit in each beat, so avoid merging runs unless the combined
 * span needs fewer transactions than the separate spans. */
#define GAME_DIRTY_BURST_PIXELS 128u
#define GAME_DIRTY_BURST_TILES (GAME_DIRTY_BURST_PIXELS / GAME_DIRTY_TILE)
#define GAME_DIRTY_MERGE_GAP_TILES 1u
typedef struct { uint32_t rows[GAME_DIRTY_ROWS][GAME_DIRTY_WORDS]; uint8_t valid; } game_background_dirty_t;

static inline int game_background_bit(const game_background_dirty_t *dirty, uint32_t row, uint32_t col) {
    return (dirty->rows[row][col / 32u] & (UINT32_C(1) << (col % 32u))) != 0u;
}

static inline void game_background_mark(game_background_dirty_t *dirty,
                                        uint32_t x, uint32_t y, uint32_t w, uint32_t h) {
    uint32_t left, right, row, bottom, col;
    if (!w || !h || x >= 1920u || y >= 1080u) return;
    if (w > 1920u - x) w = 1920u - x;
    if (h > 1080u - y) h = 1080u - y;
    left = x / GAME_DIRTY_TILE; right = (x + w - 1u) / GAME_DIRTY_TILE;
    bottom = (y + h - 1u) / GAME_DIRTY_TILE;
    for (row = y / GAME_DIRTY_TILE; row <= bottom; ++row)
        for (col = left; col <= right; ++col)
            dirty->rows[row][col / 32u] |= UINT32_C(1) << (col % 32u);
}

#if GAME_PATH_DIAGNOSTICS
static inline uint32_t game_background_run_end(const game_background_dirty_t *dirty,
                                                uint32_t row, uint32_t first) {
    while (first < GAME_DIRTY_COLS && game_background_bit(dirty, row, first)) ++first;
    return first;
}

static inline uint32_t game_background_merge_runs(const game_background_dirty_t *dirty,
                                                   uint32_t row, uint32_t first,
                                                   uint32_t end) {
    for (;;) {
        uint32_t next = end, next_end, separate_bursts, merged_bursts;
        while (next < GAME_DIRTY_COLS && !game_background_bit(dirty, row, next) &&
               next - end < GAME_DIRTY_MERGE_GAP_TILES) ++next;
        if (next == GAME_DIRTY_COLS || !game_background_bit(dirty, row, next) ||
            next - end > GAME_DIRTY_MERGE_GAP_TILES) return end;
        next_end = game_background_run_end(dirty, row, next);
        separate_bursts = (end - first + GAME_DIRTY_BURST_TILES - 1u) / GAME_DIRTY_BURST_TILES +
                          (next_end - next + GAME_DIRTY_BURST_TILES - 1u) / GAME_DIRTY_BURST_TILES;
        merged_bursts = (next_end - first + GAME_DIRTY_BURST_TILES - 1u) / GAME_DIRTY_BURST_TILES;
        if (merged_bursts >= separate_bursts) return end;
        end = next_end;
    }
}

/* Consume a horizontal run, merging a one-tile gap only when that saves an
 * AXI burst; then coalesce the same span in later rows. Restoring extra
 * background pixels is safe and can avoid a separately throttled short write. */
static inline int game_background_next(game_background_dirty_t *dirty,
                                       uint32_t *x, uint32_t *y, uint32_t *w, uint32_t *h) {
    uint32_t row, first, last, end, col, word;
    for (row = 0u; row < GAME_DIRTY_ROWS; ++row) {
        for (word = 0u; word < GAME_DIRTY_WORDS; ++word) if (dirty->rows[row][word]) break;
        if (word == GAME_DIRTY_WORDS) continue;
        first = word * 32u;
        while (!game_background_bit(dirty, row, first)) ++first;
        last = game_background_run_end(dirty, row, first);
        last = game_background_merge_runs(dirty, row, first, last);
        end = row;
        do {
            for (col = first; col < last; ++col)
                dirty->rows[end][col / 32u] &= ~(UINT32_C(1) << (col % 32u));
            if (++end == GAME_DIRTY_ROWS) break;
            if (!game_background_bit(dirty, end, first)) break;
            col = game_background_merge_runs(dirty, end, first,
                game_background_run_end(dirty, end, first));
        } while (col == last);
        *x = first * GAME_DIRTY_TILE; *y = row * GAME_DIRTY_TILE; *w = (last - first) * GAME_DIRTY_TILE;
        *h = end * GAME_DIRTY_TILE > 1080u ? 1080u - *y : (end - row) * GAME_DIRTY_TILE;
        return 1;
    }
    return 0;
}
#else
/* Keep the compact legacy restoration path in low-footprint Flash builds. */
static inline int game_background_next(game_background_dirty_t *dirty,
                                       uint32_t *x, uint32_t *y, uint32_t *w, uint32_t *h) {
    uint32_t row, first, last, end, col, word;
    for (row = 0u; row < GAME_DIRTY_ROWS; ++row) {
        for (word = 0u; word < GAME_DIRTY_WORDS; ++word) if (dirty->rows[row][word]) break;
        if (word == GAME_DIRTY_WORDS) continue;
        first = word * 32u;
        while (!game_background_bit(dirty, row, first)) ++first;
        last = first;
        while (last < GAME_DIRTY_COLS && game_background_bit(dirty, row, last)) ++last;
        end = row;
        do {
            for (col = first; col < last; ++col)
                dirty->rows[end][col / 32u] &= ~(UINT32_C(1) << (col % 32u));
            if (++end == GAME_DIRTY_ROWS) break;
            for (col = first; col < last; ++col) if (!game_background_bit(dirty, end, col)) break;
        } while (col == last);
        *x = first * GAME_DIRTY_TILE; *y = row * GAME_DIRTY_TILE; *w = (last - first) * GAME_DIRTY_TILE;
        *h = end * GAME_DIRTY_TILE > 1080u ? 1080u - *y : (end - row) * GAME_DIRTY_TILE;
        return 1;
    }
    return 0;
}
#endif
#endif
