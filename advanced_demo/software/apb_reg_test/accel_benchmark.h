#ifndef ACCEL_BENCHMARK_H
#define ACCEL_BENCHMARK_H
#include "accel_regs.h"

#define BENCHMARK_CASE_COUNT 12u
enum { BENCH_PREPARE=1,BENCH_WARMUP=2,BENCH_DRAW=3,BENCH_SWAP=4,
       BENCH_FINISHED=5,BENCH_FAILED=255 };
enum { BENCH_ERR_CONFIG=0xE200,BENCH_ERR_CLOCK=0xE201,
       BENCH_ERR_COUNTS=0xE202,BENCH_ERR_BUFFERS=0xE203 };

/* All totals are from this software run. Hardware counters are never cleared.
 * A row is publishable only when complete=1 and the whole run has pass=1. */
typedef struct {
    uint32_t complete,op,width,height,source_base,back_base;
    uint32_t samples_completed;
    uint32_t command_delta,swap_delta,underflow_delta,missed_delta;
    uint32_t writer_bursts_delta,writer_throttle_cycles_delta,reader_frames_delta;
    uint64_t draw_ticks_total,draw_ticks_min,draw_ticks_max,swap_ticks;
    uint64_t draw_us_total,draw_us_mean,draw_us_min,draw_us_max,swap_us;
    uint64_t rectangle_pixels_total,opaque_pixels_total;
    uint64_t rectangle_pixels_per_second,opaque_pixels_per_second;
} benchmark_case_t;
typedef struct {
    uint32_t schema_version,timer_hz,samples,warmups,case_count;
    uint32_t pass,completed_cases,active_case,phase,failure_phase,error_code;
    uint32_t id,version,capabilities,service_read_quota,service_watermarks;
    uint32_t commands_issued,commands_completed,swaps_requested,swaps_completed;
    uint32_t command_baseline,swap_baseline,underflow_baseline,missed_baseline;
    uint32_t command_delta,swap_delta,underflow_delta,missed_delta;
    uint64_t timer_read_ticks_min;
    benchmark_case_t cases[BENCHMARK_CASE_COUNT];
} benchmark_result_t;

/* The production backend uses the existing polling API. A native test backend
 * verifies sequencing/accounting/failures without executing RISC-V instructions. */
typedef struct {
    uint32_t (*read)(uint32_t);
    uint64_t (*ticks)(void);
    uint32_t (*submit)(uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,uint32_t);
    uint32_t (*wait_done)(void);
    uint32_t (*swap_request)(uint32_t *);
    uint32_t (*swap_wait)(uint32_t);
} benchmark_io_t;

static inline uint64_t benchmark_us(uint64_t ticks,uint32_t hz) {
    return (ticks/hz)*UINT64_C(1000000)+(ticks%hz)*UINT64_C(1000000)/hz;
}
static uint32_t benchmark_health(const benchmark_io_t *io,volatile benchmark_result_t *r) {
    uint32_t e=io->read(ACCEL_ERROR_CODE);
    r->command_delta=io->read(ACCEL_COMMAND_COUNT)-r->command_baseline;
    r->swap_delta=io->read(ACCEL_SWAP_COUNT)-r->swap_baseline;
    r->underflow_delta=io->read(ACCEL_DISPLAY_UNDERFLOW_COUNT)-r->underflow_baseline;
    r->missed_delta=io->read(ACCEL_MISSED_BOUNDARY_COUNT)-r->missed_baseline;
    if(e) return e;
    if(io->read(ACCEL_STATUS)&ACCEL_ERROR) return UINT32_C(0xE107);
    if(io->read(ACCEL_READER_ERROR)) return UINT32_C(0xE108);
    if(r->underflow_delta || r->missed_delta) return UINT32_C(0xE109);
    return 0;
}
static uint32_t benchmark_issue(const benchmark_io_t *io,volatile benchmark_result_t *r,
                                uint32_t op,uint32_t src,uint32_t w,uint32_t h,uint32_t color) {
    uint32_t e=io->submit(op,src,7680,0,0,w,h,color);
    if(e) return e;
    ++r->commands_issued;
    e=io->wait_done();
    if(!e) ++r->commands_completed;
    return e;
}
static uint32_t benchmark_swap(const benchmark_io_t *io,volatile benchmark_result_t *r) {
    uint32_t ticket,e=io->swap_request(&ticket);
    if(e) return e;
    ++r->swaps_requested;
    e=io->swap_wait(ticket);
    if(!e) ++r->swaps_completed;
    return e;
}
static uint32_t benchmark_case_run(const benchmark_io_t *io,volatile benchmark_result_t *r,
                                    volatile benchmark_case_t *c) {
    const uint32_t key=UINT32_C(0x80FF00FF),opaque=UINT32_C(0x40E8E8F0);
    const uint32_t background=UINT32_C(0x00182838);
    uint32_t e,i,front=io->read(ACCEL_FRONT_BASE),back=io->read(ACCEL_BACK_BASE);
    uint32_t commands=io->read(ACCEL_COMMAND_COUNT),swaps=io->read(ACCEL_SWAP_COUNT);
    uint32_t underflow=io->read(ACCEL_DISPLAY_UNDERFLOW_COUNT);
    uint32_t missed=io->read(ACCEL_MISSED_BOUNDARY_COUNT);
    uint32_t bursts=io->read(ACCEL_WRITER_BURSTS),throttle=io->read(ACCEL_WRITER_THROTTLE_CYCLES);
    uint32_t frames=io->read(ACCEL_READER_FRAME_COMPLETIONS);
    uint64_t start,end,elapsed;
    r->phase=BENCH_PREPARE;
    if(front==back || (front!=0 && front!=UINT32_C(0x00800000)) ||
       (back!=0 && back!=UINT32_C(0x00800000))) return BENCH_ERR_BUFFERS;
    /* Each case gets an independent source: left half key, right half opaque.
     * Full-frame preparation is deliberately outside the measurement. */
    e=benchmark_issue(io,r,ACCEL_OP_FILL,0,1920,1080,key);if(e) return e;
    e=io->submit(ACCEL_OP_FILL,0,0,c->width/2u,0,c->width/2u,c->height,opaque);
    if(e) return e;
    ++r->commands_issued;e=io->wait_done();if(e) return e;++r->commands_completed;
    e=benchmark_swap(io,r);if(e) return e;
    c->source_base=back;c->back_base=front;
    if(io->read(ACCEL_FRONT_BASE)!=back || io->read(ACCEL_BACK_BASE)!=front ||
       io->read(ACCEL_READER_BASE)!=back) return BENCH_ERR_BUFFERS;
    e=benchmark_health(io,r);if(e) return e;
    e=benchmark_issue(io,r,ACCEL_OP_FILL,0,1920,1080,background);if(e) return e;
    e=benchmark_health(io,r);if(e) return e;
    for(i=0;i<r->warmups+r->samples;++i) {
        r->phase=i<r->warmups ? BENCH_WARMUP : BENCH_DRAW;
        /* Reset the destination even after ordinary BLIT. Otherwise a previous
         * purple write could survive into the transparent half of a key test. */
        e=benchmark_issue(io,r,ACCEL_OP_FILL,0,c->width,c->height,background);if(e) return e;
        if(io->read(ACCEL_FRONT_BASE)!=c->source_base || io->read(ACCEL_BACK_BASE)!=c->back_base)
            return BENCH_ERR_BUFFERS;
        start=io->ticks();
        e=benchmark_issue(io,r,c->op,c->source_base,c->width,c->height,
                          c->op==ACCEL_OP_COLOR_KEY ? key&UINT32_C(0x00FFFFFF) : opaque);
        end=io->ticks();
        if(e) return e;
        if(end<=start) return BENCH_ERR_CLOCK;
        elapsed=end-start;
        if(i>=r->warmups) {
            c->draw_ticks_total+=elapsed;
            if(!c->samples_completed || elapsed<c->draw_ticks_min) c->draw_ticks_min=elapsed;
            if(elapsed>c->draw_ticks_max) c->draw_ticks_max=elapsed;
            ++c->samples_completed;
        }
        e=benchmark_health(io,r);if(e) return e;
    }
    /* Only present after every timed draw has completed its final B response.
     * Swap latency includes request/polling; no fixed hold is inserted. */
    r->phase=BENCH_SWAP;start=io->ticks();
    e=benchmark_swap(io,r);end=io->ticks();if(e) return e;
    if(end<=start) return BENCH_ERR_CLOCK;
    c->swap_ticks=end-start;
    e=benchmark_health(io,r);if(e) return e;
    if(io->read(ACCEL_FRONT_BASE)!=front || io->read(ACCEL_BACK_BASE)!=back ||
       io->read(ACCEL_READER_BASE)!=front) return BENCH_ERR_BUFFERS;
    c->command_delta=io->read(ACCEL_COMMAND_COUNT)-commands;
    c->swap_delta=io->read(ACCEL_SWAP_COUNT)-swaps;
    c->underflow_delta=io->read(ACCEL_DISPLAY_UNDERFLOW_COUNT)-underflow;
    c->missed_delta=io->read(ACCEL_MISSED_BOUNDARY_COUNT)-missed;
    c->writer_bursts_delta=io->read(ACCEL_WRITER_BURSTS)-bursts;
    c->writer_throttle_cycles_delta=io->read(ACCEL_WRITER_THROTTLE_CYCLES)-throttle;
    c->reader_frames_delta=io->read(ACCEL_READER_FRAME_COMPLETIONS)-frames;
    if(c->underflow_delta || c->missed_delta) return UINT32_C(0xE109);
    if(c->command_delta!=3u+2u*(r->warmups+r->samples) || c->swap_delta!=2u) return BENCH_ERR_COUNTS;
    c->draw_us_total=benchmark_us(c->draw_ticks_total,r->timer_hz);
    c->draw_us_mean=c->draw_us_total/r->samples;
    c->draw_us_min=benchmark_us(c->draw_ticks_min,r->timer_hz);
    c->draw_us_max=benchmark_us(c->draw_ticks_max,r->timer_hz);
    c->swap_us=benchmark_us(c->swap_ticks,r->timer_hz);
    c->rectangle_pixels_total=(uint64_t)c->width*c->height*r->samples;
    c->opaque_pixels_total=c->op==ACCEL_OP_COLOR_KEY ? c->rectangle_pixels_total/2u : c->rectangle_pixels_total;
    /* samples<=64, pixels<=1920*1080, hz<=UINT32_MAX: these products fit u64.
     * Rectangle throughput counts transparent pixels too; neither rate is an
     * AXI bandwidth measurement or displayed FPS. CPU polls throughout. */
    c->rectangle_pixels_per_second=c->rectangle_pixels_total*r->timer_hz/c->draw_ticks_total;
    c->opaque_pixels_per_second=c->opaque_pixels_total*r->timer_hz/c->draw_ticks_total;
    c->complete=1;
    return 0;
}
static uint32_t benchmark_run(const benchmark_io_t *io,volatile benchmark_result_t *r,
                              uint32_t samples,uint32_t warmups,uint32_t timer_hz) {
    static const uint32_t widths[4]={64,320,640,1920},heights[4]={64,240,480,1080};
    uint32_t i,e=0;
    uint64_t start,end,delta;
    /* Volatile byte stores do not require a freestanding memset implementation. */
    for(i=0;i<sizeof(*r);++i) ((volatile unsigned char *)r)[i]=0;
    r->schema_version=1;r->timer_hz=timer_hz;r->samples=samples;r->warmups=warmups;
    r->case_count=BENCHMARK_CASE_COUNT;r->phase=BENCH_PREPARE;
    r->id=io->read(ACCEL_ID);r->version=io->read(ACCEL_VERSION);
    r->capabilities=io->read(ACCEL_CAPABILITIES);
    r->service_read_quota=io->read(ACCEL_SERVICE_READ_QUOTA);
    r->service_watermarks=io->read(ACCEL_SERVICE_WATERMARKS);
    r->command_baseline=io->read(ACCEL_COMMAND_COUNT);r->swap_baseline=io->read(ACCEL_SWAP_COUNT);
    r->underflow_baseline=io->read(ACCEL_DISPLAY_UNDERFLOW_COUNT);
    r->missed_baseline=io->read(ACCEL_MISSED_BOUNDARY_COUNT);
    if(!samples || samples>64u || warmups>8u || !timer_hz ||
       r->id!=ACCEL_ID_EXPECTED || r->version!=ACCEL_VERSION_EXPECTED ||
       r->capabilities!=ACCEL_CAPABILITIES_EXPECTED || io->read(ACCEL_WIDTH)!=1920u ||
       io->read(ACCEL_HEIGHT)!=1080u || io->read(ACCEL_STRIDE)!=7680u ||
       r->service_read_quota!=128u || r->service_watermarks!=UINT32_C(0x02000180) ||
       !(io->read(ACCEL_SERVICE_STATUS)&(1u<<5))) e=BENCH_ERR_CONFIG;
    if(!e) e=benchmark_health(io,r);
    if(!e) {
        r->timer_read_ticks_min=UINT64_MAX;
        for(i=0;i<16u;++i) {
            start=io->ticks();end=io->ticks();
            if(end<=start) {e=BENCH_ERR_CLOCK;break;}
            delta=end-start;
            if(delta<r->timer_read_ticks_min) r->timer_read_ticks_min=delta;
        }
    }
    for(i=0;!e && i<BENCHMARK_CASE_COUNT;++i) {
        r->active_case=i;
        r->cases[i].width=widths[i/3u];r->cases[i].height=heights[i/3u];
        r->cases[i].op=i%3u;
        e=benchmark_case_run(io,r,&r->cases[i]);
        if(!e) ++r->completed_cases;
    }
    {
        uint32_t health=benchmark_health(io,r);
        if(!e) e=health;
    }
    if(!e && (r->command_delta!=r->commands_issued || r->commands_issued!=r->commands_completed ||
              r->swap_delta!=r->swaps_completed || r->swaps_requested!=r->swaps_completed)) e=BENCH_ERR_COUNTS;
    if(e) {r->error_code=e;r->failure_phase=r->phase;r->phase=BENCH_FAILED;return e;}
    r->phase=BENCH_FINISHED;r->pass=1;
    return 0;
}
#endif
