#ifndef DEMO_CONFIG_H
#define DEMO_CONFIG_H

/* Edit these five values, Build, then Debug the new ELF. Scene A shows this
 * rectangle. g_demo_mode=1 draws only this rectangle on black in both scenes.
 * Units are pixels, color is 0x00RRGGBB; hardware does not clip rectangles. */
#ifndef TEST_RECT_X
#define TEST_RECT_X 240u
#endif
#ifndef TEST_RECT_Y
#define TEST_RECT_Y 180u
#endif
#ifndef TEST_RECT_W
#define TEST_RECT_W 360u
#endif
#ifndef TEST_RECT_H
#define TEST_RECT_H 240u
#endif
#ifndef TEST_RECT_COLOR
#define TEST_RECT_COLOR UINT32_C(0x00FF0000)
#endif
#define DEMO_BACKGROUND_A UINT32_C(0x00102060)
#define DEMO_BACKGROUND_B UINT32_C(0x001C140C)
#endif
