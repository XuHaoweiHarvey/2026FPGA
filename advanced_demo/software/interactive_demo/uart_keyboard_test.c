#include <stdint.h>
#include "uart_keyboard_input.h"
#include "../apb_reg_test/benchmark_clock.h"

enum { UART_KEY_TEST_READY = 1u, UART_KEY_TEST_RUNNING = 2u };

typedef struct {
    uint32_t magic;
    uint32_t phase;
    uint32_t poll_count;
    uint32_t accepted_frames;
    uint32_t bad_crc_frames;
    uint32_t bad_version_frames;
    uint32_t bad_flags_frames;
    uint32_t stale_frames;
    uint32_t timeout_releases;
    uint32_t buttons;
    uint32_t last_sequence;
    uint32_t last_valid_ms;
    uint32_t pressed;
    uint32_t released;
} uart_keyboard_result_t;

volatile uart_keyboard_result_t g_uart_keyboard_result;

static uart_keyboard_input_t g_input;

static uint32_t read_mmio32(uintptr_t address) {
    return *(volatile uint32_t *)address;
}

static uint32_t milliseconds_now(void) {
    uint64_t ticks = benchmark_clock_read(read_mmio32);
    return (uint32_t)(ticks / (SYSTEM_CLINT_HZ / 1000u));
}

int main(void) {
    uint32_t now;

    g_uart_keyboard_result.phase = UART_KEY_TEST_READY;
    uart_keyboard_input_init(&g_input);
    g_uart_keyboard_result.magic = UINT32_C(0x55415254);
    g_uart_keyboard_result.phase = UART_KEY_TEST_RUNNING;

    for (;;) {
        now = milliseconds_now();
        (void)uart_keyboard_input_poll(&g_input, now);
        g_uart_keyboard_result.timeout_releases = g_input.parser.timeout_releases;
        g_uart_keyboard_result.buttons = g_input.parser.buttons;
        g_uart_keyboard_result.last_sequence = g_input.parser.last_sequence;
        g_uart_keyboard_result.last_valid_ms = g_input.parser.last_valid_ms;
        g_uart_keyboard_result.accepted_frames = g_input.parser.accepted_frames;
        g_uart_keyboard_result.bad_crc_frames = g_input.parser.bad_crc_frames;
        g_uart_keyboard_result.bad_version_frames = g_input.parser.bad_version_frames;
        g_uart_keyboard_result.bad_flags_frames = g_input.parser.bad_flags_frames;
        g_uart_keyboard_result.stale_frames = g_input.parser.stale_frames;
        g_uart_keyboard_result.pressed |= uart_keyboard_input_take_pressed(&g_input);
        g_uart_keyboard_result.released |= uart_keyboard_input_take_released(&g_input);
        ++g_uart_keyboard_result.poll_count;
    }
}
