#include <stdint.h>
#include <stdio.h>
#include "../software/interactive_demo/uart_keyboard_protocol.h"

static unsigned failures;
#define CHECK(expr) do { if (!(expr)) { \
    printf("FAIL line %d: %s\n", __LINE__, #expr); ++failures; \
} } while (0)

static uint8_t *make_frame(uint8_t *frame, uint8_t sequence, uint8_t buttons) {
    frame[0] = UART_KEY_SYNC_0;
    frame[1] = UART_KEY_SYNC_1;
    frame[2] = UART_KEY_VERSION;
    frame[3] = sequence;
    frame[4] = buttons;
    frame[5] = uart_key_crc8(&frame[2], 3u);
    return frame;
}

static int send_frame(uart_key_parser_t *parser, const uint8_t *frame,
                      uint32_t now_ms) {
    unsigned i;
    int accepted = 0;
    for (i = 0; i < UART_KEY_FRAME_SIZE; ++i)
        accepted |= uart_key_parser_feed(parser, frame[i], now_ms);
    return accepted;
}

static int stream_recovery_checks(void) {
    uart_key_parser_t parser;
    uint8_t frame[UART_KEY_FRAME_SIZE];
    unsigned position, i, bit;
    for (position = 0; position < UART_KEY_FRAME_SIZE; ++position) {
        uart_key_parser_init(&parser);
        make_frame(frame, 10u, UART_KEY_LEFT);
        for (i = 0; i < UART_KEY_FRAME_SIZE; ++i)
            if (i != position)
                (void)uart_key_parser_feed(&parser, frame[i], 0u);
        CHECK(send_frame(&parser, make_frame(frame, 11u, UART_KEY_UP), 20u));
        CHECK(parser.buttons == UART_KEY_UP && parser.accepted_frames == 1u);
    }
    for (position = 0; position <= UART_KEY_FRAME_SIZE; ++position) {
        uart_key_parser_init(&parser);
        make_frame(frame, 10u, UART_KEY_LEFT);
        for (i = 0; i <= UART_KEY_FRAME_SIZE; ++i) {
            if (i == position)
                (void)uart_key_parser_feed(&parser, 0x7Eu, 0u);
            if (i < UART_KEY_FRAME_SIZE)
                (void)uart_key_parser_feed(&parser, frame[i], 0u);
        }
        CHECK(send_frame(&parser, make_frame(frame, 11u, UART_KEY_DOWN), 20u));
        CHECK(parser.buttons == UART_KEY_DOWN);
    }
    for (position = 0; position < UART_KEY_FRAME_SIZE; ++position) {
        for (bit = 0; bit < 8u; ++bit) {
            uart_key_parser_init(&parser);
            make_frame(frame, 10u, UART_KEY_LEFT);
            frame[position] ^= (uint8_t)(1u << bit);
            CHECK(!send_frame(&parser, frame, 0u));
            CHECK(send_frame(&parser, make_frame(frame, 11u, UART_KEY_RIGHT), 20u));
        }
    }
    return 0;
}

int main(void) {
    uart_key_parser_t parser;
    uint8_t frame[UART_KEY_FRAME_SIZE];
    const uint8_t garbage[] = {0u, UART_KEY_SYNC_0, UART_KEY_SYNC_0, 0x13u};
    unsigned i;

    CHECK(stream_recovery_checks() == 0);
    CHECK(uart_key_crc8((const uint8_t *)"123456789", 9u) == 0xF4u);
    uart_key_parser_init(&parser);
    make_frame(frame, 254u, UART_KEY_UP | UART_KEY_FIRE);
    CHECK(frame[0] == 0xA5u && frame[1] == 0x5Au && frame[5] == 0xDEu);
    for (i = 0; i < sizeof(garbage); ++i)
        (void)uart_key_parser_feed(&parser, garbage[i], 0u);
    CHECK(send_frame(&parser, make_frame(frame, 254u,
          UART_KEY_UP | UART_KEY_FIRE), 10u));
    CHECK(parser.buttons == (UART_KEY_UP | UART_KEY_FIRE));
    CHECK(parser.accepted_frames == 1u);

    CHECK(!send_frame(&parser, make_frame(frame, 254u, UART_KEY_DOWN), 20u));
    CHECK(parser.buttons == (UART_KEY_UP | UART_KEY_FIRE));
    CHECK(parser.stale_frames == 1u);
    CHECK(send_frame(&parser, make_frame(frame, 255u, UART_KEY_LEFT), 30u));
    CHECK(send_frame(&parser, make_frame(frame, 0u, UART_KEY_RIGHT), 40u));
    CHECK(parser.last_sequence == 0u);
    CHECK(!send_frame(&parser, make_frame(frame, 255u, UART_KEY_LEFT), 45u));
    CHECK(parser.stale_frames == 2u);

    make_frame(frame, 1u, UART_KEY_DOWN);
    frame[5] ^= 0x80u;
    CHECK(!send_frame(&parser, frame, 50u));
    CHECK(parser.bad_crc_frames == 1u);
    CHECK(send_frame(&parser, make_frame(frame, 1u, UART_KEY_DOWN), 60u));

    make_frame(frame, 2u, UART_KEY_UP);
    frame[2] = 9u;
    frame[5] = uart_key_crc8(&frame[2], 3u);
    CHECK(!send_frame(&parser, frame, 70u));
    CHECK(parser.bad_version_frames == 1u);

    make_frame(frame, 2u, 0x80u);
    CHECK(!send_frame(&parser, frame, 80u));
    CHECK(parser.bad_flags_frames == 1u);
    CHECK(parser.buttons == UART_KEY_DOWN);

    make_frame(frame, 2u, UART_KEY_PAUSE);
    for (i = 0; i < 3u; ++i)
        (void)uart_key_parser_feed(&parser, frame[i], 90u);
    for (i = 4u; i < UART_KEY_FRAME_SIZE; ++i)
        (void)uart_key_parser_feed(&parser, frame[i], 90u);
    CHECK(!parser.active || parser.buttons == UART_KEY_DOWN);
    CHECK(send_frame(&parser, make_frame(frame, 2u, UART_KEY_PAUSE), 100u));
    CHECK(parser.buttons == UART_KEY_PAUSE);

    CHECK(!uart_key_parser_tick(&parser, 249u));
    CHECK(uart_key_parser_tick(&parser, 250u));
    CHECK(parser.buttons == 0u && !parser.have_sequence);
    CHECK(parser.timeout_releases == 1u);
    CHECK(send_frame(&parser, make_frame(frame, 0u, UART_KEY_UP), 260u));
    CHECK(parser.buttons == UART_KEY_UP);

    uart_key_parser_init(&parser);
    make_frame(frame, 7u, UART_KEY_FIRE);
    for (i = 0; i < 4u; ++i)
        (void)uart_key_parser_feed(&parser, frame[i], 300u);
    make_frame(frame, 0u, UART_KEY_RIGHT);
    for (i = 0; i < UART_KEY_FRAME_SIZE; ++i)
        (void)uart_key_parser_feed(&parser, frame[i], 300u);
    CHECK(parser.accepted_frames == 1u && parser.buttons == UART_KEY_RIGHT);

    uart_key_parser_init(&parser);
    CHECK(send_frame(&parser, make_frame(frame, 9u, UART_KEY_LEFT),
                     UINT32_MAX - 50u));
    CHECK(!uart_key_parser_tick(&parser, 98u));
    CHECK(uart_key_parser_tick(&parser, 99u));

    uart_key_parser_init(&parser);
    CHECK(send_frame(&parser, make_frame(frame, 0u, UART_KEY_FIRE), 0u));
    CHECK(!send_frame(&parser, make_frame(frame, 128u, UART_KEY_DOWN), 1u));
    CHECK(send_frame(&parser, make_frame(frame, 127u, UART_KEY_LEFT), 2u));
    CHECK(!send_frame(&parser, frame, 151u));
    CHECK(parser.last_valid_ms == 2u); /* Replays cannot keep movement alive. */
    CHECK(send_frame(&parser, make_frame(frame, 0u, UART_KEY_UP), 152u));
    CHECK(parser.timeout_releases == 1u && parser.buttons == UART_KEY_UP);

    /* Exercise payload and CRC bytes equal to framing markers as well. */
    for (i = 0; i < 256u * 64u; ++i) {
        uart_key_parser_init(&parser);
        CHECK(send_frame(&parser, make_frame(frame, (uint8_t)(i >> 6),
                         (uint8_t)(i & 63u)), 0u));
        CHECK(parser.buttons == (i & 63u));
    }

    if (failures != 0u) return 1;
    printf("PASS UART key protocol: 16384 payloads, byte insertion/deletion, 48 bit faults, sequence/reconnect, timeout and clock wrap\n");
    return 0;
}
