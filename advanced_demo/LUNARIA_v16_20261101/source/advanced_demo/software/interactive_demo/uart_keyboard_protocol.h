#ifndef UART_KEYBOARD_PROTOCOL_H
#define UART_KEYBOARD_PROTOCOL_H

#include <stdint.h>

/* Wire format: A5 5A, version, sequence, button bitmap, CRC-8/ATM. */
#define UART_KEY_SYNC_0 UINT8_C(0xA5)
#define UART_KEY_SYNC_1 UINT8_C(0x5A)
#define UART_KEY_VERSION UINT8_C(1)
#define UART_KEY_FRAME_SIZE 6u
#define UART_KEY_TIMEOUT_MS UINT32_C(150)

#define UART_KEY_UP    UINT8_C(0x01)
#define UART_KEY_DOWN  UINT8_C(0x02)
#define UART_KEY_LEFT  UINT8_C(0x04)
#define UART_KEY_RIGHT UINT8_C(0x08)
#define UART_KEY_FIRE  UINT8_C(0x10)
#define UART_KEY_PAUSE UINT8_C(0x20)
#define UART_KEY_MASK  UINT8_C(0x3F)

typedef struct {
    uint8_t frame[UART_KEY_FRAME_SIZE];
    uint8_t used;
    uint8_t have_sequence;
    uint8_t active;
    uint8_t last_sequence;
    uint8_t buttons;
    uint32_t last_valid_ms;
    uint32_t accepted_frames;
    uint32_t bad_crc_frames;
    uint32_t bad_version_frames;
    uint32_t bad_flags_frames;
    uint32_t stale_frames;
    uint32_t timeout_releases;
} uart_key_parser_t;

static inline uint8_t uart_key_crc8(const uint8_t *data, uint8_t length) {
    uint8_t crc = 0;
    uint8_t i;
    for (i = 0; i < length; ++i) {
        uint8_t bit;
        crc ^= data[i];
        for (bit = 0; bit < 8; ++bit) {
            uint8_t shifted = (uint8_t)(crc << 1);
            if (crc & 0x80u) shifted ^= UINT8_C(0x07);
            crc = shifted;
        }
    }
    return crc;
}

static inline void uart_key_parser_init(uart_key_parser_t *parser) {
    uint8_t *p = (uint8_t *)parser;
    uint32_t i;
    for (i = 0; i < (uint32_t)sizeof(*parser); ++i) p[i] = 0;
}

static inline void uart_key_parser_resync(uart_key_parser_t *parser) {
    uint8_t i, j;
    /* A damaged frame may already contain the start of the next one. */
    for (i = 1u; i + 1u < UART_KEY_FRAME_SIZE; ++i) {
        if (parser->frame[i] == UART_KEY_SYNC_0 &&
            parser->frame[i + 1u] == UART_KEY_SYNC_1) {
            parser->used = (uint8_t)(UART_KEY_FRAME_SIZE - i);
            for (j = 0u; j < parser->used; ++j)
                parser->frame[j] = parser->frame[i + j];
            return;
        }
    }
    if (parser->frame[UART_KEY_FRAME_SIZE - 1u] == UART_KEY_SYNC_0) {
        parser->frame[0] = UART_KEY_SYNC_0;
        parser->used = 1;
    } else {
        parser->used = 0;
    }
}

/* Call even when no bytes arrive. Silence also permits a sender restart. */
static inline int uart_key_parser_tick(uart_key_parser_t *parser,
                                       uint32_t now_ms) {
    if (!parser->active ||
        (uint32_t)(now_ms - parser->last_valid_ms) < UART_KEY_TIMEOUT_MS)
        return 0;
    parser->buttons = 0u;
    parser->active = 0u;
    parser->have_sequence = 0u;
    parser->used = 0u;
    ++parser->timeout_releases;
    return 1;
}

/* Returns nonzero only when a new, valid key state has been accepted. */
static inline int uart_key_parser_feed(uart_key_parser_t *parser,
                                       uint8_t byte, uint32_t now_ms) {
    uint8_t sequence, distance;

    (void)uart_key_parser_tick(parser, now_ms);
    if (parser->used == 0u) {
        if (byte == UART_KEY_SYNC_0) {
            parser->frame[0] = byte;
            parser->used = 1u;
        }
        return 0;
    }
    if (parser->used == 1u) {
        if (byte == UART_KEY_SYNC_1) {
            parser->frame[1] = byte;
            parser->used = 2u;
        } else if (byte != UART_KEY_SYNC_0) {
            parser->used = 0u;
        }
        return 0;
    }

    parser->frame[parser->used++] = byte;
    if (parser->used != UART_KEY_FRAME_SIZE) return 0;

    if (parser->frame[2] != UART_KEY_VERSION) {
        ++parser->bad_version_frames;
        uart_key_parser_resync(parser);
        return 0;
    }
    if (uart_key_crc8(&parser->frame[2], 3u) != parser->frame[5]) {
        ++parser->bad_crc_frames;
        uart_key_parser_resync(parser);
        return 0;
    }
    if ((parser->frame[4] & (uint8_t)~UART_KEY_MASK) != 0u) {
        ++parser->bad_flags_frames;
        uart_key_parser_resync(parser);
        return 0;
    }

    sequence = parser->frame[3];
    if (parser->have_sequence) {
        distance = (uint8_t)(sequence - parser->last_sequence);
        if (distance == 0u || distance > 127u) {
            ++parser->stale_frames;
            uart_key_parser_resync(parser);
            return 0;
        }
    }

    parser->last_sequence = sequence;
    parser->have_sequence = 1u;
    parser->buttons = parser->frame[4];
    parser->last_valid_ms = now_ms;
    parser->active = 1u;
    ++parser->accepted_frames;
    parser->used = 0u;
    return 1;
}

#endif
