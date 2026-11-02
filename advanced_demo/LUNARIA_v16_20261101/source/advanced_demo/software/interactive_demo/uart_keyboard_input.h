#ifndef UART_KEYBOARD_INPUT_H
#define UART_KEYBOARD_INPUT_H

#include "soc.h"
#include "uart_keyboard_protocol.h"

#ifndef SYSTEM_UART_0_IO_CTRL
#error "UART0 is absent: regenerate Sapphire SoC and BSP before using keyboard input"
#endif

/* Offsets and FIFO occupancy fields match the generated standalone UART driver. */
#define UART_KEY_BAUD 115200u
#define UART_KEY_MAX_BYTES_PER_POLL 128u

#ifndef UART_KEY_READ32
static inline uint32_t uart_key_mmio_read(uintptr_t address) {
    return *(volatile uint32_t *)address;
}
#define UART_KEY_READ32(address) uart_key_mmio_read(address)
#endif
#ifndef UART_KEY_WRITE32
static inline void uart_key_mmio_write(uintptr_t address, uint32_t value) {
    *(volatile uint32_t *)address = value;
}
#define UART_KEY_WRITE32(address, value) uart_key_mmio_write(address, value)
#endif

typedef struct {
    uart_key_parser_t parser;
    uint8_t pressed;
    uint8_t released;
} uart_keyboard_input_t;

static inline void uart_keyboard_input_init(uart_keyboard_input_t *input) {
    const uintptr_t base = (uintptr_t)SYSTEM_UART_0_IO_CTRL;
    uart_key_parser_init(&input->parser);
    input->pressed = 0u;
    input->released = 0u;
    /* Disable FIFO interrupts; this adapter polls and does not install an ISR. */
    UART_KEY_WRITE32(base + 4u, 0u);
    UART_KEY_WRITE32(base + 8u, SYSTEM_CLINT_HZ / (UART_KEY_BAUD * 8u) - 1u);
    UART_KEY_WRITE32(base + 12u, 7u); /* 8 data bits, no parity, one stop bit */
}

static inline void uart_keyboard_record_edges(uart_keyboard_input_t *input,
                                               uint8_t before) {
    const uint8_t after = input->parser.buttons;
    input->pressed |= (uint8_t)(after & (uint8_t)~before);
    input->released |= (uint8_t)(before & (uint8_t)~after);
}

/* Bounded polling keeps a noisy UART from starving rendering. Edge bits remain
 * latched until consumed, including a tap fully contained in the UART FIFO. */
static inline unsigned uart_keyboard_input_poll(uart_keyboard_input_t *input,
                                                uint32_t now_ms) {
    const uintptr_t base = (uintptr_t)SYSTEM_UART_0_IO_CTRL;
    uint8_t before = input->parser.buttons;
    unsigned count = 0u;
    (void)uart_key_parser_tick(&input->parser, now_ms);
    uart_keyboard_record_edges(input, before);
    while (count < UART_KEY_MAX_BYTES_PER_POLL &&
           (UART_KEY_READ32(base + 4u) >> 24) != 0u) {
        before = input->parser.buttons;
        (void)uart_key_parser_feed(&input->parser,
            (uint8_t)UART_KEY_READ32(base), now_ms);
        uart_keyboard_record_edges(input, before);
        ++count;
    }
    return count;
}

static inline uint8_t uart_keyboard_input_take_pressed(uart_keyboard_input_t *input) {
    const uint8_t pressed = input->pressed;
    input->pressed = 0u;
    return pressed;
}

static inline uint8_t uart_keyboard_input_take_released(uart_keyboard_input_t *input) {
    const uint8_t released = input->released;
    input->released = 0u;
    return released;
}

/* Preserve a complete press/release that arrives between game frames. A
 * latched press is presented for one simulation step, while a held key stays
 * present through parser.buttons. */
static inline uint8_t uart_keyboard_input_consume_buttons(
    uart_keyboard_input_t *input) {
    const uint8_t buttons = (uint8_t)(input->parser.buttons | input->pressed);
    input->pressed = 0u;
    return buttons;
}

#endif
