#ifndef GAME_PRESENTATION_H
#define GAME_PRESENTATION_H
#include <stdint.h>
#ifndef GAME_ALLOW_SCALE2
#define GAME_ALLOW_SCALE2 0
#endif
/* Optional symbol; no change to the original mailbox or runtime ABI. */
typedef struct {
    uint32_t magic,publication,scale,display_x,display_y,display_width,display_height;
    uint32_t showcase,state,boss_phase,boss_moving;
    uint32_t first_boundary,last_boundary,presentation_intervals,missing_boundaries,max_boundary_gap;
} game_presentation_t;
#if GAME_ALLOW_SCALE2
extern volatile game_presentation_t g_game_presentation;
#endif
#endif
