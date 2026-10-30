/* M1a board smoke test. Code, data and stack remain in 64 KB OCRAM. */
#include "../apb_reg_test/accel_api.h"

#ifndef SYSTEM_DDR_BMB
#error "Generate Sapphire external memory before building M1a"
#endif
#if SYSTEM_DDR_BMB != 0x1000
#error "Recheck the CPU DDR window and address translation"
#endif

typedef struct {
    uint32_t phase, pass, error, front, back, cpu_status, cpu_error;
    uint32_t writes, reads, last_value, swap_ticket;
    uint32_t underflow_before,underflow_after,missed_before,missed_after;
} m1a_result_t;
volatile m1a_result_t g_m1a_result;

__attribute__((noinline,noreturn)) void m1a_test_done(void) {
    for(;;) __asm__ volatile ("nop" ::: "memory");
}
static void fail(uint32_t code) {
    g_m1a_result.error=code;
    g_m1a_result.cpu_status=accel_read(ACCEL_CPU_DDR_STATUS);
    g_m1a_result.cpu_error=accel_read(ACCEL_CPU_DDR_ERROR);
    g_m1a_result.underflow_after=accel_read(ACCEL_DISPLAY_UNDERFLOW_COUNT);
    g_m1a_result.missed_after=accel_read(ACCEL_MISSED_BOUNDARY_COUNT);
    m1a_test_done();
}
static void check(uint32_t code) { if(code) fail(code); }
static uint32_t wait_cpu_status(uint32_t mask,uint32_t value) {
    uint32_t i,status;
    for(i=0;i<ACCEL_POLL_LIMIT;++i) {
        status=accel_read(ACCEL_CPU_DDR_STATUS);
        if((status&mask)==value) return 0;
    }
    return UINT32_C(0xE201);
}
int main(void) {
    uint32_t x,y,ticket,status,front,back,pixel;
    volatile uint32_t *ddr;
    __asm__ volatile ("csrci mstatus,8" ::: "memory");
    g_m1a_result.phase=1;
    check(accel_init());
    if(!(accel_read(ACCEL_CPU_DDR_STATUS)&(1u<<4))) fail(UINT32_C(0xE202));
    /* An IDE restart does not reset the platform owner. Recover only once
       the old transaction has drained, then explicitly release its session. */
    status=accel_read(ACCEL_CPU_DDR_STATUS);
    if(status&1u) {
        check(wait_cpu_status(2u,0));
        accel_write(ACCEL_CPU_DDR_CONTROL,2u);
        check(wait_cpu_status(1u,0));
    }
    accel_write(ACCEL_CPU_DDR_CONTROL,4u);
    check(display_wait_frames(3));
    g_m1a_result.underflow_before=accel_read(ACCEL_DISPLAY_UNDERFLOW_COUNT);
    g_m1a_result.missed_before=accel_read(ACCEL_MISSED_BOUNDARY_COUNT);
    g_m1a_result.phase=2;
    check(accel_fill_rect(0,0,1920,1080,UINT32_C(0x00102030)));
    check(accel_wait_done());
    front=frame_get_front();back=frame_get_back();
    g_m1a_result.front=front;g_m1a_result.back=back;
    if(front==back || (front!=0 && front!=UINT32_C(0x00800000)) ||
       (back!=0 && back!=UINT32_C(0x00800000))) fail(UINT32_C(0xE203));
    g_m1a_result.phase=3;
    accel_write(ACCEL_CPU_DDR_CONTROL,1u);
    check(wait_cpu_status(1u,1u));
    if(accel_read(ACCEL_CPU_DDR_STATUS)&4u) fail(UINT32_C(0xE204));
    /* The CPU sees a 0x1000 alias of the physical DDR byte address. */
    ddr=(volatile uint32_t *)(uintptr_t)(SYSTEM_DDR_BMB+back);
    for(y=256;y<384;++y) {
        for(x=256;x<384;++x) {
            pixel=UINT32_C(0x0000E060);
            ddr[y*1920u+x]=pixel;
            ++g_m1a_result.writes;
        }
        __asm__ volatile ("fence iorw,iorw" ::: "memory");
        if(ddr[y*1920u+256u]!=pixel || ddr[y*1920u+383u]!=pixel)
            fail(UINT32_C(0xE205));
        g_m1a_result.reads+=2;
    }
    g_m1a_result.last_value=ddr[383u*1920u+383u];
    if(g_m1a_result.last_value!=pixel) fail(UINT32_C(0xE206));
    ++g_m1a_result.reads;
    if(frame_get_front()!=front || frame_get_back()!=back) fail(UINT32_C(0xE207));
    g_m1a_result.phase=4;
    __asm__ volatile ("fence iorw,iorw" ::: "memory");
    check(wait_cpu_status(2u,0));
    if(accel_read(ACCEL_CPU_DDR_ERROR)) fail(UINT32_C(0xE208));
    accel_write(ACCEL_CPU_DDR_CONTROL,2u);
    check(wait_cpu_status(1u,0));
    g_m1a_result.phase=5;
    check(frame_swap_request(&ticket));
    g_m1a_result.swap_ticket=ticket;
    check(display_wait_swap_done(ticket));
    if(frame_get_front()!=back) fail(UINT32_C(0xE209));
    check(display_wait_frames(2));
    g_m1a_result.underflow_after=accel_read(ACCEL_DISPLAY_UNDERFLOW_COUNT);
    g_m1a_result.missed_after=accel_read(ACCEL_MISSED_BOUNDARY_COUNT);
    if(g_m1a_result.underflow_after!=g_m1a_result.underflow_before ||
       g_m1a_result.missed_after!=g_m1a_result.missed_before)
        fail(UINT32_C(0xE20A));
    g_m1a_result.cpu_status=accel_read(ACCEL_CPU_DDR_STATUS);
    g_m1a_result.cpu_error=accel_read(ACCEL_CPU_DDR_ERROR);
    g_m1a_result.phase=6;g_m1a_result.pass=1;
    m1a_test_done();
}
