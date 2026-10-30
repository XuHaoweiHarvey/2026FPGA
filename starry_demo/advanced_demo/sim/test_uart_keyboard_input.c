#include <stdint.h>
#include <stdio.h>
#include "soc.h"
#include "../software/interactive_demo/uart_keyboard_protocol.h"

#define CHECK(expr) do { if (!(expr)) { \
    printf("FAIL line %d: %s\n", __LINE__, #expr); return 1; \
} } while (0)

static uint8_t fifo[128];
static unsigned fifo_read, fifo_write;
static uint32_t write_addr[3], write_value[3];
static unsigned writes;
static int continuous_noise;

static uint32_t mock_read(uintptr_t address) {
    if (continuous_noise && address == SYSTEM_UART_0_IO_CTRL + 4u)
        return UINT32_C(0x01000000);
    if (continuous_noise && address == SYSTEM_UART_0_IO_CTRL)
        return 0u;
    if (address == SYSTEM_UART_0_IO_CTRL + 4u)
        return (uint32_t)(fifo_write - fifo_read) << 24;
    if (address == SYSTEM_UART_0_IO_CTRL)
        return fifo[fifo_read++];
    return 0u;
}

static void mock_write(uintptr_t address, uint32_t value) {
    if (writes < 3u) {
        write_addr[writes] = (uint32_t)address;
        write_value[writes] = value;
    }
    ++writes;
}

#define UART_KEY_READ32(address) mock_read(address)
#define UART_KEY_WRITE32(address, value) mock_write((address), (value))
#include "../software/interactive_demo/uart_keyboard_input.h"

static void queue_frame(uint8_t sequence, uint8_t buttons) {
    uint8_t frame[UART_KEY_FRAME_SIZE];
    unsigned i;
    frame[0] = UART_KEY_SYNC_0;
    frame[1] = UART_KEY_SYNC_1;
    frame[2] = UART_KEY_VERSION;
    frame[3] = sequence;
    frame[4] = buttons;
    frame[5] = uart_key_crc8(&frame[2], 3u);
    for (i = 0; i < UART_KEY_FRAME_SIZE; ++i)
        fifo[fifo_write++] = frame[i];
}

int main(void) {
    uart_keyboard_input_t input;
    unsigned drained;

    uart_keyboard_input_init(&input);
    CHECK(writes == 3u);
    CHECK(write_addr[0] == SYSTEM_UART_0_IO_CTRL + 4u && write_value[0] == 0u);
    CHECK(write_addr[1] == SYSTEM_UART_0_IO_CTRL + 8u && write_value[1] == 107u);
    CHECK(write_addr[2] == SYSTEM_UART_0_IO_CTRL + 12u && write_value[2] == 7u);

    queue_frame(0u, UART_KEY_UP);
    drained = uart_keyboard_input_poll(&input, 10u);
    CHECK(drained == UART_KEY_FRAME_SIZE && input.parser.buttons == UART_KEY_UP);
    CHECK(uart_keyboard_input_take_pressed(&input) == UART_KEY_UP);
    CHECK(uart_keyboard_input_take_released(&input) == 0u);

    queue_frame(1u, 0u);
    queue_frame(2u, UART_KEY_FIRE);
    queue_frame(3u, 0u);
    drained = uart_keyboard_input_poll(&input, 20u);
    CHECK(drained == 3u * UART_KEY_FRAME_SIZE && input.parser.buttons == 0u);
    CHECK(uart_keyboard_input_consume_buttons(&input) == UART_KEY_FIRE);
    CHECK(uart_keyboard_input_consume_buttons(&input) == 0u);
    CHECK(uart_keyboard_input_take_pressed(&input) == 0u);
    CHECK(uart_keyboard_input_take_released(&input) == (UART_KEY_UP | UART_KEY_FIRE));

    queue_frame(4u, UART_KEY_LEFT);
    CHECK(uart_keyboard_input_poll(&input, 30u) == UART_KEY_FRAME_SIZE);
    CHECK(input.parser.buttons == UART_KEY_LEFT);
    CHECK(uart_keyboard_input_poll(&input, 179u) == 0u);
    CHECK(input.parser.buttons == UART_KEY_LEFT);
    CHECK(uart_keyboard_input_poll(&input, 180u) == 0u);
    CHECK(input.parser.buttons == 0u && input.parser.timeout_releases == 1u);
    CHECK(uart_keyboard_input_take_released(&input) == UART_KEY_LEFT);

    continuous_noise = 1;
    CHECK(uart_keyboard_input_poll(&input, 200u) == UART_KEY_MAX_BYTES_PER_POLL);
    CHECK(input.parser.buttons == 0u);

    printf("PASS UART input adapter: register setup, bounded FIFO drain, state/edge latch and timeout release\n");
    return 0;
}
