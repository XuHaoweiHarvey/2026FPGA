/* Execute the production accel_init body against deterministic APB registers.
 * The runner copies the body verbatim; MMIO reads are the only replacement.
 * This does not model DDR timing, HDMI, or the remainder of main(). */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "accel_regs.h"

static uint32_t registers[64];
static unsigned checks, reads;
static uint32_t accel_read(uint32_t offset) {
    if ((offset & 3u) || offset / 4u >= 64u) abort();
    ++reads;
    return registers[offset / 4u];
}
#define REG(offset) registers[(offset) / 4u]
#include "accel_init_under_test.h"

static void expect(uint32_t expected, const char *name) {
    uint32_t actual = accel_init();
    ++checks;
    if (actual != expected) {
        fprintf(stderr, "%s: expected %04x, got %04x (window=%d scale=%d wide=%d)\n",
                name, (unsigned)expected, (unsigned)actual,
                GAME_DISPLAY_WINDOW, GAME_ALLOW_SCALE2, GAME_ALLOW_WIDE_CACHE);
        exit(1);
    }
    if (actual && (accel_cached_capabilities_valid || accel_cached_command_count_valid)) abort();
    if (!actual && (!accel_cached_capabilities_valid || !accel_cached_command_count_valid ||
                    accel_cached_command_count != 37u)) abort();
}

static void setup(uint32_t version, uint32_t caps) {
    memset(registers, 0, sizeof(registers));
    REG(ACCEL_ID) = ACCEL_ID_EXPECTED;
    REG(ACCEL_VERSION) = version;
    REG(ACCEL_CAPABILITIES) = caps;
    REG(ACCEL_STATUS) = ACCEL_INIT_DONE | ACCEL_DONE | ACCEL_COMMAND_QUEUE_READY;
    REG(ACCEL_BUFFER_STATUS) = FRAME_FRONT_VALID;
    REG(ACCEL_WIDTH) = 1920; REG(ACCEL_HEIGHT) = 1080; REG(ACCEL_STRIDE) = 7680;
    REG(ACCEL_SERVICE_READ_QUOTA) = 128;
    REG(ACCEL_SERVICE_WATERMARKS) = 0x02000180;
    REG(ACCEL_SERVICE_STATUS) = (1u << 5) | (1u << 6);
    REG(ACCEL_COMMAND_COUNT) = 37;
    /* Verify a failed reinitialization invalidates cached state as well. */
    accel_cached_capabilities_valid = accel_cached_command_count_valid = 1;
    reads = 0;
}

int main(void) {
    unsigned i;
    const uint32_t versions[] = {0x60000,0x70000,0x80000,0x90000,0xa0000,0xb0000,0xc0000,0xd0000,0xe0000,0xf0000,0x100000};
    const uint32_t caps[] = {0x1fb,0x7fb,0xffb,0x1ffb,0x3ffb,0x7ffb,0xfffb,0x1fffb,0x3fffb,0x7fffb,0xffffb};
    uint32_t version = GAME_DISPLAY_WINDOW ? 0xa0000 : 0x70000;
    uint32_t features = GAME_DISPLAY_WINDOW ? 0x3ffb : 0x7fb;
    for (i = 0; i < 11; ++i) {
        int allowed = GAME_DISPLAY_WINDOW ?
            (i >= 2 && (i <= 4 || (i == 5 && GAME_ALLOW_SCALE2) ||
                        (i == 6 && GAME_ALLOW_SCALE2 && GAME_ALLOW_WIDE_CACHE) ||
                        (i >= 7 && GAME_ALLOW_SCALE2 && GAME_ALLOW_WIDE_CACHE && GAME_ALLOW_BEAM))) : i <= 1;
        setup(versions[i], caps[i]);
        expect(allowed ? 0 : 0xe000, "hardware compatibility");
    }
    setup(0x110000, 0xffffb); expect(0xe000, "unknown version");
    setup(version, features); REG(ACCEL_ID) = 0; expect(0xe000, "wrong ID");
    setup(version, features); REG(ACCEL_WIDTH) = 1280; expect(0xe003, "wrong width");
    setup(version, features); REG(ACCEL_SERVICE_READ_QUOTA) = 64; expect(0xe003, "wrong DDR quota");
    setup(version, features); REG(ACCEL_SERVICE_STATUS) = 0; expect(0xe003, "missing service policy");
    setup(version, features | 0x10000); expect(0xe003, "unknown capability");
    setup(version, features & ~ACCEL_CAP_ALPHA); expect(0xe003, "missing alpha");
    setup(version, features); REG(ACCEL_ERROR_CODE) = 0x23; expect(0x23, "hardware error preserved");
    setup(version, features); REG(ACCEL_STATUS) |= ACCEL_BUSY; expect(0xe001, "busy timeout");
    setup(version, features); REG(ACCEL_BUFFER_STATUS) |= FRAME_SWAP_PENDING; expect(0xe001, "pending swap");
    setup(version, features); REG(ACCEL_BUFFER_STATUS) |= FRAME_WRITER_OWNED; expect(0xe001, "writer owned");
#if GAME_DISPLAY_WINDOW
        setup(version, features & ~ACCEL_CAP_DISPLAY_WINDOW); expect(0xe000, "missing window");
#endif
#if GAME_DISPLAY_WINDOW && GAME_ALLOW_SCALE2
        setup(0xb0000, 0x3ffb); expect(0xe003, "v11 missing scale");
        setup(0xa0000, 0x7ffb); expect(0xe003, "v10 unexpected scale");
        setup(0xb0000, 0xfffb); expect(0xe003, "v11 unexpected wide cache");
#endif
#if GAME_DISPLAY_WINDOW && GAME_ALLOW_SCALE2 && GAME_ALLOW_WIDE_CACHE
        setup(0xc0000, 0x7ffb); expect(0xe003, "v12 missing wide cache");
        setup(0xc0000, 0xbffb); expect(0xe003, "v12 missing scale");
        setup(0xc0000, 0xf7fb); expect(0xe000, "v12 missing window");
#endif
#if GAME_DISPLAY_WINDOW && GAME_ALLOW_SCALE2 && GAME_ALLOW_WIDE_CACHE && GAME_ALLOW_BEAM
    setup(0x100000,0x7fffb); expect(0xe003,"v16 missing tile compositor");
    setup(0xf0000,0xffffb); expect(0xe003,"v15 unexpected tile compositor");
    setup(0xf0000,0x3fffb); expect(0xe003,"v15 missing read ahead");
    setup(0xe0000,0x7fffb); expect(0xe003,"v14 unexpected read ahead");
    setup(0xe0000,0x1fffb); expect(0xe003,"v14 missing overlap");
    setup(0xe0000,0x2fffb); expect(0xe003,"v14 missing beam");
    setup(0xe0000,0x37ffb); expect(0xe003,"v14 missing cache");
    setup(0xd0000,0x3fffb); expect(0xe003,"v13 unexpected overlap");
    setup(0xd0000,0xfffb); expect(0xe003,"v13 missing beam");
    setup(0xd0000,0x17ffb); expect(0xe003,"v13 missing wide cache");
    setup(0xd0000,0x1bffb); expect(0xe003,"v13 missing scale");
    setup(0xc0000,0x1fffb); expect(0xe003,"v12 unexpected beam");
#endif
    printf("PASS %u startup checks: window=%d scale=%d wide=%d beam=%d\n",
           checks, GAME_DISPLAY_WINDOW, GAME_ALLOW_SCALE2, GAME_ALLOW_WIDE_CACHE,GAME_ALLOW_BEAM);
    return 0;
}
