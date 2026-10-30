/* M1b: real RV32 pixel loops versus the existing FPGA accelerator. */
#include "../apb_reg_test/accel_api.h"
#include "../apb_reg_test/benchmark_clock.h"
#include "software_render.h"
#include "hud.h"

#if !defined(SYSTEM_DDR_BMB) || SYSTEM_DDR_BMB != 0x1000
#error "M1b requires the verified M1a CPU DDR alias"
#endif
#ifndef M1B_SIZE_INDEX
#define M1B_SIZE_INDEX 0u
#endif
#ifndef M1B_CPU_BUDGET_SECONDS
#define M1B_CPU_BUDGET_SECONDS 120u
#endif
#ifndef M1B_CYCLE_LIMIT
#define M1B_CYCLE_LIMIT 0u
#endif
#define M1B_STRIDE 1920u
#define M1B_SLOT1 UINT32_C(0x00800000)
#define M1B_BACKGROUND UINT32_C(0x00182838)
#define M1B_KEY UINT32_C(0x80ff00ff)
#define M1B_OPAQUE UINT32_C(0x40e8e8f0)
#define M1B_FILL UINT32_C(0x0030c0e0)
enum {M1B_CPU=0,M1B_FPGA=1};
enum {M1B_INIT=1,M1B_PREPARE=2,M1B_DRAW=3,M1B_VERIFY=4,
      M1B_HUD=5,M1B_PRESENT=6,M1B_RUNNING=7,M1B_FINISHED=8,M1B_FAILED=255};
enum {M1B_ERR_CONFIG=0xE300,M1B_ERR_SESSION=0xE301,
      M1B_ERR_CPU=0xE302,M1B_ERR_TIMEOUT=0xE303,
      M1B_ERR_PIXEL=0xE304,M1B_ERR_ROLE=0xE305,
      M1B_ERR_CLOCK=0xE306,M1B_ERR_HEALTH=0xE307};
typedef struct {
    uint32_t valid,width,height,pixels,front,back,hash,verified_pixels;
    uint32_t render_fps_x100,presented_fps_x100,underflow_delta,missed_delta;
    uint64_t prepare_ticks,session_ticks,pixel_ticks,drain_ticks;
    uint64_t submit_ticks,wait_ticks,render_ticks,verify_ticks,hud_ticks;
    uint64_t swap_ticks,present_ticks;
} m1b_sample_t;
typedef struct {
    uint32_t schema,pass,phase,error,cycle,op,mode,size_index;
    uint32_t width,height,expected,actual,error_x,error_y;
    uint32_t cpu_status,cpu_error,underflow_base,missed_base;
    uint32_t underflow_delta,missed_delta,reader_error,speedup_x100;
    uint32_t command_base,command_delta,swap_base,swap_delta;
    m1b_sample_t sample[3][2];
} m1b_result_t;
volatile m1b_result_t g_m1b_result;
volatile uint32_t g_m1b_cycle_limit=M1B_CYCLE_LIMIT;

static uint32_t m1b_read32(uintptr_t addr) {return *(volatile uint32_t *)addr;}
static uint64_t m1b_ticks(void) {
    uint64_t t;
    __asm__ volatile ("fence iorw,iorw" ::: "memory");
    t=benchmark_clock_read(m1b_read32);
    __asm__ volatile ("fence iorw,iorw" ::: "memory");
    return t;
}
__attribute__((noinline,noreturn)) void m1b_test_done(void) {
    for(;;) __asm__ volatile ("nop" ::: "memory");
}
static void m1b_fail(uint32_t e) {
    g_m1b_result.error=e;g_m1b_result.pass=0;g_m1b_result.phase=M1B_FAILED;
    g_m1b_result.cpu_status=accel_read(ACCEL_CPU_DDR_STATUS);
    g_m1b_result.cpu_error=accel_read(ACCEL_CPU_DDR_ERROR);
    g_m1b_result.underflow_delta=accel_read(ACCEL_DISPLAY_UNDERFLOW_COUNT)-g_m1b_result.underflow_base;
    g_m1b_result.missed_delta=accel_read(ACCEL_MISSED_BOUNDARY_COUNT)-g_m1b_result.missed_base;
    g_m1b_result.reader_error=accel_read(ACCEL_READER_ERROR);
    m1b_test_done();
}
static void m1b_check(uint32_t e) {if(e) m1b_fail(e);}
static uint32_t m1b_wait_cpu(uint32_t mask,uint32_t value) {
    uint32_t i,status;
    for(i=0;i<ACCEL_POLL_LIMIT;++i) {
        status=accel_read(ACCEL_CPU_DDR_STATUS);
        if((status&mask)==value) return 0;
    }
    return M1B_ERR_SESSION;
}
static uint32_t m1b_begin(void) {
    uint32_t s=accel_read(ACCEL_CPU_DDR_STATUS);
    if((s&7u) || accel_read(ACCEL_CPU_DDR_ERROR)) return M1B_ERR_SESSION;
    accel_write(ACCEL_CPU_DDR_CONTROL,1u);
    return m1b_wait_cpu(1u,1u);
}
static uint32_t m1b_end(void) {
    uint32_t e;
    __asm__ volatile ("fence iorw,iorw" ::: "memory");
    e=m1b_wait_cpu(2u,0u);if(e) return e;
    if(accel_read(ACCEL_CPU_DDR_ERROR) || (accel_read(ACCEL_CPU_DDR_STATUS)&4u))
        return M1B_ERR_CPU;
    accel_write(ACCEL_CPU_DDR_CONTROL,2u);
    return m1b_wait_cpu(1u,0u);
}
static volatile uint32_t *m1b_pixels(uint32_t base) {
    return (volatile uint32_t *)(uintptr_t)(SYSTEM_DDR_BMB+base);
}
static void m1b_health(void) {
    g_m1b_result.underflow_delta=accel_read(ACCEL_DISPLAY_UNDERFLOW_COUNT)-g_m1b_result.underflow_base;
    g_m1b_result.missed_delta=accel_read(ACCEL_MISSED_BOUNDARY_COUNT)-g_m1b_result.missed_base;
    g_m1b_result.reader_error=accel_read(ACCEL_READER_ERROR);
    if(g_m1b_result.underflow_delta || g_m1b_result.missed_delta ||
       g_m1b_result.reader_error || accel_error()) m1b_fail(M1B_ERR_HEALTH);
}
static void m1b_issue(uint32_t op,uint32_t source,uint32_t x,uint32_t y,
                      uint32_t w,uint32_t h,uint32_t color) {
    m1b_check(accel_submit(op,source,7680u,x,y,w,h,color));
    m1b_check(accel_wait_done());
}
static void m1b_prepare(uint32_t w,uint32_t h) {
    uint32_t ticket,back=frame_get_back();
    m1b_issue(ACCEL_OP_FILL,0,0,0,1920,1080,M1B_KEY);
    m1b_issue(ACCEL_OP_FILL,0,w/2u,0,w/2u,h,M1B_OPAQUE);
    m1b_check(frame_swap_request(&ticket));m1b_check(frame_wait_swap_done(ticket));
    if(frame_get_front()!=back || frame_get_back()==back) m1b_fail(M1B_ERR_ROLE);
    m1b_issue(ACCEL_OP_FILL,0,0,0,1920,1080,M1B_BACKGROUND);
    m1b_health();
}
static uint32_t m1b_expected(uint32_t op,uint32_t col,uint32_t w) {
    if(op==ACCEL_OP_FILL) return M1B_FILL;
    if(col>=w/2u) return M1B_OPAQUE;
    return op==ACCEL_OP_COLOR_KEY ? M1B_BACKGROUND : M1B_KEY;
}
static void m1b_draw_cpu(uint32_t op,uint32_t front,uint32_t back,
                          uint32_t x,uint32_t y,uint32_t w,uint32_t h,
                          volatile m1b_sample_t *s) {
    volatile uint32_t *dst=m1b_pixels(back);
    const volatile uint32_t *src=m1b_pixels(front);
    uint32_t row;
    uint64_t t0=m1b_ticks(),t1,t2,t3,budget=(uint64_t)M1B_CPU_BUDGET_SECONDS*SYSTEM_CLINT_HZ;
    m1b_check(m1b_begin());t1=m1b_ticks();
    if(op==ACCEL_OP_FILL) {
        for(row=0;row<h;++row) {
            m1b_software_fill(dst,M1B_STRIDE,x,y+row,w,1u,M1B_FILL);
            if(m1b_ticks()-t1>budget) {m1b_check(m1b_end());m1b_fail(M1B_ERR_TIMEOUT);}
        }
    } else {
        for(row=0;row<h;++row) {
            m1b_software_blit(dst,src+row*M1B_STRIDE,M1B_STRIDE,x,y+row,w,1u,
                               op==ACCEL_OP_COLOR_KEY,M1B_KEY);
            if(m1b_ticks()-t1>budget) {m1b_check(m1b_end());m1b_fail(M1B_ERR_TIMEOUT);}
        }
    }
    t2=m1b_ticks();m1b_check(m1b_end());t3=m1b_ticks();
    if(t3<=t0 || t2<=t1) m1b_fail(M1B_ERR_CLOCK);
    s->session_ticks=t1-t0;s->pixel_ticks=t2-t1;
    s->drain_ticks=t3-t2;s->render_ticks=t3-t0;
}
static void m1b_draw_fpga(uint32_t op,uint32_t front,uint32_t x,uint32_t y,
                           uint32_t w,uint32_t h,volatile m1b_sample_t *s) {
    uint64_t t0=m1b_ticks(),t1,t2;
    m1b_check(accel_submit(op,op==ACCEL_OP_FILL ? 0u : front,7680u,x,y,w,h,
                            op==ACCEL_OP_FILL ? M1B_FILL : M1B_KEY));
    t1=m1b_ticks();m1b_check(accel_wait_done());t2=m1b_ticks();
    if(t2<=t0) m1b_fail(M1B_ERR_CLOCK);
    s->submit_ticks=t1-t0;s->wait_ticks=t2-t1;s->render_ticks=t2-t0;
}
static void m1b_verify(uint32_t op,uint32_t back,uint32_t x,uint32_t y,
                        uint32_t w,uint32_t h,volatile m1b_sample_t *s) {
    volatile uint32_t *dst=m1b_pixels(back);
    uint32_t row,col,want,got,hash=UINT32_C(2166136261);
    uint64_t start=m1b_ticks();
    uint64_t budget=(uint64_t)M1B_CPU_BUDGET_SECONDS*SYSTEM_CLINT_HZ;
    m1b_check(m1b_begin());
    for(row=0;row<h;++row) {
        for(col=0;col<w;++col) {
            got=dst[(y+row)*M1B_STRIDE+x+col];want=m1b_expected(op,col,w);
            if(got!=want) {
                g_m1b_result.error_x=x+col;g_m1b_result.error_y=y+row;
                g_m1b_result.expected=want;g_m1b_result.actual=got;
                m1b_check(m1b_end());m1b_fail(M1B_ERR_PIXEL);
            }
            hash=(hash^got)*UINT32_C(16777619);
            ++s->verified_pixels;
        }
        if(m1b_ticks()-start>budget) {m1b_check(m1b_end());m1b_fail(M1B_ERR_TIMEOUT);}
    }
    /* Check untouched pixels adjacent to the target when they exist. */
    if(x && (got=dst[y*M1B_STRIDE+x-1u])!=M1B_BACKGROUND) {
        g_m1b_result.error_x=x-1u;g_m1b_result.error_y=y;
        g_m1b_result.expected=M1B_BACKGROUND;g_m1b_result.actual=got;
        m1b_check(m1b_end());m1b_fail(M1B_ERR_PIXEL);
    }
    if(x+w<M1B_STRIDE && (got=dst[y*M1B_STRIDE+x+w])!=M1B_BACKGROUND) {
        g_m1b_result.error_x=x+w;g_m1b_result.error_y=y;
        g_m1b_result.expected=M1B_BACKGROUND;g_m1b_result.actual=got;
        m1b_check(m1b_end());m1b_fail(M1B_ERR_PIXEL);
    }
    m1b_check(m1b_end());s->hash=hash;s->verify_ticks=m1b_ticks()-start;
}
static uint32_t m1b_rate(uint64_t ticks) {
    if(!ticks) return 0;
    return (uint32_t)(((uint64_t)SYSTEM_CLINT_HZ*100u)/ticks);
}
static void m1b_hud(uint32_t back,uint32_t op,uint32_t w,uint32_t h,uint32_t mode) {
    char line[64],*p;
    volatile uint32_t *dst=m1b_pixels(back);
    volatile m1b_sample_t *cpu=&g_m1b_result.sample[op][M1B_CPU];
    volatile m1b_sample_t *fpga=&g_m1b_result.sample[op][M1B_FPGA];
    uint32_t color=UINT32_C(0x00ffffff),xx=1060u;
    m1b_check(m1b_begin());
    m1b_hud_text(dst,xx,48u,"M1B CPU FPGA COMPARISON",color);
    m1b_hud_text(dst,xx,84u,"CPU SOFTWARE RENDERING",UINT32_C(0x0030c0e0));
    m1b_hud_text(dst,xx,120u,"FPGA HARDWARE ACCELERATION",UINT32_C(0x00e8e8f0));
    p=line;p=m1b_append(p,op==0u ? "FILL " : op==1u ? "BLIT " : "COLOR KEY ");
    p=m1b_u32(p,w);*p++='X';p=m1b_u32(p,h);*p=0;
    m1b_hud_text(dst,xx,168u,line,color);
    p=line;p=m1b_append(p,"PIXELS ");p=m1b_u32(p,w*h);*p=0;
    m1b_hud_text(dst,xx,204u,line,color);
    p=line;p=m1b_append(p,"CPU RENDER FPS ");
    p=cpu->valid ? m1b_fixed2(p,cpu->render_fps_x100) : m1b_append(p,"WAIT");*p=0;
    m1b_hud_text(dst,xx,252u,line,UINT32_C(0x0030c0e0));
    p=line;p=m1b_append(p,"FPGA RENDER FPS ");
    p=fpga->valid ? m1b_fixed2(p,fpga->render_fps_x100) : m1b_append(p,"WAIT");*p=0;
    m1b_hud_text(dst,xx,288u,line,UINT32_C(0x00e8e8f0));
    p=line;p=m1b_append(p,"SPEEDUP ");
    p=cpu->valid && fpga->valid ? m1b_fixed2(p,g_m1b_result.speedup_x100) : m1b_append(p,"WAIT");
    *p++='X';*p=0;m1b_hud_text(dst,xx,336u,line,color);
    p=line;p=m1b_append(p,"LAST PRESENTED FPS ");
    p=g_m1b_result.sample[op][mode].present_ticks ?
      m1b_fixed2(p,g_m1b_result.sample[op][mode].presented_fps_x100) :
      m1b_append(p,"WAIT");*p=0;
    m1b_hud_text(dst,xx,384u,line,color);
    p=line;p=m1b_append(p,"UNDERFLOW ");p=m1b_u32(p,g_m1b_result.underflow_delta);*p=0;
    m1b_hud_text(dst,xx,432u,line,color);
    p=line;p=m1b_append(p,"MISSED ");p=m1b_u32(p,g_m1b_result.missed_delta);*p=0;
    m1b_hud_text(dst,xx,468u,line,color);
    m1b_hud_text(dst,xx,504u,"ERROR 0",color);
    m1b_hud_text(dst,xx,540u,mode==M1B_CPU ? "DISPLAY CPU" : "DISPLAY FPGA",color);
    m1b_check(m1b_end());
}
int main(void) {
    static const uint32_t widths[4]={64u,320u,640u,1920u};
    static const uint32_t heights[4]={64u,240u,480u,1080u};
    uint32_t op,mode,w,h,x,y,front,back,ticket,status;
    uint64_t frame_start,t0,t1;
    volatile m1b_sample_t *s;
    __asm__ volatile ("csrci mstatus,8" ::: "memory");
    g_m1b_result.schema=1u;g_m1b_result.phase=M1B_INIT;
    m1b_check(accel_init());
    if(M1B_SIZE_INDEX>3u || !(accel_read(ACCEL_CPU_DDR_STATUS)&16u))
        m1b_fail(M1B_ERR_CONFIG);
    /* Same recovery as M1a after an IDE restart; never reset the platform. */
    status=accel_read(ACCEL_CPU_DDR_STATUS);
    if(status&1u) {
        m1b_check(m1b_wait_cpu(2u,0u));
        accel_write(ACCEL_CPU_DDR_CONTROL,2u);
        m1b_check(m1b_wait_cpu(1u,0u));
    }
    accel_write(ACCEL_CPU_DDR_CONTROL,4u);
    m1b_check(display_wait_frames(3u));
    g_m1b_result.underflow_base=accel_read(ACCEL_DISPLAY_UNDERFLOW_COUNT);
    g_m1b_result.missed_base=accel_read(ACCEL_MISSED_BOUNDARY_COUNT);
    g_m1b_result.command_base=accel_read(ACCEL_COMMAND_COUNT);
    g_m1b_result.swap_base=accel_read(ACCEL_SWAP_COUNT);
    g_m1b_result.size_index=M1B_SIZE_INDEX;
    w=widths[M1B_SIZE_INDEX];h=heights[M1B_SIZE_INDEX];
    x=w==1920u ? 0u : 256u;y=h==1080u ? 0u : 256u;
    g_m1b_result.width=w;g_m1b_result.height=h;
    for(;;) {
        for(op=0;op<3u;++op) for(mode=0;mode<2u;++mode) {
            g_m1b_result.op=op;g_m1b_result.mode=mode;
            if(mode==M1B_CPU) {
                g_m1b_result.sample[op][M1B_FPGA].valid=0u;
                g_m1b_result.speedup_x100=0u;
            }
            s=&g_m1b_result.sample[op][mode];s->valid=0u;
            s->width=w;s->height=h;s->pixels=w*h;
            frame_start=m1b_ticks();g_m1b_result.phase=M1B_PREPARE;
            m1b_prepare(w,h);t0=m1b_ticks();s->prepare_ticks=t0-frame_start;
            front=frame_get_front();back=frame_get_back();
            if(front==back || (front!=0u && front!=M1B_SLOT1) ||
               (back!=0u && back!=M1B_SLOT1)) m1b_fail(M1B_ERR_ROLE);
            s->front=front;s->back=back;g_m1b_result.phase=M1B_DRAW;
            if(mode==M1B_CPU) m1b_draw_cpu(op,front,back,x,y,w,h,s);
            else m1b_draw_fpga(op,front,x,y,w,h,s);
            if(!s->render_ticks) m1b_fail(M1B_ERR_CLOCK);
            s->render_fps_x100=m1b_rate(s->render_ticks);
            g_m1b_result.phase=M1B_VERIFY;
            m1b_verify(op,back,x,y,w,h,s);m1b_health();
            if(mode==M1B_FPGA && s->hash!=g_m1b_result.sample[op][M1B_CPU].hash)
                m1b_fail(M1B_ERR_PIXEL);
            s->valid=1u;
            if(g_m1b_result.sample[op][M1B_CPU].valid &&
               g_m1b_result.sample[op][M1B_FPGA].valid)
                g_m1b_result.speedup_x100=(uint32_t)(
                    g_m1b_result.sample[op][M1B_CPU].render_ticks*100u /
                    g_m1b_result.sample[op][M1B_FPGA].render_ticks);
            g_m1b_result.phase=M1B_HUD;t0=m1b_ticks();
            /* HUD preparation is outside either timed render kernel. */
            m1b_issue(ACCEL_OP_FILL,0,1030u,24u,860u,570u,UINT32_C(0x00081020));
            m1b_hud(back,op,w,h,mode);t1=m1b_ticks();s->hud_ticks=t1-t0;
            g_m1b_result.phase=M1B_PRESENT;t0=m1b_ticks();
            m1b_check(frame_swap_request(&ticket));m1b_check(frame_wait_swap_done(ticket));
            t1=m1b_ticks();s->swap_ticks=t1-t0;s->present_ticks=t1-frame_start;
            s->presented_fps_x100=m1b_rate(s->present_ticks);
            if(frame_get_front()!=back) m1b_fail(M1B_ERR_ROLE);
            g_m1b_result.command_delta=accel_read(ACCEL_COMMAND_COUNT)-g_m1b_result.command_base;
            g_m1b_result.swap_delta=accel_read(ACCEL_SWAP_COUNT)-g_m1b_result.swap_base;
            m1b_health();
            s->underflow_delta=g_m1b_result.underflow_delta;
            s->missed_delta=g_m1b_result.missed_delta;
            g_m1b_result.phase=M1B_RUNNING;
        }
        ++g_m1b_result.cycle;g_m1b_result.pass=1u;
        if(g_m1b_cycle_limit && g_m1b_result.cycle>=g_m1b_cycle_limit) {
            g_m1b_result.phase=M1B_FINISHED;m1b_test_done();
        }
    }
}
