#ifndef M2_METRICS_H
#define M2_METRICS_H
#include <stdint.h>

typedef struct {
    uint32_t valid,fps_x100,last_frames;
    uint64_t last_render_ticks,last_min_ticks,last_max_ticks;
    uint64_t pending_ticks,pending_min,pending_max,window_start;
    uint32_t pending_frames;
} m2_metric_t;

/* Only completed render intervals enter the denominator. HUD and swap time
 * are outside this interval, and an empty window does not publish a value. */
static uint32_t m2_metric_add(volatile m2_metric_t *m,uint64_t hz,
                              uint64_t start,uint64_t finish) {
    uint64_t duration;
    if(finish<=start || !hz) return 1u;
    duration=finish-start;
    if(!m->pending_frames) {m->window_start=start;m->pending_min=duration;m->pending_max=duration;}
    m->pending_ticks+=duration;++m->pending_frames;
    if(duration<m->pending_min) m->pending_min=duration;
    if(duration>m->pending_max) m->pending_max=duration;
    if(finish-m->window_start>=hz) {
        m->fps_x100=(uint32_t)(((uint64_t)m->pending_frames*hz*100u)/m->pending_ticks);
        m->last_frames=m->pending_frames;m->last_render_ticks=m->pending_ticks;
        m->last_min_ticks=m->pending_min;m->last_max_ticks=m->pending_max;
        m->pending_frames=0;m->pending_ticks=0;m->valid=1;
    }
    return 0u;
}
static void m2_metric_publish(volatile m2_metric_t *m,uint64_t hz) {
    if(m->pending_frames && m->pending_ticks) {
        m->fps_x100=(uint32_t)(((uint64_t)m->pending_frames*hz*100u)/m->pending_ticks);
        m->last_frames=m->pending_frames;m->last_render_ticks=m->pending_ticks;
        m->last_min_ticks=m->pending_min;m->last_max_ticks=m->pending_max;
        m->pending_frames=0;m->pending_ticks=0;m->valid=1;
    }
}
static uint32_t m2_speedup_x100(const volatile m2_metric_t *cpu,
                                const volatile m2_metric_t *fpga) {
    if(!cpu->valid || !fpga->valid || !cpu->fps_x100) return 0u;
    return (uint32_t)(((uint64_t)fpga->fps_x100*100u)/cpu->fps_x100);
}
/* Called only after a completed safe swap. The first presented frame establishes
 * the origin; all earlier loading/render time is excluded from the five seconds. */
static uint32_t m2_stage_done(uint32_t presents,uint64_t first_present,
                              uint64_t now,uint64_t hz,uint32_t seconds) {
    return presents && now>=first_present && hz &&
           now-first_present>=(uint64_t)seconds*hz;
}
#endif
