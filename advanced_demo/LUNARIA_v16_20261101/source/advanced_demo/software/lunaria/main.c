#include "../apb_reg_test/accel_api.h"
#include "../apb_reg_test/benchmark_clock.h"
#include "../interactive_demo/game_debug_abi.h"
#include "../interactive_demo/game_presentation.h"
#include "../interactive_demo/game_runtime.h"
#include "../interactive_demo/uart_keyboard_input.h"
#include "lunaria_asset_ids.h"
#include "lunaria_render.h"
#include "lunaria_pool.h"
#include "lunaria_upload.h"
#include <stdint.h>
#define FENCE() __asm__ volatile("fence iorw,iorw" ::: "memory")
volatile game_debug_control_t g_debug_control;
volatile game_debug_status_t g_debug_status, g_debug_first_fault;
volatile game_runtime_t g_game_runtime;
volatile game_presentation_t g_game_presentation;
volatile uint32_t g_game_measurement_complete;
volatile ln_upload_t g_lunaria_upload;
volatile uint32_t g_lunaria_chunk[LN_UPLOAD_WORDS] __attribute__((aligned(16)));
const volatile uint32_t g_game_required_caps = 0x10E00;
const volatile uint32_t g_game_beam_compatible = GAME_ALLOW_BEAM ? 0x10000 : 0;
const volatile uint32_t g_game_alpha_hardware_compatible = 0x3000;
const volatile uint32_t g_game_scale2_compatible = 0x4000;
const volatile uint32_t g_game_showcase_available = 1;
const volatile uint32_t g_lunaria_available = 1;
const volatile uint32_t g_lunaria_v14_compatible = 0x20000;
const volatile uint32_t g_lunaria_v16_compatible = 0x80000;
const volatile uint32_t g_lunaria_v15_compatible = 0x40000;
const volatile uint32_t g_lunaria_v12_compatible =
    (GAME_ALLOW_SCALE2 && GAME_ALLOW_WIDE_CACHE) ? ACCEL_CAP_ALPHA_WIDE_CACHE : 0;
const volatile uint32_t g_lunaria_asset_hashes[2] = {LN_BACKGROUND_HASH,
                                                     LN_ATLAS_HASH};
const volatile game_build_config_t g_game_build_config = {
    GAME_BUILD_CONFIG_MAGIC,
    1,
    0,
    640,
    300,
    640,
    480,
    1,
    0,
    0,
    1,
    1, /* submission timing enabled */
    1,
    1,
    LN_CAPACITY,
    1920,
    1080};
static lunaria_t game;
/* Optional, independent extension: original debug mailboxes keep their ABI.
 * Odd publication means an in-progress snapshot. Peaks reset with a campaign.
 */
volatile uint32_t g_lunaria_metrics[9] = {0x4c4e4d31u, 1u, 0u};
/* Same frame, microseconds: logic+page flush, submit/backpressure, drain, swap. */
volatile uint32_t g_lunaria_timing[7] = {0x4c4e5431u, 1u, 0u};
/* Independent request mailbox. The host commits sequence last; firmware
 * changes settings between frames and commits acknowledgement last. */
volatile ln_settings_t g_lunaria_settings = {
    LN_SETTINGS_MAGIC, 1u, 0u, 0u, 0u, LN_DEFAULT_LIMIT, 0u,
    LN_DEFAULT_LIMIT, 0u, LN_MIN_LIMIT, LN_CAPACITY};
static uart_keyboard_input_t keyboard;
static uint32_t alpha = 255, fps_ms, fps_frames, command_base, swap_base,
                underflow_base, missed_base;
static uint32_t previous_boundary, measurement_ms, measure_frames, measure_swap,
    measure_bound;
static uint32_t measure_command, measure_underflow, measure_missed,
    measure_window_ms, measure_window_frames, measure_first_boundary;
static uint32_t rendering;
static uint32_t active_sprites(void) { return game.current_elements; }
static uint32_t read32(uintptr_t a) { return *(volatile uint32_t *)a; }
static uint64_t ticks(void) { return benchmark_clock_read(read32); }
static uint32_t ms(void) {
  return (uint32_t)(ticks() / (SYSTEM_CLINT_HZ / 1000u));
}
/* Share the 64-bit clock conversion across the five timing boundaries. */
static __attribute__((noinline)) uint32_t us_delta(uint64_t start) {
  return (uint32_t)((ticks() - start) / (SYSTEM_CLINT_HZ / 1000000u));
}
static uint32_t fnv(uint32_t h, uint32_t word) {
  return (h ^ word) * UINT32_C(16777619);
}
static volatile uint32_t *ddr(uint32_t physical) {
  return (volatile uint32_t *)(uintptr_t)(physical + 0x1000u);
}
static void publish(void) {
  uint32_t p = g_debug_status.publication;
  g_debug_status.publication = p | 1u;
  FENCE();
  g_debug_status.magic = GAME_DEBUG_STATUS_MAGIC;
  g_debug_status.version = 1;
  g_debug_status.frame = game.frames;
  g_debug_status.score = game.score;
  g_debug_status.lives = game.lives;
  g_debug_status.active_sprites = active_sprites();
  g_debug_status.max_active_sprites = game.peak_elements;
  g_lunaria_metrics[2]++;
  FENCE();
  g_lunaria_metrics[3] = game.fps_x100;
  g_lunaria_metrics[4] = game.current_visible;
  g_lunaria_metrics[5] = game.peak_visible_bullets;
  g_lunaria_metrics[6] = game.current_elements;
  g_lunaria_metrics[7] = game.peak_elements;
  g_lunaria_metrics[8] = game.deferred_emissions;
  FENCE();
  g_lunaria_metrics[2]++;
  g_debug_status.buttons = keyboard.parser.buttons;
  g_debug_status.player_x = (uint32_t)(game.player_x / LN_Q);
  g_debug_status.player_y = (uint32_t)(game.player_y / LN_Q);
  g_debug_status.invincible_mode = game.invincible;
  g_debug_status.enemy_limit = 1;
  g_debug_status.wave = game.phase + 1u;
  g_debug_status.dropped_ms = game.dropped_ms;
  g_debug_status.uart_accepted = keyboard.parser.accepted_frames;
  g_debug_status.uart_bad_crc = keyboard.parser.bad_crc_frames;
  g_debug_status.uart_bad_version = keyboard.parser.bad_version_frames;
  g_debug_status.uart_bad_flags = keyboard.parser.bad_flags_frames;
  g_debug_status.uart_stale = keyboard.parser.stale_frames;
  g_debug_status.uart_timeout_releases = keyboard.parser.timeout_releases;
  g_debug_status.raw_commands = accel_read(ACCEL_COMMAND_COUNT);
  g_debug_status.raw_swaps = accel_read(ACCEL_SWAP_COUNT);
  g_debug_status.raw_underflows = accel_read(ACCEL_DISPLAY_UNDERFLOW_COUNT);
  g_debug_status.raw_missed = accel_read(ACCEL_MISSED_BOUNDARY_COUNT);
  g_debug_status.command_delta = g_debug_status.raw_commands - command_base;
  g_debug_status.swap_delta = g_debug_status.raw_swaps - swap_base;
  g_debug_status.underflow_delta =
      g_debug_status.raw_underflows - underflow_base;
  g_debug_status.missed_delta = g_debug_status.raw_missed - missed_base;
  g_debug_status.hardware_error = accel_read(ACCEL_ERROR_CODE);
  g_debug_status.reader_error = accel_read(ACCEL_READER_ERROR);
  g_debug_status.cpu_ddr_error = accel_read(ACCEL_CPU_DDR_ERROR);
  g_debug_status.cpu_ddr_status = accel_read(ACCEL_CPU_DDR_STATUS);
  g_debug_status.sprite_status = accel_read(ACCEL_SPRITE_STATUS);
  g_debug_status.asset_status = accel_read(ACCEL_ASSET_STATUS);
  g_debug_status.buffer_status = accel_read(ACCEL_BUFFER_STATUS);
  g_debug_status.front_base = display_get_front_buffer();
  g_debug_status.back_base = display_get_back_buffer();
  g_game_runtime.publication++;
  FENCE();
  g_game_runtime.campaign_stage =
      game.state == LN_TITLE ? 255u : game.phase + 1u;
  g_game_runtime.campaign_result = game.state == LN_VICTORY   ? 1u
                                   : game.state == LN_FAILURE ? 2u
                                                              : 0u;
  g_game_runtime.boss_hp = ln_boss_hp(&game);
  FENCE();
  g_game_runtime.publication++;
  FENCE();
  g_debug_status.publication = (p + 2u) & ~1u;
}
static void fail(uint32_t e) {
  g_debug_status.error = e;
  g_debug_status.phase = 255;
  g_lunaria_upload.magic = LN_UPLOAD_MAGIC;
  g_lunaria_upload.version = 1;
  g_lunaria_upload.error = e;
  FENCE();
  g_lunaria_upload.state = LN_UPLOAD_FAULT;
  publish();
  g_debug_first_fault = g_debug_status;
  for (;;) {
  }
}
static void require(uint32_t e) {
  if (e)
    fail(e);
}
static void health(void) {
  if (accel_error() || accel_read(ACCEL_READER_ERROR) ||
      accel_read(ACCEL_CPU_DDR_ERROR) ||
      (accel_read(ACCEL_CPU_DDR_STATUS) & 4u))
    fail(0xEE01);
  if (accel_read(ACCEL_DISPLAY_UNDERFLOW_COUNT) != underflow_base ||
      accel_read(ACCEL_MISSED_BOUNDARY_COUNT) != missed_base)
    fail(0xEE02);
}
static void session_begin(void) {
  uint32_t i;
  if (accel_read(ACCEL_CPU_DDR_STATUS) & 7u)
    fail(0xEE03);
  accel_write(ACCEL_CPU_DDR_CONTROL, 1);
  for (i = 0; i < ACCEL_POLL_LIMIT; i++) {
    uint32_t s = accel_read(ACCEL_CPU_DDR_STATUS);
    if (s & 4u)
      fail(0xEE03);
    if (s & 1u)
      return;
  }
  fail(0xEE03);
}
static void session_end(void) {
  uint32_t i;
  FENCE();
  for (i = 0; i < ACCEL_POLL_LIMIT; i++)
    if (!(accel_read(ACCEL_CPU_DDR_STATUS) & 2u))
      break;
  if (i == ACCEL_POLL_LIMIT || accel_read(ACCEL_CPU_DDR_ERROR))
    fail(0xEE04);
  accel_write(ACCEL_CPU_DDR_CONTROL, 2);
  for (i = 0; i < ACCEL_POLL_LIMIT; i++)
    if (!(accel_read(ACCEL_CPU_DDR_STATUS) & 1u))
      return;
  fail(0xEE04);
}
/* Draw queues and CPU DDR sessions never overlap. Every page switch during
 * rendering drains the previous batch, then starts a fresh counted batch. */
void ln_pool_io_begin(void) {
  if (rendering) require(accel_command_batch_end());
  session_begin();
}
void ln_pool_io_end(void) {
  session_end();
  if (rendering) require(accel_command_batch_begin());
}
uint32_t ln_pool_io_back(void) {
  uint32_t base = display_get_back_buffer();
  if (base != 0 && base != LN_POOL_SLOT1) fail(0xEE05);
  return base;
}
uint32_t ln_pool_io_read(uint32_t physical) { return *ddr(physical); }
void ln_pool_io_write(uint32_t physical, uint32_t word) { *ddr(physical) = word; }
static volatile uint32_t *asset_word(uint32_t window, uint32_t n) {
  if (window)
    return ddr(LN_SPRITE_BASE) + n;
  return ddr(LN_BACKGROUND_BASE) + (300u + n / 640u) * 1920u + 640u + n % 640u;
}
static void upload(void) {
  uint32_t window = 0, offset = 0, total_hash = UINT32_C(2166136261), i;
  g_lunaria_upload.magic = LN_UPLOAD_MAGIC;
  g_lunaria_upload.version = 1;
  g_debug_status.phase = 2;
  if ((accel_read(ACCEL_ASSET_STATUS) & 2u) &&
      (accel_read(ACCEL_SPRITE_STATUS) & 2u)) {
    session_begin();
    for (window = 0; window < 2; window++) {
      total_hash = UINT32_C(2166136261);
      for (i = 0; i < LN_ASSET_WORDS; i++)
        total_hash = fnv(total_hash, *asset_word(window, i));
      if (total_hash != g_lunaria_asset_hashes[window])
        fail(0xEA08);
    }
    session_end();
    g_lunaria_upload.received_background = LN_ASSET_WORDS;
    g_lunaria_upload.received_atlas = LN_ASSET_WORDS;
    g_lunaria_upload.background_hash = LN_BACKGROUND_HASH;
    g_lunaria_upload.atlas_hash = LN_ATLAS_HASH;
    FENCE();
    g_lunaria_upload.state = LN_UPLOAD_READY;
    return;
  }
  if ((accel_read(ACCEL_ASSET_STATUS) | accel_read(ACCEL_SPRITE_STATUS)) & 3u)
    fail(0xEA01);
  accel_write(ACCEL_ASSET_CONTROL, 1);
  if (!(accel_read(ACCEL_ASSET_STATUS) & 1u))
    fail(0xEA02);
  g_lunaria_upload.state = LN_UPLOAD_WAIT;
  publish();
  while (window < 2u) {
    uint32_t sequence = g_lunaria_upload.sequence, count,
             hash = UINT32_C(2166136261), actual = UINT32_C(2166136261);
    if (sequence == g_lunaria_upload.ack)
      continue;
    FENCE();
    g_lunaria_upload.state = LN_UPLOAD_PROCESS;
    count = g_lunaria_upload.count;
    if (sequence != g_lunaria_upload.ack + 1u ||
        g_lunaria_upload.window != window ||
        g_lunaria_upload.offset != offset || !count ||
        count > LN_UPLOAD_WORDS || count > LN_ASSET_WORDS - offset)
      fail(0xEA03);
    for (i = 0; i < count; i++)
      hash = fnv(hash, g_lunaria_chunk[i]);
    if (hash != g_lunaria_upload.expected_hash)
      fail(0xEA04);
    session_begin();
    for (i = 0; i < count; i++)
      *asset_word(window, offset + i) = g_lunaria_chunk[i];
    FENCE();
    for (i = 0; i < count; i++) {
      uint32_t value = *asset_word(window, offset + i);
      actual = fnv(actual, value);
      total_hash = fnv(total_hash, value);
    }
    session_end();
    if (actual != hash)
      fail(0xEA05);
    offset += count;
    g_lunaria_upload.actual_hash = actual;
    if (window)
      g_lunaria_upload.received_atlas = offset;
    else
      g_lunaria_upload.received_background = offset;
    if (offset == LN_ASSET_WORDS) {
      if (total_hash != g_lunaria_asset_hashes[window])
        fail(0xEA06);
      if (!window) {
        g_lunaria_upload.background_hash = total_hash;
        accel_write(ACCEL_ASSET_CONTROL, 2);
        if (!(accel_read(ACCEL_ASSET_STATUS) & 2u))
          fail(0xEA07);
        require(accel_sprite_begin());
      } else {
        g_lunaria_upload.atlas_hash = total_hash;
        require(accel_sprite_seal());
      }
      window++;
      offset = 0;
      total_hash = UINT32_C(2166136261);
    }
    health();
    g_lunaria_upload.state = window == 2u ? LN_UPLOAD_READY : LN_UPLOAD_WAIT;
    FENCE();
    g_lunaria_upload.ack = sequence;
  }
}
static uint32_t submit(void *context, const ln_command_t *c) {
  (void)context;
  return accel_submit(c->op, c->src, c->stride, c->x, c->y, c->w, c->h,
                      c->color);
}
static void settings_command(void) {
  uint32_t seq = g_lunaria_settings.sequence;
  if (seq == g_lunaria_settings.ack)
    return;
  FENCE();
  g_lunaria_settings.result = 0;
  if (g_debug_status.measurement_state == 1u)
    g_lunaria_settings.result = 0xED04;
  else if (!ln_configure(&game, g_lunaria_settings.requested_limit,
                         g_lunaria_settings.requested_spin))
    g_lunaria_settings.result = 0xED10;
  g_lunaria_settings.limit = game.bullet_limit;
  g_lunaria_settings.spin = game.spin_patterns;
  FENCE();
  g_lunaria_settings.ack = seq;
}
static void debug_command(uint32_t now) {
  uint32_t seq = g_debug_control.sequence, c;
  if (seq == g_debug_status.acknowledged_sequence)
    return;
  FENCE();
  c = g_debug_control.command;
  g_debug_status.command_result = 0;
  if (g_debug_status.measurement_state == 1u && c)
    g_debug_status.command_result = 0xED04;
  else if (c == 1 || c == 6 || c == 10)
    ln_begin(&game);
  else if (c == 2 || c == 3) {
    game.paused = (uint8_t)(c == 2);
    game.last_ms = now;
    game.accumulator_ms = 0;
  } else if (c == 4) {
    game.invincible = (uint8_t)(g_debug_control.flags & 1u);
    alpha = g_debug_control.projectile_alpha > 255u
                ? 255u
                : g_debug_control.projectile_alpha;
  } else if (c == 7 && game.invincible && !game.paused &&
             game.state == LN_FIGHT) {
    uint32_t i;
    for (i = 0; i < LN_SHOTS; i++)
      game.shots[i].active = 0;
    measurement_ms = now;
    measure_frames = game.frames;
    measure_swap = accel_read(ACCEL_SWAP_COUNT);
    measure_bound = accel_read(ACCEL_BOUNDARY_COUNT);
    measure_command = accel_read(ACCEL_COMMAND_COUNT);
    measure_underflow = accel_read(ACCEL_DISPLAY_UNDERFLOW_COUNT);
    measure_missed = accel_read(ACCEL_MISSED_BOUNDARY_COUNT);
    measure_window_ms = now;
    measure_window_frames = game.frames;
    measure_first_boundary = 0;
    g_debug_status.measurement_state = 1;
    g_debug_status.measurement_elapsed_ms = 0;
    g_debug_status.measurement_frames = 0;
    g_debug_status.measurement_swaps = 0;
    g_debug_status.measurement_min_fps_x100 = UINT32_MAX;
    g_debug_status.measurement_min_sprites = UINT32_MAX;
    g_debug_status.measurement_max_sprites = 0;
    g_debug_status.measurement_underflows = 0;
    g_debug_status.measurement_missed = 0;
    g_game_measurement_complete = 0;
    g_game_runtime.measurement_max_render_us = 0;
    g_game_runtime.measurement_max_frame_us = 0;
    g_game_runtime.measurement_over_budget_frames = 0;
    g_game_runtime.measurement_command_submit_us = 0;
    g_game_runtime.measurement_command_wait_us = 0;
    g_game_runtime.measurement_path_diagnostics = 2;
    g_game_presentation.first_boundary = 0;
    g_game_presentation.last_boundary = 0;
    g_game_presentation.presentation_intervals = 0;
    g_game_presentation.missing_boundaries = 0;
    g_game_presentation.max_boundary_gap = 0;
  } else if (c)
    g_debug_status.command_result = 0xED03;
  FENCE();
  g_debug_status.acknowledged_sequence = seq;
}
int main(void) {
  uint32_t i, ticket, now;
  __asm__ volatile("csrw mie,zero\ncsrci mstatus,8" ::: "memory");
  g_debug_status.magic = GAME_DEBUG_STATUS_MAGIC;
  g_debug_status.version = 1;
  g_debug_status.phase = 1;
  g_debug_control.magic = GAME_DEBUG_CONTROL_MAGIC;
  g_debug_control.projectile_alpha = 255;
  g_debug_control.enemy_limit = 1;
  g_game_runtime.magic = GAME_RUNTIME_MAGIC;
  g_game_presentation.magic = 0x47505231;
  uart_keyboard_input_init(&keyboard);
  require(accel_init());
  if ((accel_read(ACCEL_CAPABILITIES) & g_game_required_caps) !=
      g_game_required_caps)
    fail(0xEE00);
  g_game_presentation.scale =
      (accel_read(ACCEL_CAPABILITIES) & 0x4000u) ? 2u : 1u;
  g_game_presentation.display_x = g_game_presentation.scale == 2 ? 320 : 640;
  g_game_presentation.display_y = g_game_presentation.scale == 2 ? 60 : 300;
  g_game_presentation.display_width = 640u * g_game_presentation.scale;
  g_game_presentation.display_height = 480u * g_game_presentation.scale;
  require(display_wait_frames(3));
  underflow_base = accel_read(ACCEL_DISPLAY_UNDERFLOW_COUNT);
  missed_base = accel_read(ACCEL_MISSED_BOUNDARY_COUNT);
  for (i = 0; i < 2; i++) {
    require(accel_fill_rect(640, 300, 640, 480, 0x00070719));
    require(accel_wait_done());
    require(display_swap_request(&ticket));
    require(display_wait_swap_done(ticket));
  }
  upload();
  now = ms();
  ln_reset(&game, now);
  fps_ms = now;
  command_base = accel_read(ACCEL_COMMAND_COUNT);
  swap_base = accel_read(ACCEL_SWAP_COUNT);
  for (;;) {
    uint64_t start = ticks(), render_start, part_start;
    ln_render_stats_t stats;
    uint32_t render_us, frame_us, boundary, buttons, update_us, submit_us, drain_us, swap_us;
    now = ms();
    uart_keyboard_input_poll(&keyboard, now);
    debug_command(now);
    settings_command();
    buttons = uart_keyboard_input_consume_buttons(&keyboard);
    if (g_debug_status.measurement_state == 1u)
      buttons &= ~(UART_KEY_PAUSE | UART_KEY_FIRE);
    /* Preserve every simulation frame at high density, even if presentation
     * is slow. The desktop viewer uses this same 16 ms step per drawn frame. */
    part_start = ticks();
    ln_step(&game, (uint8_t)buttons, game.last_ms + LN_TICK_MS);
    ln_pool_flush();
    update_us = us_delta(part_start);
    render_start = ticks();
    require(accel_command_batch_begin());
    rendering = 1;
    require(ln_render(&game, alpha, submit, 0, &stats));
    submit_us = us_delta(render_start);
    part_start = ticks();
    require(accel_command_batch_end());
    drain_us = us_delta(part_start);
    rendering = 0;
    render_us = us_delta(render_start);
    health();
    part_start = ticks();
    require(display_swap_request(&ticket));
    require(display_wait_swap_done(ticket));
    swap_us = us_delta(part_start);
    health();
    game.frames++;
    boundary = accel_read(ACCEL_BOUNDARY_COUNT);
    g_game_presentation.publication++;
    FENCE();
    g_game_presentation.showcase = 1;
    g_game_presentation.state = game.state;
    g_game_presentation.boss_phase = game.phase + 1u;
    g_game_presentation.boss_moving =
        game.state == LN_FIGHT && (game.phase < 3u || game.phase > 5u);
    if (g_debug_status.measurement_state != 2u &&
        (g_debug_status.measurement_state != 1u || measure_first_boundary)) {
      if (previous_boundary) {
        uint32_t gap = boundary - previous_boundary;
        g_game_presentation.presentation_intervals++;
        if (gap > g_game_presentation.max_boundary_gap)
          g_game_presentation.max_boundary_gap = gap;
        if (gap > 1u)
          g_game_presentation.missing_boundaries += gap - 1u;
      } else
        g_game_presentation.first_boundary = boundary;
    } else if (g_debug_status.measurement_state == 1u) {
      measure_first_boundary = 1;
      g_game_presentation.first_boundary = boundary;
    }
    previous_boundary = boundary;
    if (g_debug_status.measurement_state != 2u)
      g_game_presentation.last_boundary = boundary;
    FENCE();
    g_game_presentation.publication++;
    frame_us = us_delta(start);
    g_game_runtime.publication++;
    FENCE();
    g_game_runtime.render_us = render_us;
    g_game_runtime.frame_us = frame_us;
    g_game_runtime.command_submit_us = submit_us;
    g_game_runtime.command_wait_us = drain_us;
    g_lunaria_timing[2]++;
    FENCE();
    g_lunaria_timing[3]=update_us;g_lunaria_timing[4]=submit_us;
    g_lunaria_timing[5]=drain_us;g_lunaria_timing[6]=swap_us;
    FENCE();
    g_lunaria_timing[2]++;
    if (render_us > g_game_runtime.max_render_us)
      g_game_runtime.max_render_us = render_us;
    if (frame_us > g_game_runtime.max_frame_us)
      g_game_runtime.max_frame_us = frame_us;
    if (render_us > 16667u)
      g_game_runtime.over_budget_frames++;
    g_game_runtime.background_pixels = stats.background_pixels;
    g_game_runtime.background_rectangles = 1;
    g_game_runtime.sprite_pixels = stats.sprite_pixels;
    g_game_runtime.glyph_blits = stats.glyphs;
    if (g_debug_status.measurement_state == 1u) {
      uint32_t elapsed = ms() - measurement_ms;
      g_game_runtime.measurement_command_submit_us += submit_us;
      g_game_runtime.measurement_command_wait_us += drain_us;
      g_debug_status.measurement_elapsed_ms = elapsed;
      g_debug_status.measurement_frames = game.frames - measure_frames;
      g_debug_status.measurement_swaps =
          accel_read(ACCEL_SWAP_COUNT) - measure_swap;
      if (render_us > g_game_runtime.measurement_max_render_us)
        g_game_runtime.measurement_max_render_us = render_us;
      if (frame_us > g_game_runtime.measurement_max_frame_us)
        g_game_runtime.measurement_max_frame_us = frame_us;
      g_game_runtime.measurement_commands =
          accel_read(ACCEL_COMMAND_COUNT) - measure_command;
      g_debug_status.measurement_underflows =
          accel_read(ACCEL_DISPLAY_UNDERFLOW_COUNT) - measure_underflow;
      g_debug_status.measurement_missed =
          accel_read(ACCEL_MISSED_BOUNDARY_COUNT) - measure_missed;
      {
        uint32_t n = active_sprites(), t = ms();
        if (n < g_debug_status.measurement_min_sprites)
          g_debug_status.measurement_min_sprites = n;
        if (n > g_debug_status.measurement_max_sprites)
          g_debug_status.measurement_max_sprites = n;
        if (t - measure_window_ms >= 1000u) {
          uint32_t fps = (game.frames - measure_window_frames) * 100000u /
                         (t - measure_window_ms);
          if (fps < g_debug_status.measurement_min_fps_x100)
            g_debug_status.measurement_min_fps_x100 = fps;
          measure_window_ms = t;
          measure_window_frames = game.frames;
        }
      }
      if (render_us > 16667u)
        g_game_runtime.measurement_over_budget_frames++;
      g_game_runtime.measurement_display_frames = boundary - measure_bound;
      g_game_runtime.measurement_repeated_frames =
          g_game_runtime.measurement_display_frames >
                  g_debug_status.measurement_frames
              ? g_game_runtime.measurement_display_frames -
                    g_debug_status.measurement_frames
              : 0;
      if (elapsed >= 60000u) {
        g_debug_status.measurement_state = 2;
        FENCE();
        g_game_measurement_complete = 1;
      }
    }
    FENCE();
    g_game_runtime.publication++;
    fps_frames++;
    /* Count completed presents against wall time, including the swap wait. */
    now = ms();
    if (now - fps_ms >= 1000u) {
      game.fps_x100 = fps_frames * 100000u / (now - fps_ms);
      g_debug_status.fps_x100 = game.fps_x100;
      fps_ms = now;
      fps_frames = 0;
    }
    g_debug_status.phase = game.paused                ? 5u
                           : game.state == LN_FAILURE ? 6u
                                                      : 4u;
    publish();
  }
}
