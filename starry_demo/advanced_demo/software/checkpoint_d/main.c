/* Checkpoint D: rebuild Back, then explicitly present at a safe frame boundary. */
#include "accel_api.h"

typedef struct { uint32_t x,y,width,height,color; } rectangle_t;
/* Edit at main or scene_begin in Variables; edits apply to the next scene. */
volatile rectangle_t g_red_rectangle   = {353,217,509,233,UINT32_C(0x00FF0000)};
volatile rectangle_t g_green_rectangle = {717,401,301,199,UINT32_C(0x0000FF00)};
volatile uint32_t g_hold_frames=60; /* Display periods to hold each completed scene. */
volatile uint32_t g_frame_limit=0;  /* 0 = run continuously; 2 = one complete A/B cycle. */
typedef struct {
    uint32_t id,version,status,error_code,errors,phase,pass;
    uint32_t init_data_beats,init_aw_bursts,init_wlast_bursts,init_b_responses,init_aw_beats;
    uint32_t front_base,back_base,buffer_status,write_owner;
    uint32_t command_before,command_after,swap_before,swap_after,frames_presented,scene;
    uint32_t reader_base,reader_outstanding,reader_data_beats,reader_reserved_beats,reader_error;
    uint32_t boundary_count,missed_boundaries;
    uint32_t rect_x,rect_y,rect_width,rect_height,rect_color;
    uint32_t scratch_readback;
    uint32_t service_status,writer_throttle_cycles,writer_bursts,reader_ar_stall_cycles,reader_ar_max_stall,reader_r_stall_cycles,reader_r_max_stall,display_underflow_count,reader_frame_completions,reader_fifo_level,writer_max_cycles,service_read_quota,service_watermarks;
} apb_test_result_t;
volatile apb_test_result_t g_apb_test_result;

__attribute__((noinline,noreturn)) void apb_test_done(void) {
    for(;;) __asm__ volatile ("nop" ::: "memory");
}
/* Breakpoint hooks: scene_begin observes the OLD Front while Back is rebuilt;
 * frame_presented observes committed ownership; new pixels follow in active video. */
__attribute__((noinline)) void scene_begin(void) { __asm__ volatile ("nop" ::: "memory"); }
__attribute__((noinline)) void back_ready(void) { __asm__ volatile ("nop" ::: "memory"); }
__attribute__((noinline)) void frame_presented(void) { __asm__ volatile ("nop" ::: "memory"); }
static void snapshot(void) {
    g_apb_test_result.service_status=accel_read(ACCEL_SERVICE_STATUS);
    g_apb_test_result.writer_throttle_cycles=accel_read(ACCEL_WRITER_THROTTLE_CYCLES);
    g_apb_test_result.writer_bursts=accel_read(ACCEL_WRITER_BURSTS);
    g_apb_test_result.reader_ar_stall_cycles=accel_read(ACCEL_READER_AR_STALL_CYCLES);
    g_apb_test_result.reader_ar_max_stall=accel_read(ACCEL_READER_AR_MAX_STALL);
    g_apb_test_result.reader_r_stall_cycles=accel_read(ACCEL_READER_R_STALL_CYCLES);
    g_apb_test_result.reader_r_max_stall=accel_read(ACCEL_READER_R_MAX_STALL);
    g_apb_test_result.display_underflow_count=accel_read(ACCEL_DISPLAY_UNDERFLOW_COUNT);
    g_apb_test_result.reader_frame_completions=accel_read(ACCEL_READER_FRAME_COMPLETIONS);
    g_apb_test_result.reader_fifo_level=accel_read(ACCEL_READER_FIFO_LEVEL);
    g_apb_test_result.writer_max_cycles=accel_read(ACCEL_WRITER_MAX_CYCLES);
    g_apb_test_result.service_read_quota=accel_read(ACCEL_SERVICE_READ_QUOTA);
    g_apb_test_result.service_watermarks=accel_read(ACCEL_SERVICE_WATERMARKS);

    g_apb_test_result.status=accel_read(ACCEL_STATUS);
    g_apb_test_result.front_base=frame_get_front();g_apb_test_result.back_base=frame_get_back();
    g_apb_test_result.buffer_status=accel_read(ACCEL_BUFFER_STATUS);
    g_apb_test_result.reader_base=accel_read(ACCEL_READER_BASE);
    g_apb_test_result.reader_outstanding=accel_read(ACCEL_READER_OUTSTANDING);
    g_apb_test_result.reader_data_beats=accel_read(ACCEL_READER_DATA_BEATS);
    g_apb_test_result.reader_reserved_beats=accel_read(ACCEL_READER_RESERVED_BEATS);
    g_apb_test_result.reader_error=accel_read(ACCEL_READER_ERROR);
    g_apb_test_result.boundary_count=accel_read(ACCEL_BOUNDARY_COUNT);
    g_apb_test_result.missed_boundaries=accel_read(ACCEL_MISSED_BOUNDARY_COUNT);
}
static void require(uint32_t error) {
    if(!error) return;
    ++g_apb_test_result.errors;g_apb_test_result.pass=0;
    g_apb_test_result.error_code=error;snapshot();apb_test_done();
}
static void equal(uint32_t a,uint32_t b) { if(a!=b) require(UINT32_C(0xE003)); }
static void fill(uint32_t x,uint32_t y,uint32_t w,uint32_t h,uint32_t color) {
    require(accel_fill_rect(x,y,w,h,color));require(accel_wait_done());
}
static void hold_scene(uint32_t frames) {
    uint32_t i,start=accel_read(ACCEL_BOUNDARY_COUNT);
    for(i=0;i<ACCEL_POLL_LIMIT;++i) {
        require(accel_error());
        if(accel_read(ACCEL_BOUNDARY_COUNT)-start>=frames) return;
    }
    require(UINT32_C(0xE106));
}
int main(void) {
    uint32_t i,s=0,bs=0,old_front,old_back,ticket,scene=0;
    rectangle_t rect;
    __asm__ volatile ("csrci mstatus,8" ::: "memory");
    g_apb_test_result.phase=1;g_apb_test_result.pass=0;g_apb_test_result.errors=0;
    g_apb_test_result.id=accel_read(ACCEL_ID);g_apb_test_result.version=accel_read(ACCEL_VERSION);
    if(g_apb_test_result.id!=ACCEL_ID_EXPECTED || g_apb_test_result.version!=ACCEL_VERSION_EXPECTED)
        require(UINT32_C(0xE000));
    /* CPU Debug reset does not reset DMA/Front/Back. Let an old command/swap finish. */
    for(i=0;i<ACCEL_POLL_LIMIT;++i) {
        require(accel_error());s=accel_read(ACCEL_STATUS);bs=accel_read(ACCEL_BUFFER_STATUS);
        if((s&ACCEL_INIT_DONE) && !(s&ACCEL_BUSY) && (bs&FRAME_FRONT_VALID) &&
           !(bs&(FRAME_SWAP_PENDING|FRAME_WRITER_OWNED))) break;
    }
    if(i==ACCEL_POLL_LIMIT) require(UINT32_C(0xE001));
    g_apb_test_result.init_data_beats=accel_read(ACCEL_INIT_DATA_BEATS);
    g_apb_test_result.init_aw_beats=accel_read(ACCEL_INIT_AW_BEATS);
    g_apb_test_result.init_aw_bursts=accel_read(ACCEL_INIT_AW_BURSTS);
    g_apb_test_result.init_wlast_bursts=accel_read(ACCEL_INIT_WLAST_BURSTS);
    g_apb_test_result.init_b_responses=accel_read(ACCEL_INIT_B_RESPONSES);
    equal(g_apb_test_result.init_data_beats,518400);equal(g_apb_test_result.init_aw_beats,518400);
    equal(g_apb_test_result.init_aw_bursts,g_apb_test_result.init_wlast_bursts);
    equal(g_apb_test_result.init_aw_bursts,g_apb_test_result.init_b_responses);
    if(!g_apb_test_result.init_aw_bursts) require(UINT32_C(0xE003));
    equal(accel_read(ACCEL_STRIDE),7680);equal(accel_read(ACCEL_WIDTH),1920);
    equal(accel_read(ACCEL_HEIGHT),1080);equal(accel_read(ACCEL_CAPABILITIES),UINT32_C(0x3B));
    g_apb_test_result.write_owner=accel_read(ACCEL_WRITE_OWNER);equal(g_apb_test_result.write_owner,1);
    accel_write(ACCEL_SCRATCH,UINT32_C(0x12345678));
    g_apb_test_result.scratch_readback=accel_read(ACCEL_SCRATCH);
    equal(g_apb_test_result.scratch_readback,UINT32_C(0x12345678));
    accel_write(ACCEL_SWAP_CONTROL,FRAME_CLEAR_DONE);
    for(;;) {
        g_apb_test_result.scene=scene;g_apb_test_result.phase=2;snapshot();scene_begin();
        old_front=frame_get_front();old_back=frame_get_back();
        if(old_front==old_back || (old_front!=0 && old_front!=UINT32_C(0x00800000)) ||
           (old_back!=0 && old_back!=UINT32_C(0x00800000))) require(UINT32_C(0xE004));
        if(scene==0) { rect.x=g_red_rectangle.x;rect.y=g_red_rectangle.y;
            rect.width=g_red_rectangle.width;rect.height=g_red_rectangle.height;rect.color=g_red_rectangle.color; }
        else { rect.x=g_green_rectangle.x;rect.y=g_green_rectangle.y;
            rect.width=g_green_rectangle.width;rect.height=g_green_rectangle.height;rect.color=g_green_rectangle.color; }
        g_apb_test_result.command_before=accel_read(ACCEL_COMMAND_COUNT);
        fill(0,0,1920,1080,scene==0?UINT32_C(0x000000FF):0);
        g_apb_test_result.phase=3;
        fill(rect.x,rect.y,rect.width,rect.height,rect.color);
        g_apb_test_result.rect_x=rect.x;g_apb_test_result.rect_y=rect.y;
        g_apb_test_result.rect_width=rect.width;g_apb_test_result.rect_height=rect.height;
        g_apb_test_result.rect_color=rect.color;
        g_apb_test_result.command_after=accel_read(ACCEL_COMMAND_COUNT);
        equal(g_apb_test_result.command_after,g_apb_test_result.command_before+2u);
        equal(frame_get_front(),old_front);equal(frame_get_back(),old_back);
        snapshot();back_ready(); /* HDMI must still show the previous Front here. */
        g_apb_test_result.phase=4;g_apb_test_result.swap_before=accel_read(ACCEL_SWAP_COUNT);
        require(frame_swap_request(&ticket));require(frame_wait_swap_done(ticket));
        g_apb_test_result.swap_after=accel_read(ACCEL_SWAP_COUNT);
        equal(g_apb_test_result.swap_after,g_apb_test_result.swap_before+1u);
        equal(frame_get_front(),old_back);equal(frame_get_back(),old_front);
        snapshot();equal(g_apb_test_result.reader_base,old_back);
        ++g_apb_test_result.frames_presented;
        if(g_apb_test_result.frames_presented>=2) g_apb_test_result.pass=1;
        g_apb_test_result.phase=5;frame_presented();
        hold_scene(g_hold_frames);
        if(g_frame_limit && g_apb_test_result.frames_presented>=g_frame_limit) apb_test_done();
        scene^=1u;
    }
}
