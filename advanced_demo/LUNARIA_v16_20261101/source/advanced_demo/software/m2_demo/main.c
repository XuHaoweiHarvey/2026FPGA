/* M2 competition loop: identical complete frame tasks on CPU and FPGA. */
#include "../apb_reg_test/accel_api.h"
#include "../apb_reg_test/benchmark_clock.h"
#include "../m1b_compare/hud.h"
#include "scene.h"
#include "assets.h"
#include "metrics.h"
#include "render.h"

#if !defined(SYSTEM_DDR_BMB) || SYSTEM_DDR_BMB != 0x1000
#error "M2 requires the verified uncached M1a DDR alias"
#endif
#define M2_PHASE_SECONDS 5u
#define M2_FRAME_TIMEOUT_SECONDS 300u
#define M2_ASSET_BEGIN 1u
#define M2_ASSET_SEAL 2u
#define M2_ASSET_LOADING 1u
#define M2_ASSET_READY 2u
#define M2_ASSET_FEATURE UINT32_C(0x80000000)
enum {M2_RECT=0,M2_IMAGE=1,M2_CPU=0,M2_FPGA=1};
enum {M2_BOOT=1,M2_ASSET_WRITE=2,M2_ASSET_VERIFY=3,M2_ASSET_SEALING=4,
      M2_FRAME_RENDER=5,M2_FRAME_HUD=6,M2_FRAME_SWAP=7,M2_RUNNING=8,M2_FAILED=255};
enum {M2_ERR_CONFIG=0xe400,M2_ERR_SESSION=0xe401,M2_ERR_ASSET=0xe402,
      M2_ERR_FRAME=0xe403,M2_ERR_CLOCK=0xe404,M2_ERR_HEALTH=0xe405,
      M2_ERR_ROLE=0xe406,M2_ERR_TIMEOUT=0xe407};

typedef struct {
    uint32_t schema,phase,error,scene,mode,cycle,frame,rect_count;
    uint32_t front,back,asset_status,cpu_status,cpu_error,reader_error;
    uint32_t underflow_base,missed_base,underflow_delta,missed_delta;
    uint32_t swap_base,swap_delta,command_base,command_delta;
    uint32_t asset_rows_written,asset_rows_verified,asset_image;
    uint32_t asset_hash[3],asset_verify_hash[3],asset_expected,asset_actual;
    uint32_t asset_error_x,asset_error_y,recovery_error,row_progress;
    uint32_t stage_presents,presented_fps_x100[2][2];
    uint64_t asset_write_ticks,asset_verify_ticks,asset_total_ticks;
    uint64_t stage_first_present_ticks,stage_last_present_ticks;
    uint32_t stage_presents_log[2][2];
    uint64_t stage_first_present_log[2][2],stage_last_present_log[2][2];
    uint64_t frame_render_ticks,frame_hud_ticks,frame_swap_ticks;
    m2_metric_t metric[2][2][2]; /* scene, executor, transition/steady */
} m2_result_t;
volatile m2_result_t g_m2_result;
static m2_scene_state_t m2_state;
static m2_task_t m2_task;

static uint32_t m2_read32(uintptr_t p) {return *(volatile uint32_t *)p;}
static uint64_t m2_ticks(void) {
    uint64_t t;
    __asm__ volatile ("fence iorw,iorw" ::: "memory");
    t=benchmark_clock_read(m2_read32);
    __asm__ volatile ("fence iorw,iorw" ::: "memory");
    return t;
}
static volatile uint32_t *m2_ddr(uint32_t phys) {
    return (volatile uint32_t *)(uintptr_t)(SYSTEM_DDR_BMB+phys);
}
__attribute__((noinline,noreturn)) void m2_error_stop(void) {
    for(;;) __asm__ volatile ("nop" ::: "memory");
}
static void m2_fail(uint32_t e) {
    g_m2_result.error=e;g_m2_result.phase=M2_FAILED;
    g_m2_result.asset_status=accel_read(ACCEL_ASSET_STATUS);
    g_m2_result.cpu_status=accel_read(ACCEL_CPU_DDR_STATUS);
    g_m2_result.cpu_error=accel_read(ACCEL_CPU_DDR_ERROR);
    g_m2_result.reader_error=accel_read(ACCEL_READER_ERROR);
    g_m2_result.underflow_delta=accel_read(ACCEL_DISPLAY_UNDERFLOW_COUNT)-g_m2_result.underflow_base;
    g_m2_result.missed_delta=accel_read(ACCEL_MISSED_BOUNDARY_COUNT)-g_m2_result.missed_base;
    m2_error_stop();
}
static void m2_require(uint32_t e) {if(e) m2_fail(e);}
static uint32_t m2_wait_session(uint32_t mask,uint32_t value) {
    uint32_t i,s;
    for(i=0;i<ACCEL_POLL_LIMIT;++i) {
        s=accel_read(ACCEL_CPU_DDR_STATUS);
        if((s&mask)==value) return 0;
    }
    return M2_ERR_SESSION;
}
static void m2_session_begin(void) {
    uint32_t s=accel_read(ACCEL_CPU_DDR_STATUS);
    if((s&7u) || accel_read(ACCEL_CPU_DDR_ERROR)) m2_fail(M2_ERR_SESSION);
    accel_write(ACCEL_CPU_DDR_CONTROL,1u);
    m2_require(m2_wait_session(1u,1u));
}
static void m2_session_end(void) {
    __asm__ volatile ("fence iorw,iorw" ::: "memory");
    m2_require(m2_wait_session(2u,0u));
    if(accel_read(ACCEL_CPU_DDR_ERROR) || (accel_read(ACCEL_CPU_DDR_STATUS)&4u))
        m2_fail(M2_ERR_SESSION);
    accel_write(ACCEL_CPU_DDR_CONTROL,2u);
    m2_require(m2_wait_session(1u,0u));
}
static void m2_recover_debug_session(void) {
    uint32_t s=accel_read(ACCEL_CPU_DDR_STATUS);
    if(s&1u) {
        m2_require(m2_wait_session(2u,0u));
        accel_write(ACCEL_CPU_DDR_CONTROL,2u);
        m2_require(m2_wait_session(1u,0u));
    }
    g_m2_result.recovery_error=accel_read(ACCEL_CPU_DDR_ERROR);
    if(g_m2_result.recovery_error || (accel_read(ACCEL_CPU_DDR_STATUS)&4u)) {
        accel_write(ACCEL_CPU_DDR_CONTROL,4u);
        if(accel_read(ACCEL_CPU_DDR_ERROR) || (accel_read(ACCEL_CPU_DDR_STATUS)&4u))
            m2_fail(M2_ERR_SESSION);
    }
}
static void m2_health(void) {
    g_m2_result.underflow_delta=accel_read(ACCEL_DISPLAY_UNDERFLOW_COUNT)-g_m2_result.underflow_base;
    g_m2_result.missed_delta=accel_read(ACCEL_MISSED_BOUNDARY_COUNT)-g_m2_result.missed_base;
    g_m2_result.reader_error=accel_read(ACCEL_READER_ERROR);
    if(g_m2_result.underflow_delta || g_m2_result.missed_delta ||
       g_m2_result.reader_error || accel_error() ||
       !(accel_read(ACCEL_ASSET_STATUS)&M2_ASSET_READY) ||
       accel_read(ACCEL_CPU_DDR_ERROR) || (accel_read(ACCEL_CPU_DDR_STATUS)&7u))
        m2_fail(M2_ERR_HEALTH);
}
static void m2_asset_write(void) {
    uint32_t image,y,x,pixel,hash;
    uint64_t start=m2_ticks();
    g_m2_result.phase=M2_ASSET_WRITE;
    m2_session_begin();
    for(image=0;image<M2_IMAGE_COUNT;++image) {
        volatile uint32_t *dst=m2_ddr(m2_image_base(image));
        hash=UINT32_C(2166136261);
        g_m2_result.asset_image=image;
        for(y=0;y<M2_VIEW_H;++y) {
            for(x=0;x<M2_VIEW_W;++x) {
                pixel=m2_image_pixel(image,x,y);
                dst[y*M2_VIEW_W+x]=pixel;
                hash=(hash^pixel)*UINT32_C(16777619);
            }
            ++g_m2_result.asset_rows_written;
        }
        g_m2_result.asset_hash[image]=hash;
    }
    m2_session_end();
    g_m2_result.asset_write_ticks=m2_ticks()-start;
}
static void m2_asset_verify(void) {
    uint32_t image,y,x,pixel,want,hash;
    uint64_t start=m2_ticks();
    g_m2_result.phase=M2_ASSET_VERIFY;
    m2_session_begin();
    for(image=0;image<M2_IMAGE_COUNT;++image) {
        const volatile uint32_t *src=m2_ddr(m2_image_base(image));
        hash=UINT32_C(2166136261);
        g_m2_result.asset_image=image;
        for(y=0;y<M2_VIEW_H;++y) {
            for(x=0;x<M2_VIEW_W;++x) {
                pixel=src[y*M2_VIEW_W+x];want=m2_image_pixel(image,x,y);
                if(pixel!=want) {
                    g_m2_result.asset_error_x=x;g_m2_result.asset_error_y=y;
                    g_m2_result.asset_expected=want;g_m2_result.asset_actual=pixel;
                    m2_fail(M2_ERR_ASSET);
                }
                hash=(hash^pixel)*UINT32_C(16777619);
            }
            ++g_m2_result.asset_rows_verified;
        }
        g_m2_result.asset_verify_hash[image]=hash;
        if(g_m2_result.asset_hash[image] && hash!=g_m2_result.asset_hash[image])
            m2_fail(M2_ERR_ASSET);
    }
    m2_session_end();
    g_m2_result.asset_verify_ticks=m2_ticks()-start;
}
static void m2_assets_initialize(void) {
    uint32_t s=accel_read(ACCEL_ASSET_STATUS);
    uint64_t start=m2_ticks();
    if(!(s&M2_ASSET_FEATURE)) m2_fail(M2_ERR_CONFIG);
    if(!(s&M2_ASSET_READY)) {
        if(!(s&M2_ASSET_LOADING)) {
            accel_write(ACCEL_ASSET_CONTROL,M2_ASSET_BEGIN);
            if(accel_error() || !(accel_read(ACCEL_ASSET_STATUS)&M2_ASSET_LOADING))
                m2_fail(M2_ERR_ASSET);
        }
        m2_asset_write();m2_asset_verify();
        g_m2_result.phase=M2_ASSET_SEALING;
        if(accel_read(ACCEL_CPU_DDR_STATUS)&3u) m2_fail(M2_ERR_SESSION);
        accel_write(ACCEL_ASSET_CONTROL,M2_ASSET_SEAL);
        if(accel_error() || !(accel_read(ACCEL_ASSET_STATUS)&M2_ASSET_READY))
            m2_fail(M2_ERR_ASSET);
    } else m2_asset_verify(); /* IDE restart: verify retained sealed DDR. */
    g_m2_result.asset_status=accel_read(ACCEL_ASSET_STATUS);
    g_m2_result.asset_total_ticks=m2_ticks()-start;
}
static void m2_fill_cpu(volatile uint32_t *dst,uint32_t x,uint32_t y,
                        uint32_t w,uint32_t h,uint32_t color,uint64_t start) {
    uint32_t row,col;
    for(row=0;row<h;++row) {
        for(col=0;col<w;++col) dst[(y+row)*1920u+x+col]=color;
        g_m2_result.row_progress=row+1u;
        if(m2_ticks()-start>(uint64_t)M2_FRAME_TIMEOUT_SECONDS*SYSTEM_CLINT_HZ)
            m2_fail(M2_ERR_TIMEOUT);
    }
}
static void m2_render_cpu(const m2_task_t *t,uint64_t start) {
    uint32_t i,y;
    volatile uint32_t *dst=m2_ddr(t->back_base);
    m2_session_begin();
    if(t->scene==M2_RECT) {
        if(t->clear_full) m2_fill_cpu(dst,M2_VIEW_X,M2_VIEW_Y,M2_VIEW_W,M2_VIEW_H,
                                     M2_BACKGROUND,start);
        else for(i=0;i<t->old_count;++i) {
            const m2_rect_t *r=&t->old_rects[i];
            m2_fill_cpu(dst,M2_VIEW_X+(uint32_t)r->x,M2_VIEW_Y+(uint32_t)r->y,
                        r->w,r->h,M2_BACKGROUND,start);
        }
        for(i=0;i<t->rect_count;++i) {
            const m2_rect_t *r=&t->new_rects[i];
            m2_fill_cpu(dst,M2_VIEW_X+(uint32_t)r->x,M2_VIEW_Y+(uint32_t)r->y,
                        r->w,r->h,r->color,start);
        }
    } else {
        const volatile uint32_t *src=m2_ddr(m2_image_base(t->image_index));
        for(y=0;y<M2_VIEW_H;++y) {
            m2_copy_image_row_cpu(dst+(M2_VIEW_Y+y)*1920u+M2_VIEW_X,
                                  src+y*M2_VIEW_W);
            g_m2_result.row_progress=y+1u;
            if(m2_ticks()-start>(uint64_t)M2_FRAME_TIMEOUT_SECONDS*SYSTEM_CLINT_HZ)
                m2_fail(M2_ERR_TIMEOUT);
        }
    }
    m2_session_end();
}
static void m2_fpga_fill(uint32_t x,uint32_t y,uint32_t w,uint32_t h,uint32_t color) {
    m2_require(accel_fill_rect(x,y,w,h,color));
    m2_require(accel_wait_done());
}
static void m2_render_fpga(const m2_task_t *t) {
    uint32_t i;
    if(t->scene==M2_RECT) {
        if(t->clear_full) m2_fpga_fill(M2_VIEW_X,M2_VIEW_Y,M2_VIEW_W,M2_VIEW_H,M2_BACKGROUND);
        else for(i=0;i<t->old_count;++i) {
            const m2_rect_t *r=&t->old_rects[i];
            m2_fpga_fill(M2_VIEW_X+(uint32_t)r->x,M2_VIEW_Y+(uint32_t)r->y,
                         r->w,r->h,M2_BACKGROUND);
        }
        for(i=0;i<t->rect_count;++i) {
            const m2_rect_t *r=&t->new_rects[i];
            m2_fpga_fill(M2_VIEW_X+(uint32_t)r->x,M2_VIEW_Y+(uint32_t)r->y,
                         r->w,r->h,r->color);
        }
    } else {
        m2_require(accel_blit(m2_image_base(t->image_index),M2_VIEW_W*4u,
                              M2_VIEW_X,M2_VIEW_Y,M2_VIEW_W,M2_VIEW_H));
        m2_require(accel_wait_done());
    }
}
static void m2_metric_record(uint32_t scene,uint32_t mode,uint32_t class_id,
                             uint64_t start,uint64_t finish) {
    volatile m2_metric_t *m=&g_m2_result.metric[scene][mode][class_id];
    if(m2_metric_add(m,SYSTEM_CLINT_HZ,start,finish)) m2_fail(M2_ERR_CLOCK);
}
static void m2_metric_flush(uint32_t scene,uint32_t mode,uint32_t class_id) {
    volatile m2_metric_t *m=&g_m2_result.metric[scene][mode][class_id];
    m2_metric_publish(m,SYSTEM_CLINT_HZ);
}
static void m2_hud_line(volatile uint32_t *dst,uint32_t y,const char *label,
                        const volatile m2_metric_t *m,uint32_t color) {
    char line[48],*p=line;
    p=m1b_append(p,label);
    p=m->valid ? m1b_fixed2(p,m->fps_x100) : m1b_append(p,"WAIT");
    *p=0;m1b_hud_text(dst,36u,y,line,color);
}
static void m2_draw_hud(uint32_t scene,uint32_t mode,uint32_t class_id,uint32_t back) {
    char line[48],*p;
    volatile uint32_t *dst=m2_ddr(back);
    const volatile m2_metric_t *cpu=&g_m2_result.metric[scene][M2_CPU][class_id];
    const volatile m2_metric_t *fpga=&g_m2_result.metric[scene][M2_FPGA][class_id];
    uint32_t speedup=0;
    m2_fpga_fill(16u,16u,590u,245u,UINT32_C(0x00081020));
    m2_session_begin();
    m2_hud_line(dst,38u,"CPU RENDER FPS ",cpu,UINT32_C(0x004bd9ef));
    m2_hud_line(dst,82u,"FPGA RENDER FPS ",fpga,UINT32_C(0x00e8e8f0));
    p=line;p=m1b_append(p,"HARDWARE SPEEDUP ");
    if(cpu->valid && fpga->valid && cpu->fps_x100) {
        speedup=m2_speedup_x100(cpu,fpga);
        p=m1b_fixed2(p,speedup);*p++='X';
    } else p=m1b_append(p,"WAIT");
    *p=0;m1b_hud_text(dst,36u,126u,line,UINT32_C(0x00ffd878));
    m1b_hud_text(dst,36u,170u,scene==M2_RECT ? "MOVING RECTANGLES" : "IMAGE SWITCHING",
                 UINT32_C(0x00ffffff));
    p=line;p=m1b_append(p,mode==M2_CPU ? "CPU " : "FPGA ");
    p=m1b_append(p,scene==M2_RECT ? "RECTANGLES " : "640X480 IMAGE ");
    if(scene==M2_RECT) p=m1b_u32(p,RECT_COUNT);
    *p=0;m1b_hud_text(dst,36u,214u,line,UINT32_C(0x00afc0d0));
    m2_session_end();
}
static void m2_startup_clear(void) {
    uint32_t i,ticket,back;
    for(i=0;i<2u;++i) {
        back=frame_get_back();
        m2_fpga_fill(0,0,1920u,1080u,M2_BACKGROUND);
        m2_require(frame_swap_request(&ticket));m2_require(frame_wait_swap_done(ticket));
        if(frame_get_front()!=back) m2_fail(M2_ERR_ROLE);
        m2_health();
    }
}
static void m2_run_stage(uint32_t scene,uint32_t mode) {
    uint64_t stage_wall=m2_ticks(),start,render_done,hud_start,swap_start,now;
    uint32_t back,ticket,class_id;
    g_m2_result.scene=scene;g_m2_result.mode=mode;g_m2_result.stage_presents=0;
    g_m2_result.stage_first_present_ticks=0;g_m2_result.stage_last_present_ticks=0;
    m2_scene_reset(&m2_state);
    for(;;) {
        g_m2_result.phase=M2_FRAME_RENDER;g_m2_result.row_progress=0;
        m2_health();
        back=frame_get_back();
        if(back!=0u && back!=UINT32_C(0x00800000)) m2_fail(M2_ERR_ROLE);
        start=m2_ticks();m2_make_task(&m2_state,&m2_task,scene,back);
        class_id=m2_task.clear_full ? 1u : 0u;
        if(mode==M2_CPU) m2_render_cpu(&m2_task,start);
        else m2_render_fpga(&m2_task);
        render_done=m2_ticks();
        if(render_done-start>(uint64_t)M2_FRAME_TIMEOUT_SECONDS*SYSTEM_CLINT_HZ)
            m2_fail(M2_ERR_TIMEOUT);
        g_m2_result.frame_render_ticks=render_done-start;
        m2_metric_record(scene,mode,class_id,start,render_done);
        if(scene==M2_RECT && m2_task.frame_number==1u)
            m2_metric_flush(scene,mode,1u);
        g_m2_result.phase=M2_FRAME_HUD;hud_start=m2_ticks();
        m2_draw_hud(scene,mode,class_id,back);
        g_m2_result.frame_hud_ticks=m2_ticks()-hud_start;
        g_m2_result.phase=M2_FRAME_SWAP;swap_start=m2_ticks();
        m2_require(frame_swap_request(&ticket));m2_require(frame_wait_swap_done(ticket));
        now=m2_ticks();g_m2_result.frame_swap_ticks=now-swap_start;
        if(frame_get_front()!=back || (accel_read(ACCEL_CPU_DDR_STATUS)&3u))
            m2_fail(M2_ERR_ROLE);
        m2_commit_task(&m2_state,&m2_task);
        ++g_m2_result.stage_presents;++g_m2_result.frame;
        if(g_m2_result.stage_presents==1u)
            g_m2_result.stage_first_present_ticks=now;
        g_m2_result.stage_last_present_ticks=now;
        if(now>stage_wall)
            g_m2_result.presented_fps_x100[scene][mode]=(uint32_t)(
                (uint64_t)g_m2_result.stage_presents*SYSTEM_CLINT_HZ*100u/(now-stage_wall));
        g_m2_result.front=frame_get_front();g_m2_result.back=frame_get_back();
        g_m2_result.command_delta=accel_read(ACCEL_COMMAND_COUNT)-g_m2_result.command_base;
        g_m2_result.swap_delta=accel_read(ACCEL_SWAP_COUNT)-g_m2_result.swap_base;
        m2_health();g_m2_result.phase=M2_RUNNING;
        if(m2_stage_done(g_m2_result.stage_presents,
                         g_m2_result.stage_first_present_ticks,now,
                         SYSTEM_CLINT_HZ,M2_PHASE_SECONDS)) break;
    }
    m2_metric_flush(scene,mode,0u);
    g_m2_result.stage_presents_log[scene][mode]=g_m2_result.stage_presents;
    g_m2_result.stage_first_present_log[scene][mode]=g_m2_result.stage_first_present_ticks;
    g_m2_result.stage_last_present_log[scene][mode]=g_m2_result.stage_last_present_ticks;
}
/* Stable debugger breakpoint after all four timed stages. */
__attribute__((noinline)) void m2_cycle_boundary(void) {
    ++g_m2_result.cycle;
    __asm__ volatile ("" ::: "memory");
}
int main(void) {
    uint32_t e;
    __asm__ volatile ("csrci mstatus,8" ::: "memory");
    g_m2_result.schema=1u;g_m2_result.phase=M2_BOOT;g_m2_result.rect_count=RECT_COUNT;
    e=accel_init();m2_require(e);
    if(!(accel_read(ACCEL_CPU_DDR_STATUS)&16u)) m2_fail(M2_ERR_CONFIG);
    m2_recover_debug_session();
    m2_require(display_wait_frames(3u));
    g_m2_result.underflow_base=accel_read(ACCEL_DISPLAY_UNDERFLOW_COUNT);
    g_m2_result.missed_base=accel_read(ACCEL_MISSED_BOUNDARY_COUNT);
    g_m2_result.command_base=accel_read(ACCEL_COMMAND_COUNT);
    g_m2_result.swap_base=accel_read(ACCEL_SWAP_COUNT);
    m2_assets_initialize();m2_health();m2_startup_clear();
    for(;;) {
        m2_run_stage(M2_RECT,M2_CPU);
        m2_run_stage(M2_RECT,M2_FPGA);
        m2_run_stage(M2_IMAGE,M2_CPU);
        m2_run_stage(M2_IMAGE,M2_FPGA);
        m2_cycle_boundary();
    }
}
