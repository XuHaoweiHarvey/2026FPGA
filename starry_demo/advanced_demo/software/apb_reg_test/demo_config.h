#ifndef DEMO_CONFIG_H
#define DEMO_CONFIG_H

/* Edit these values, Build, then Debug the new ELF. Scene A shows this
 * rectangle. g_demo_mode=1 draws only this rectangle on black in both scenes;
 * g_demo_mode=2 runs the Front->Back BLIT demo; 3 compares ordinary and keyed
 * copies of a 128x128 robot against the same blue/green background; 4 runs the
 * finite timing benchmark (see docs/BENCHMARK.md). Units are pixels, color is
 * 0x00RRGGBB; hardware does not clip rectangles. */
#ifndef DEMO_MODE
#define DEMO_MODE 0u
#endif
/* Per geometry/operation: one warmup then eight timed commands by default.
 * These limits keep result arithmetic bounded; no display hold is used. */
#ifndef BENCHMARK_SAMPLES
#define BENCHMARK_SAMPLES 8u
#endif
#ifndef BENCHMARK_WARMUPS
#define BENCHMARK_WARMUPS 1u
#endif
#if BENCHMARK_SAMPLES < 1 || BENCHMARK_SAMPLES > 64
#error "BENCHMARK_SAMPLES must be in 1..64"
#endif
#if BENCHMARK_WARMUPS < 0 || BENCHMARK_WARMUPS > 8
#error "BENCHMARK_WARMUPS must be in 0..8"
#endif
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
/* RGB24 only; upper bits passed by callers are ignored by the API. */
#ifndef DEMO_COLOR_KEY_RGB
#define DEMO_COLOR_KEY_RGB UINT32_C(0x00FF00FF)
#endif
#endif
