/* Native C software test. Models command completion/pixels, not RTL or DDR timing. */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "accel_benchmark.h"
#include "benchmark_clock.h"

static uint32_t regs[0xC8/4],pixels[2][1920*1080];
static uint32_t pending_op,pending_src,pending_x,pending_y,pending_w,pending_h,pending_color;
static uint32_t pending,issued,finished,swaps,tick_reads;
static uint32_t fail_wait,fail_submit,inject_underflow,inject_missed,lose_count,bad_roles,bad_reader;
static uint64_t now;
static int frozen,variable_latency;
static volatile benchmark_result_t result;
#define REG(name) regs[(name)/4]

static uint32_t read_reg(uint32_t offset) {assert(offset<sizeof(regs));return regs[offset/4];}
static uint64_t ticks(void) {++tick_reads;if(!frozen) now+=11;return now;}
static uint32_t submit(uint32_t op,uint32_t src,uint32_t stride,uint32_t x,uint32_t y,
                       uint32_t w,uint32_t h,uint32_t color) {
    assert(!pending);
    if(fail_submit && issued+1==fail_submit) return UINT32_C(0xE102);
    assert(w && h && x+w<=1920 && y+h<=1080);
    assert(!(x%4) && !(w%4));
    assert(REG(ACCEL_FRONT_BASE)!=REG(ACCEL_BACK_BASE));
    if(op!=ACCEL_OP_FILL) {
        assert(src==REG(ACCEL_FRONT_BASE));assert(stride==7680);
    }
    pending_op=op;pending_src=src;pending_x=x;pending_y=y;
    pending_w=w;pending_h=h;pending_color=color;pending=1;
    ++issued;++REG(ACCEL_COMMAND_COUNT);
    REG(ACCEL_STATUS)=ACCEL_INIT_DONE|ACCEL_BUSY;
    REG(ACCEL_BUFFER_STATUS)|=FRAME_WRITER_OWNED;
    return 0;
}
static uint32_t wait_done(void) {
    uint32_t x,y,v,back=REG(ACCEL_BACK_BASE)?1u:0u,front=pending_src?1u:0u;
    assert(pending);
    if(fail_wait && issued==fail_wait) {
        REG(ACCEL_ERROR_CODE)=0x23;return 0x23; /* Leave ownership held on failure. */
    }
    for(y=0;y<pending_h;++y) for(x=0;x<pending_w;++x) {
        v=pending_op==ACCEL_OP_FILL ? pending_color : pixels[front][y*1920+x];
        if(pending_op!=ACCEL_OP_COLOR_KEY || (v&0xFFFFFFu)!=(pending_color&0xFFFFFFu))
            pixels[back][(pending_y+y)*1920+pending_x+x]=v;
    }
    now+=100+(uint64_t)pending_w*pending_h/16;
    if(variable_latency) now+=(issued%3u)*7u;
    ++REG(ACCEL_READER_FRAME_COMPLETIONS); /* Synthetic progress, not performance. */
    REG(ACCEL_WRITER_BURSTS)+=(pending_w/4+31)/32*pending_h;
    REG(ACCEL_WRITER_THROTTLE_CYCLES)+=13;
    REG(ACCEL_STATUS)=ACCEL_INIT_DONE|ACCEL_DONE;
    REG(ACCEL_BUFFER_STATUS)&=~FRAME_WRITER_OWNED;
    pending=0;++finished;
    if(issued==inject_underflow) ++REG(ACCEL_DISPLAY_UNDERFLOW_COUNT);
    if(issued==inject_missed) ++REG(ACCEL_MISSED_BOUNDARY_COUNT);
    if(issued==lose_count) --REG(ACCEL_COMMAND_COUNT);
    return 0;
}
static uint32_t swap_request(uint32_t *ticket) {
    assert(!pending);
    assert(!(REG(ACCEL_BUFFER_STATUS)&FRAME_WRITER_OWNED));
    *ticket=REG(ACCEL_SWAP_COUNT)+1u;
    REG(ACCEL_BUFFER_STATUS)|=FRAME_SWAP_PENDING;
    return 0;
}
static uint32_t swap_wait(uint32_t ticket) {
    uint32_t old_front=REG(ACCEL_FRONT_BASE),old_back=REG(ACCEL_BACK_BASE);
    uint32_t slot=old_back?1u:0u;
    const volatile benchmark_case_t *c=&result.cases[result.active_case];
    assert(REG(ACCEL_BUFFER_STATUS)&FRAME_SWAP_PENDING);
    assert(ticket==REG(ACCEL_SWAP_COUNT)+1u);
    if(swaps%2u==0) {
        /* Preparation must put key/opaque in equal halves, including X bytes. */
        assert(pixels[slot][0]==UINT32_C(0x80FF00FF));
        assert(pixels[slot][c->width/2]==UINT32_C(0x40E8E8F0));
    } else {
        uint32_t expected=c->op==ACCEL_OP_COLOR_KEY ? UINT32_C(0x00182838) :
                          c->op==ACCEL_OP_FILL ? UINT32_C(0x40E8E8F0) : UINT32_C(0x80FF00FF);
        assert(pixels[slot][0]==expected);
        assert(pixels[slot][c->width/2]==UINT32_C(0x40E8E8F0));
        /* Source remains intact through all resets/draws. */
        assert(pixels[old_front?1u:0u][0]==UINT32_C(0x80FF00FF));
    }
    if(!bad_roles) {REG(ACCEL_FRONT_BASE)=old_back;REG(ACCEL_BACK_BASE)=old_front;}
    REG(ACCEL_READER_BASE)=bad_reader ? UINT32_C(0xDEAD0000) : REG(ACCEL_FRONT_BASE);
    REG(ACCEL_SWAP_COUNT)=ticket;++swaps;
    REG(ACCEL_BUFFER_STATUS)&=~FRAME_SWAP_PENDING;
    REG(ACCEL_BUFFER_STATUS)|=FRAME_SWAP_DONE;
    now+=700;
    return 0;
}
static const benchmark_io_t io={read_reg,ticks,submit,wait_done,swap_request,swap_wait};
static void reset(uint32_t initial_front) {
    memset(regs,0,sizeof(regs));memset(pixels,0,sizeof(pixels));
    pending=issued=finished=swaps=tick_reads=0;
    fail_wait=fail_submit=inject_underflow=inject_missed=lose_count=bad_roles=bad_reader=0;
    frozen=variable_latency=0;now=UINT64_C(0xFFFFFFF0);
    REG(ACCEL_ID)=ACCEL_ID_EXPECTED;REG(ACCEL_VERSION)=ACCEL_VERSION_EXPECTED;
    REG(ACCEL_CAPABILITIES)=ACCEL_CAPABILITIES_EXPECTED;
    REG(ACCEL_WIDTH)=1920;REG(ACCEL_HEIGHT)=1080;REG(ACCEL_STRIDE)=7680;
    REG(ACCEL_SERVICE_READ_QUOTA)=128;REG(ACCEL_SERVICE_WATERMARKS)=0x02000180;
    REG(ACCEL_SERVICE_STATUS)=1u<<5;REG(ACCEL_STATUS)=ACCEL_INIT_DONE;
    REG(ACCEL_BUFFER_STATUS)=FRAME_FRONT_VALID;
    REG(ACCEL_FRONT_BASE)=initial_front;REG(ACCEL_BACK_BASE)=initial_front^0x00800000u;
    REG(ACCEL_READER_BASE)=initial_front;
    REG(ACCEL_COMMAND_COUNT)=UINT32_C(0xFFFFFFFE);REG(ACCEL_SWAP_COUNT)=UINT32_C(0xFFFFFFFE);
    REG(ACCEL_DISPLAY_UNDERFLOW_COUNT)=7;REG(ACCEL_MISSED_BOUNDARY_COUNT)=3;
    REG(ACCEL_WRITER_BURSTS)=UINT32_C(0xFFFFFFFE);
    REG(ACCEL_WRITER_THROTTLE_CYCLES)=UINT32_C(0xFFFFFFFE);
}
static void normal(uint32_t initial_front,uint32_t samples,uint32_t warmups) {
    uint32_t i,expected=12u*(3u+2u*(samples+warmups));
    reset(initial_front);
    assert(benchmark_run(&io,&result,samples,warmups,SYSTEM_CLINT_HZ)==0);
    assert(result.pass==1 && result.completed_cases==12 && result.phase==BENCH_FINISHED);
    assert(result.commands_issued==expected && result.commands_completed==expected);
    assert(result.command_delta==expected && result.swap_delta==24);
    assert(issued==expected && finished==expected && swaps==24);
    assert(result.underflow_baseline==7 && result.missed_baseline==3);
    assert(result.underflow_delta==0 && result.missed_delta==0);
    assert(REG(ACCEL_FRONT_BASE)==initial_front);
    assert(now>UINT64_C(0x100000000));assert(result.timer_read_ticks_min==11);
    for(i=0;i<12;++i) {
        const volatile benchmark_case_t *c=&result.cases[i];
        uint64_t each=111+(uint64_t)c->width*c->height/16;
        uint64_t area=(uint64_t)c->width*c->height*samples;
        assert(c->complete && c->op==i%3 && c->samples_completed==samples);
        assert(c->draw_ticks_total==each*samples);
        assert(c->draw_ticks_min==each && c->draw_ticks_max==each && c->swap_ticks==711);
        assert(c->draw_us_total==benchmark_us(each*samples,SYSTEM_CLINT_HZ));
        assert(c->draw_us_mean==benchmark_us(each,SYSTEM_CLINT_HZ));
        assert(c->rectangle_pixels_total==area);
        assert(c->opaque_pixels_total==(c->op==ACCEL_OP_COLOR_KEY ? area/2 : area));
        assert(c->rectangle_pixels_per_second==area*SYSTEM_CLINT_HZ/(each*samples));
        assert(c->command_delta==expected/12 && c->swap_delta==2);
        assert(c->writer_bursts_delta>0 && c->reader_frames_delta==expected/12);
    }
}
static uint32_t clock_step;
static uint32_t rollover_read(uintptr_t address) {
    static const uint32_t values[6]={0,UINT32_MAX,1,1,7,1};
    static const uint32_t offsets[6]={4,0,4,4,0,4};
    assert(clock_step<6);
    assert(address==(uintptr_t)SYSTEM_CLINT_CTRL+0xBFF8u+offsets[clock_step]);
    return values[clock_step++];
}
int main(void) {
    uint32_t i;
    clock_step=0;
    assert(benchmark_clock_read(rollover_read)==UINT64_C(0x100000007));
    assert(clock_step==6);
    assert(benchmark_us(UINT64_C(100000001),100000000)==1000000);
    assert(benchmark_us(UINT64_C(8640000000000),100000000)==UINT64_C(86400000000));
    normal(0,8,1);normal(0x00800000,1,0);normal(0,64,8);
    reset(0);variable_latency=1;
    assert(benchmark_run(&io,&result,2,1,SYSTEM_CLINT_HZ)==0);
    assert(result.cases[0].draw_ticks_min==367);
    assert(result.cases[0].draw_ticks_max==374);
    assert(result.cases[0].draw_ticks_total==741);
    assert(result.cases[0].draw_us_mean==3);
    reset(0);frozen=1;
    assert(benchmark_run(&io,&result,8,1,SYSTEM_CLINT_HZ)==BENCH_ERR_CLOCK);
    assert(!issued && !swaps && !result.pass);
    for(i=0;i<4;++i) {
        reset(0);
        assert(benchmark_run(&io,&result,i==0 ? 0 : i==1 ? 65 : 8,
               i==2 ? 9 : 1,i==3 ? 0 : SYSTEM_CLINT_HZ)==BENCH_ERR_CONFIG);
        assert(!issued && !swaps && !result.pass);
    }
    reset(0);REG(ACCEL_VERSION)=0x40000;
    assert(benchmark_run(&io,&result,8,1,SYSTEM_CLINT_HZ)==BENCH_ERR_CONFIG);
    assert(!issued);
    reset(0);REG(ACCEL_READER_ERROR)=0x2003;
    assert(benchmark_run(&io,&result,8,1,SYSTEM_CLINT_HZ)==0xE108);
    assert(!issued && !result.pass);
    reset(0);fail_wait=7;
    assert(benchmark_run(&io,&result,8,1,SYSTEM_CLINT_HZ)==0x23);
    assert(!result.pass && !result.cases[0].complete && swaps==1 && issued==7 && finished==6);
    assert(pending && (REG(ACCEL_BUFFER_STATUS)&FRAME_WRITER_OWNED));
    reset(0);fail_submit=6;
    assert(benchmark_run(&io,&result,8,1,SYSTEM_CLINT_HZ)==0xE102);
    assert(!result.pass && swaps==1 && issued==5 && !pending);
    reset(0);inject_underflow=7;
    assert(benchmark_run(&io,&result,8,1,SYSTEM_CLINT_HZ)==0xE109);
    assert(!result.pass && result.underflow_delta==1 && swaps==1);
    reset(0);inject_missed=7;
    assert(benchmark_run(&io,&result,8,1,SYSTEM_CLINT_HZ)==0xE109);
    assert(!result.pass && result.missed_delta==1 && swaps==1);
    reset(0);lose_count=7;
    assert(benchmark_run(&io,&result,8,1,SYSTEM_CLINT_HZ)==BENCH_ERR_COUNTS);
    assert(!result.pass && !result.cases[0].complete && result.completed_cases==0);
    reset(0);bad_roles=1;
    assert(benchmark_run(&io,&result,8,1,SYSTEM_CLINT_HZ)==BENCH_ERR_BUFFERS);
    assert(!result.pass && swaps==1);
    reset(0);bad_reader=1;
    assert(benchmark_run(&io,&result,8,1,SYSTEM_CLINT_HZ)==BENCH_ERR_BUFFERS);
    assert(!result.pass && !result.cases[0].complete);
    puts("PASS benchmark software: 12 cases, pixel/key preservation, timing/accounting, counter/clock rollover, configuration and fault stop");
    puts("Native behavioral backend only; no RISC-V instructions, RTL, DDR timing or hardware measurements.");
    return 0;
}
