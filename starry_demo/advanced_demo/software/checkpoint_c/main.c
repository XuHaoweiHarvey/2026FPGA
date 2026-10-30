/* Checkpoint C. CPU executes in OCRAM; only the hardware engine writes DDR. */
#include "accel_regs.h"

typedef struct { uint32_t x,y,width,height,color; } rectangle_t;
/* Stop at main, edit these in Variables, then Resume; or edit/rebuild here. */
volatile rectangle_t g_rectangle = {7,19,101,77,UINT32_C(0x0017A4E9)};
typedef struct {
    uint32_t id,version,status,error_code,errors,phase,pass;
    uint32_t init_data_beats,init_aw_bursts,init_wlast_bursts,init_b_responses,init_aw_beats;
    uint32_t front_base,write_owner,command_before,command_after;
    uint32_t rect_x_readback,rect_y_readback,width_readback,height_readback,color_readback;
    uint32_t scratch_readback;
} apb_test_result_t;
volatile apb_test_result_t g_apb_test_result;
static void barrier(void) { __asm__ volatile ("fence iorw,iorw" ::: "memory"); }
static void reg_write(uint32_t offset,uint32_t value) {
    barrier();*(volatile uint32_t *)(ACCEL_BASE+offset)=value;barrier();
}
static uint32_t reg_read(uint32_t offset) {
    uint32_t value;barrier();value=*(volatile uint32_t *)(ACCEL_BASE+offset);barrier();return value;
}
static void check(uint32_t actual,uint32_t expected) {
    if(actual!=expected) ++g_apb_test_result.errors;
}
__attribute__((noinline,noreturn)) void apb_test_done(void) {
    for(;;) __asm__ volatile ("nop" ::: "memory");
}
static void fail(uint32_t code) {
    ++g_apb_test_result.errors;
    g_apb_test_result.error_code=code;
    g_apb_test_result.status=reg_read(ACCEL_STATUS);
    apb_test_done();
}
static void wait_idle(int require_done) {
    uint32_t i,s;
    for(i=0;i<UINT32_C(20000000);++i) {
        s=reg_read(ACCEL_STATUS);g_apb_test_result.status=s;
        if(!(s&ACCEL_BUSY) && (!require_done || (s&ACCEL_DONE))) {
            if(require_done && (s&ACCEL_ERROR)) fail(reg_read(ACCEL_ERROR_CODE));
            return;
        }
    }
    fail(UINT32_C(0xE002));
}
static void fill(uint32_t x,uint32_t y,uint32_t w,uint32_t h,uint32_t color) {
    uint32_t before=reg_read(ACCEL_COMMAND_COUNT);
    reg_write(ACCEL_RECT_X,x);reg_write(ACCEL_RECT_Y,y);
    reg_write(ACCEL_RECT_WIDTH,w);reg_write(ACCEL_RECT_HEIGHT,h);reg_write(ACCEL_RECT_COLOR,color);
    check(reg_read(ACCEL_RECT_X),x);check(reg_read(ACCEL_RECT_Y),y);
    check(reg_read(ACCEL_RECT_WIDTH),w);check(reg_read(ACCEL_RECT_HEIGHT),h);check(reg_read(ACCEL_RECT_COLOR),color);
    reg_write(ACCEL_CONTROL,1);
    /* Acknowledge this command, avoiding a stale sticky DONE. */
    check(reg_read(ACCEL_COMMAND_COUNT),before+1);
    wait_idle(1);
}
int main(void) {
    uint32_t i,s;
    __asm__ volatile ("csrci mstatus,8" ::: "memory");
    g_apb_test_result.pass=0;g_apb_test_result.errors=0;g_apb_test_result.error_code=0;
    g_apb_test_result.phase=1;
    g_apb_test_result.id=reg_read(ACCEL_ID);check(g_apb_test_result.id,ACCEL_ID_EXPECTED);
    g_apb_test_result.version=reg_read(ACCEL_VERSION);check(g_apb_test_result.version,ACCEL_VERSION_EXPECTED);
    if(g_apb_test_result.errors) fail(UINT32_C(0xE000));
    for(i=0;i<UINT32_C(20000000);++i) {
        s=reg_read(ACCEL_STATUS);g_apb_test_result.status=s;
        if(s&ACCEL_INIT_DONE) break;
        if(s&ACCEL_ERROR) fail(reg_read(ACCEL_ERROR_CODE));
    }
    if(!(g_apb_test_result.status&ACCEL_INIT_DONE)) fail(UINT32_C(0xE001));
    wait_idle(0); /* Debug reset may have left an earlier command draining. */
    reg_write(ACCEL_CONTROL,2);
    g_apb_test_result.init_data_beats=reg_read(ACCEL_INIT_DATA_BEATS);
    g_apb_test_result.init_aw_bursts=reg_read(ACCEL_INIT_AW_BURSTS);
    g_apb_test_result.init_wlast_bursts=reg_read(ACCEL_INIT_WLAST_BURSTS);
    g_apb_test_result.init_b_responses=reg_read(ACCEL_INIT_B_RESPONSES);
    g_apb_test_result.init_aw_beats=reg_read(ACCEL_INIT_AW_BEATS);
    check(g_apb_test_result.init_data_beats,518400);check(g_apb_test_result.init_aw_beats,518400);
    check(g_apb_test_result.init_aw_bursts,g_apb_test_result.init_wlast_bursts);
    check(g_apb_test_result.init_aw_bursts,g_apb_test_result.init_b_responses);
    if(g_apb_test_result.init_aw_bursts==0) ++g_apb_test_result.errors;
    g_apb_test_result.front_base=reg_read(ACCEL_FRONT_BASE);check(g_apb_test_result.front_base,0);
    g_apb_test_result.write_owner=reg_read(ACCEL_WRITE_OWNER);check(g_apb_test_result.write_owner,1);
    check(reg_read(ACCEL_STRIDE),7680);check(reg_read(ACCEL_WIDTH),1920);check(reg_read(ACCEL_HEIGHT),1080);
    check(reg_read(ACCEL_CAPABILITIES),UINT32_C(0x1B));
    reg_write(ACCEL_SCRATCH,UINT32_C(0x12345678));
    g_apb_test_result.scratch_readback=reg_read(ACCEL_SCRATCH);check(g_apb_test_result.scratch_readback,UINT32_C(0x12345678));
    if(g_apb_test_result.errors) fail(UINT32_C(0xE003));
    g_apb_test_result.command_before=reg_read(ACCEL_COMMAND_COUNT);
    g_apb_test_result.phase=2;
    fill(0,0,1920,1080,UINT32_C(0x00102030));
    g_apb_test_result.phase=3;
    fill(g_rectangle.x,g_rectangle.y,g_rectangle.width,g_rectangle.height,g_rectangle.color);
    g_apb_test_result.rect_x_readback=reg_read(ACCEL_RECT_X);
    g_apb_test_result.rect_y_readback=reg_read(ACCEL_RECT_Y);
    g_apb_test_result.width_readback=reg_read(ACCEL_RECT_WIDTH);
    g_apb_test_result.height_readback=reg_read(ACCEL_RECT_HEIGHT);
    g_apb_test_result.color_readback=reg_read(ACCEL_RECT_COLOR);
    g_apb_test_result.command_after=reg_read(ACCEL_COMMAND_COUNT);
    check(g_apb_test_result.command_after,g_apb_test_result.command_before+2);
    g_apb_test_result.error_code=reg_read(ACCEL_ERROR_CODE);check(g_apb_test_result.error_code,0);
    g_apb_test_result.status=reg_read(ACCEL_STATUS);check(g_apb_test_result.status,UINT32_C(0x1A));
    g_apb_test_result.phase=4;
    g_apb_test_result.pass=(g_apb_test_result.errors==0)?1u:0u;
    apb_test_done();
}
