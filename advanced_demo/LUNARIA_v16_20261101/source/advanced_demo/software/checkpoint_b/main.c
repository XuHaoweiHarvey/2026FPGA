/* On-chip RAM application; no UART, interrupt, or DDR accesses. */
#include "accel_regs.h"

typedef struct {
    uint32_t id;
    uint32_t version;
    uint32_t rect_x_readback;
    uint32_t rect_y_readback;
    uint32_t color_readback;
    uint32_t scratch_readback;
    uint32_t status;
    uint32_t error_code;
    uint32_t errors;
    uint32_t iterations;
    uint32_t phase;
    uint32_t pass;
} apb_test_result_t;
volatile apb_test_result_t g_apb_test_result;

static void barrier(void) { __asm__ volatile ("fence iorw,iorw" ::: "memory"); }
static void reg_write(uint32_t offset, uint32_t value) {
    barrier();
    *(volatile uint32_t *)(ACCEL_BASE + offset) = value;
    barrier();
}
static uint32_t reg_read(uint32_t offset) {
    uint32_t value;
    barrier();
    value = *(volatile uint32_t *)(ACCEL_BASE + offset);
    barrier();
    return value;
}
static void check(uint32_t actual, uint32_t expected) {
    if (actual != expected) ++g_apb_test_result.errors;
}

/* Set a breakpoint at this function: result is complete before entry. */
__attribute__((noinline, noreturn)) void apb_test_done(void) {
    for (;;) __asm__ volatile ("nop" ::: "memory");
}

int main(void) {
    uint32_t i, pattern;
    __asm__ volatile ("csrci mstatus,8" ::: "memory"); // no interrupts in B
    g_apb_test_result.pass = 0;
    g_apb_test_result.errors = 0;
    g_apb_test_result.iterations = 0;
    g_apb_test_result.phase = 1;
    g_apb_test_result.id = reg_read(ACCEL_ID);
    check(g_apb_test_result.id, ACCEL_ID_EXPECTED);
    g_apb_test_result.version = reg_read(ACCEL_VERSION);
    check(g_apb_test_result.version, ACCEL_VERSION_EXPECTED);

    g_apb_test_result.phase = 2;
    reg_write(ACCEL_RECT_X, 123);
    g_apb_test_result.rect_x_readback = reg_read(ACCEL_RECT_X);
    check(g_apb_test_result.rect_x_readback, 123);
    reg_write(ACCEL_RECT_Y, 456);
    g_apb_test_result.rect_y_readback = reg_read(ACCEL_RECT_Y);
    check(g_apb_test_result.rect_y_readback, 456);
    reg_write(ACCEL_RECT_COLOR, UINT32_C(0x00FF0000));
    g_apb_test_result.color_readback = reg_read(ACCEL_RECT_COLOR);
    check(g_apb_test_result.color_readback, UINT32_C(0x00FF0000));
    reg_write(ACCEL_RECT_WIDTH, 640);
    check(reg_read(ACCEL_RECT_WIDTH), 640);
    reg_write(ACCEL_RECT_HEIGHT, 480);
    check(reg_read(ACCEL_RECT_HEIGHT), 480);

    /* Repeated writes/reads exercise all bits without relying on UART. */
    g_apb_test_result.phase = 3;
    for (i = 0; i < 2048; ++i) {
        pattern = (UINT32_C(1) << (i & 31u)) ^ (i * UINT32_C(0x1020304));
        reg_write(ACCEL_SCRATCH, pattern);
        check(reg_read(ACCEL_SCRATCH), pattern);
        g_apb_test_result.iterations = i + 1;
    }
    reg_write(ACCEL_SCRATCH, UINT32_C(0x12345678));
    g_apb_test_result.scratch_readback = reg_read(ACCEL_SCRATCH);
    check(g_apb_test_result.scratch_readback, UINT32_C(0x12345678));

    /* CONTROL upper bits are RW; bit 0 is a self-clearing START test only. */
    g_apb_test_result.phase = 4;
    reg_write(ACCEL_CONTROL, UINT32_C(0x20));
    check(reg_read(ACCEL_CONTROL), UINT32_C(0x20));
    reg_write(ACCEL_CONTROL, UINT32_C(0x21));
    check(reg_read(ACCEL_CONTROL), UINT32_C(0x20));
    g_apb_test_result.status = reg_read(ACCEL_STATUS);
    check(g_apb_test_result.status, 2); /* START_SEEN=1, BUSY=0 */
    g_apb_test_result.error_code = reg_read(ACCEL_ERROR_CODE);
    check(g_apb_test_result.error_code, 0);
    check(reg_read(ACCEL_STRIDE), 7680);
    check(reg_read(ACCEL_WIDTH), 1920);
    check(reg_read(ACCEL_HEIGHT), 1080);
    check(reg_read(ACCEL_CAPABILITIES), 7);

    /* Invalid/RO accesses are tested in RTL simulation, not on this CPU:
       the generated SoC's PSLVERROR-to-trap behavior is not confirmed yet. */
    g_apb_test_result.phase = 5;
    g_apb_test_result.pass = (g_apb_test_result.errors == 0) ? 1u : 0u;
    apb_test_done();
}
