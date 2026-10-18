/* Checkpoint E: CPU submits commands only; FPGA performs every pixel write. */
#include "accel_api.h"
#include "demo_config.h"

typedef struct { uint32_t x,y,width,height,color; } rectangle_t;
volatile rectangle_t g_test_rectangle={TEST_RECT_X,TEST_RECT_Y,TEST_RECT_W,TEST_RECT_H,TEST_RECT_COLOR};
volatile uint32_t g_hold_frames=60;
volatile uint32_t g_frame_limit=0; /* 0 = indefinite; otherwise number of presented scenes. */
volatile uint32_t g_demo_mode=DEMO_MODE; /* 0 = multi-rectangle; 1 = parameter rectangle; 2 = BLIT. */
volatile uint32_t g_validation_target=1000; /* Records a milestone; never stops the loop. */

enum { PHASE_INIT=1,PHASE_BUILD=2,PHASE_RECT=3,PHASE_BACK_READY=4,
       PHASE_SWAP=5,PHASE_HOLD=6,PHASE_STOPPED=7,PHASE_FAILED=255 };
typedef struct {
    uint32_t id,version,pass,errors,phase,failure_phase,failure_code;
    uint32_t iterations,scene,mode,commands_issued,commands_completed;
    uint32_t swaps_requested,swaps_completed,timeout_count;
    uint32_t rejected_operations,rejected_commands,rejected_swaps;
    uint32_t accelerator_error_observations,reader_error_observations;
    uint32_t axi_write_error_observations,axi_read_error_observations;
    uint32_t command_baseline,swap_baseline,command_delta,swap_delta;
    uint32_t underflow_baseline,missed_baseline,underflow_delta,missed_delta;
    uint32_t baseline_valid,target_reached,running;
    uint32_t rect_x,rect_y,rect_width,rect_height,rect_color;
    uint32_t blit_commands_issued,blit_commands_completed;
    uint32_t source_swaps_requested,source_swaps_completed;
    uint32_t blit_source_base,blit_target_x,blit_target_y,blit_target_width,blit_target_height;
    accel_diagnostics_t diagnostics;
} demo_result_t;
/* Keep the successful IDE project/result symbol. diagnostics contains raw CSR
 * values; failure_code records software errors separately from ERROR_CODE. */
volatile demo_result_t g_apb_test_result;

__attribute__((noinline,noreturn)) void apb_test_done(void) {
    for(;;) __asm__ volatile ("nop" ::: "memory");
}
__attribute__((noinline)) void scene_begin(void) { __asm__ volatile ("nop" ::: "memory"); }
__attribute__((noinline)) void back_ready(void) { __asm__ volatile ("nop" ::: "memory"); }
__attribute__((noinline)) void frame_presented(void) { __asm__ volatile ("nop" ::: "memory"); }

static void snapshot(void) {
    diagnostics_read(&g_apb_test_result.diagnostics);
    if(g_apb_test_result.baseline_valid) {
        g_apb_test_result.command_delta=g_apb_test_result.diagnostics.command_count-g_apb_test_result.command_baseline;
        g_apb_test_result.swap_delta=g_apb_test_result.diagnostics.swap_count-g_apb_test_result.swap_baseline;
        g_apb_test_result.underflow_delta=g_apb_test_result.diagnostics.display_underflow_count-g_apb_test_result.underflow_baseline;
        g_apb_test_result.missed_delta=g_apb_test_result.diagnostics.missed_boundaries-g_apb_test_result.missed_baseline;
    }
}
static void require(uint32_t error) {
    if(!error) return;
    g_apb_test_result.failure_phase=g_apb_test_result.phase;
    g_apb_test_result.failure_code=error;
    ++g_apb_test_result.errors;g_apb_test_result.pass=0;
    if(error==0xE001u || error==0xE101u || error==0xE103u || error==0xE105u || error==0xE106u)
        ++g_apb_test_result.timeout_count;
    if(error==0xE102u || error==0xE104u || (error>=4 && error<=6)) {
        ++g_apb_test_result.rejected_operations;
        if(g_apb_test_result.phase==PHASE_SWAP) ++g_apb_test_result.rejected_swaps;
        else ++g_apb_test_result.rejected_commands;
    }
    snapshot();
    if(g_apb_test_result.diagnostics.error_code) ++g_apb_test_result.accelerator_error_observations;
    if(g_apb_test_result.diagnostics.reader_error) ++g_apb_test_result.reader_error_observations;
    if(g_apb_test_result.diagnostics.error_code==0x12u || g_apb_test_result.diagnostics.error_code==0x23u ||
       g_apb_test_result.diagnostics.error_code==0x1002u)
        ++g_apb_test_result.axi_write_error_observations;
    if(g_apb_test_result.diagnostics.error_code==0x22u || g_apb_test_result.diagnostics.reader_error==0x2003u)
        ++g_apb_test_result.axi_read_error_observations;
    g_apb_test_result.running=0;g_apb_test_result.phase=PHASE_FAILED;
    /* No CONTROL reset/error-clear, swap cancellation, or AXI interruption. */
    apb_test_done();
}
static void equal(uint32_t a,uint32_t b) { if(a!=b) require(UINT32_C(0xE003)); }
static void check_health(void) {
    snapshot();
    require(g_apb_test_result.diagnostics.error_code);
    if(g_apb_test_result.diagnostics.status&ACCEL_ERROR) require(UINT32_C(0xE107));
    if(g_apb_test_result.diagnostics.reader_error) require(UINT32_C(0xE108));
    if(g_apb_test_result.underflow_delta || g_apb_test_result.missed_delta) require(UINT32_C(0xE109));
}
static void fill(uint32_t x,uint32_t y,uint32_t w,uint32_t h,uint32_t color) {
    require(accel_fill_rect(x,y,w,h,color));
    ++g_apb_test_result.commands_issued; /* COMMAND_COUNT acknowledged START. */
    require(accel_wait_done());
    ++g_apb_test_result.commands_completed; /* Successful B/DONE, ownership released. */
    check_health();
}
static void blit_from_front(uint32_t x,uint32_t y,uint32_t w,uint32_t h) {
    uint32_t source=display_get_front_buffer();
    g_apb_test_result.blit_source_base=source;
    g_apb_test_result.blit_target_x=x;g_apb_test_result.blit_target_y=y;
    g_apb_test_result.blit_target_width=w;g_apb_test_result.blit_target_height=h;
    require(accel_blit(source,7680,x,y,w,h));
    ++g_apb_test_result.commands_issued;
    ++g_apb_test_result.blit_commands_issued;
    require(accel_wait_done());
    ++g_apb_test_result.commands_completed;
    ++g_apb_test_result.blit_commands_completed;
    check_health();
}
static void request_swap(uint32_t *ticket,uint32_t source_swap) {
    require(display_swap_request(ticket));
    ++g_apb_test_result.swaps_requested;
    if(source_swap) ++g_apb_test_result.source_swaps_requested;
    require(display_wait_swap_done(*ticket));
    ++g_apb_test_result.swaps_completed;
    if(source_swap) ++g_apb_test_result.source_swaps_completed;
    check_health();
}
static void hold_scene(uint32_t frames) {
    uint32_t i;
    /* Each frame wait is bounded; refresh diagnostics during the hold. */
    for(i=0;i<frames;++i) { require(display_wait_frames(1));check_health(); }
}
int main(void) {
    uint32_t old_front,old_back,ticket,scene=0,mode;
    rectangle_t rect;
    __asm__ volatile ("csrci mstatus,8" ::: "memory");
    g_apb_test_result.phase=PHASE_INIT;g_apb_test_result.running=1;
    g_apb_test_result.id=accel_read(ACCEL_ID);g_apb_test_result.version=accel_read(ACCEL_VERSION);
    require(accel_init());
    equal(accel_read(ACCEL_INIT_DATA_BEATS),518400);equal(accel_read(ACCEL_INIT_AW_BEATS),518400);
    equal(accel_read(ACCEL_INIT_AW_BURSTS),accel_read(ACCEL_INIT_WLAST_BURSTS));
    equal(accel_read(ACCEL_INIT_AW_BURSTS),accel_read(ACCEL_INIT_B_RESPONSES));
    if(!accel_read(ACCEL_INIT_AW_BURSTS)) require(UINT32_C(0xE003));
    equal(accel_read(ACCEL_WRITE_OWNER),1);
    accel_write(ACCEL_SCRATCH,UINT32_C(0x12345678));
    equal(accel_read(ACCEL_SCRATCH),UINT32_C(0x12345678));
    /* Retain startup history; allow steady display/CDC before the run baseline.
     * No counter clear and no later failure is excluded. */
    require(display_wait_frames(3));snapshot();
    g_apb_test_result.command_baseline=g_apb_test_result.diagnostics.command_count;
    g_apb_test_result.swap_baseline=g_apb_test_result.diagnostics.swap_count;
    g_apb_test_result.underflow_baseline=g_apb_test_result.diagnostics.display_underflow_count;
    g_apb_test_result.missed_baseline=g_apb_test_result.diagnostics.missed_boundaries;
    g_apb_test_result.baseline_valid=1;
    check_health();
    for(;;) {
        g_apb_test_result.phase=PHASE_BUILD;g_apb_test_result.scene=scene;
        mode=g_demo_mode;g_apb_test_result.mode=mode;
        rect.x=g_test_rectangle.x;rect.y=g_test_rectangle.y;
        rect.width=g_test_rectangle.width;rect.height=g_test_rectangle.height;rect.color=g_test_rectangle.color;
        g_apb_test_result.rect_x=rect.x;g_apb_test_result.rect_y=rect.y;
        g_apb_test_result.rect_width=rect.width;g_apb_test_result.rect_height=rect.height;
        g_apb_test_result.rect_color=rect.color;
        check_health();scene_begin();
        old_front=display_get_front_buffer();old_back=display_get_back_buffer();
        if(old_front==old_back || (old_front!=0 && old_front!=UINT32_C(0x00800000)) ||
           (old_back!=0 && old_back!=UINT32_C(0x00800000))) require(UINT32_C(0xE004));
        if(mode==2) {
            /* First build a source image in Back and publish it as Front. */
            g_apb_test_result.phase=PHASE_RECT;
            fill(0,0,1920,1080,UINT32_C(0));
            fill(0,0,16,16,UINT32_C(0x00FF0000));
            fill(16,0,16,16,UINT32_C(0x0000FF00));
            fill(0,16,16,16,UINT32_C(0x000000FF));
            fill(16,16,16,16,UINT32_C(0x00FFFF00));
            equal(display_get_front_buffer(),old_front);equal(display_get_back_buffer(),old_back);
            equal(g_apb_test_result.commands_issued,g_apb_test_result.commands_completed);
            check_health();equal(g_apb_test_result.command_delta,g_apb_test_result.commands_issued);
            g_apb_test_result.phase=PHASE_BACK_READY;back_ready();
            g_apb_test_result.phase=PHASE_SWAP;
            request_swap(&ticket,1);
            g_apb_test_result.phase=PHASE_RECT;
            /* The new Back is cleared before BLIT; source Front remains visible. */
            equal(display_get_front_buffer(),old_back);equal(display_get_back_buffer(),old_front);
            fill(0,0,1920,1080,UINT32_C(0));
            blit_from_front(64,64,32,32);
            equal(display_get_front_buffer(),old_back);equal(display_get_back_buffer(),old_front);
            equal(g_apb_test_result.commands_issued,g_apb_test_result.commands_completed);
            check_health();equal(g_apb_test_result.command_delta,g_apb_test_result.commands_issued);
            g_apb_test_result.phase=PHASE_BACK_READY;back_ready();
            g_apb_test_result.phase=PHASE_SWAP;
            request_swap(&ticket,0);
        } else {
            fill(0,0,1920,1080,mode==1 ? 0 : (scene==0 ? DEMO_BACKGROUND_A : DEMO_BACKGROUND_B));
            g_apb_test_result.phase=PHASE_RECT;
            if(mode==1 || scene==0) {
                fill(rect.x,rect.y,rect.width,rect.height,rect.color);
                if(mode!=1) {
                    fill(760,240,300,300,UINT32_C(0x0000FF00));
                    fill(1260,590,450,280,UINT32_C(0x000000FF));
                }
            } else {
                fill(140,630,470,170,UINT32_C(0x00FFFF00));
                fill(960,130,220,410,UINT32_C(0x0000FFFF));
                fill(1300,500,370,330,UINT32_C(0x00FF00FF));
            }
            equal(display_get_front_buffer(),old_front);equal(display_get_back_buffer(),old_back);
            equal(g_apb_test_result.commands_issued,g_apb_test_result.commands_completed);
            check_health();equal(g_apb_test_result.command_delta,g_apb_test_result.commands_issued);
            g_apb_test_result.phase=PHASE_BACK_READY;back_ready();
            g_apb_test_result.phase=PHASE_SWAP;
            request_swap(&ticket,0);
        }
        /* Two swaps in BLIT mode restore the initial slot roles. */
        equal(display_get_front_buffer(),mode==2 ? old_front : old_back);
        equal(display_get_back_buffer(),mode==2 ? old_back : old_front);
        equal(g_apb_test_result.commands_issued,g_apb_test_result.commands_completed);
        check_health();
        equal(g_apb_test_result.diagnostics.reader_base,mode==2 ? old_front : old_back);
        equal(g_apb_test_result.swap_delta,g_apb_test_result.swaps_completed);
        ++g_apb_test_result.iterations;
        if(g_apb_test_result.iterations>=2) g_apb_test_result.pass=1;
        if(g_validation_target && g_apb_test_result.iterations>=g_validation_target)
            g_apb_test_result.target_reached=1;
        g_apb_test_result.phase=PHASE_HOLD;frame_presented();
        hold_scene(g_hold_frames);check_health();
        if(g_frame_limit && g_apb_test_result.iterations>=g_frame_limit) {
            g_apb_test_result.running=0;g_apb_test_result.phase=PHASE_STOPPED;apb_test_done();
        }
        scene^=1u;
    }
}
