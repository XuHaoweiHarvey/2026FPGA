#ifndef M2_SCENE_H
#define M2_SCENE_H
#include <stdint.h>

#ifndef RECT_COUNT
#define RECT_COUNT 24u
#endif
#if RECT_COUNT < 1 || RECT_COUNT > 64
#error "RECT_COUNT must be in 1..64"
#endif
#define M2_VIEW_X 640u
#define M2_VIEW_Y 300u
#define M2_VIEW_W 640u
#define M2_VIEW_H 480u
#define M2_BACKGROUND UINT32_C(0x00101928)
#define M2_ASSET_BASE UINT32_C(0x01000000)
#define M2_IMAGE_BYTES UINT32_C(0x0012c000)
#define M2_IMAGE_COUNT 3u

typedef struct {
    int32_t x,y,vx,vy;
    uint32_t w,h,color;
} m2_rect_t;
typedef struct {
    uint32_t scene,frame_number,image_index,clear_full,old_count,rect_count;
    uint32_t back_base,back_slot;
    m2_rect_t old_rects[RECT_COUNT];
    m2_rect_t new_rects[RECT_COUNT];
} m2_task_t;
typedef struct {
    m2_rect_t motion[RECT_COUNT];
    m2_rect_t slot_rects[2][RECT_COUNT];
    uint32_t slot_has_rects[2],slot_needs_clear[2],frame_number;
} m2_scene_state_t;

static uint32_t m2_rand(uint32_t *seed) {
    *seed=*seed*UINT32_C(1664525)+UINT32_C(1013904223);
    return *seed;
}
static void m2_scene_reset(m2_scene_state_t *s) {
    uint32_t i,seed=UINT32_C(0x6d325e71);
    s->frame_number=0;
    for(i=0;i<2u;++i) {s->slot_has_rects[i]=0;s->slot_needs_clear[i]=1;}
    for(i=0;i<RECT_COUNT;++i) {
        m2_rect_t *r=&s->motion[i];
        uint32_t v=m2_rand(&seed);
        r->w=12u+(v&31u);r->h=12u+((v>>5)&31u);
        r->x=(int32_t)(m2_rand(&seed)%(M2_VIEW_W-r->w));
        r->y=(int32_t)(m2_rand(&seed)%(M2_VIEW_H-r->h));
        v=m2_rand(&seed);
        r->vx=(v&1u ? 1 : -1)*(int32_t)(1u+((v>>1)&3u));
        r->vy=(v&8u ? 1 : -1)*(int32_t)(1u+((v>>4)&3u));
        r->color=UINT32_C(0x00303030) | ((v>>8)&UINT32_C(0x00cfcfcf));
    }
}
static void m2_step_one(m2_rect_t *r) {
    int32_t x=r->x+r->vx,y=r->y+r->vy;
    if(x<0 || x+(int32_t)r->w>(int32_t)M2_VIEW_W) {
        r->vx=-r->vx;x=r->x+r->vx;
    }
    if(y<0 || y+(int32_t)r->h>(int32_t)M2_VIEW_H) {
        r->vy=-r->vy;y=r->y+r->vy;
    }
    r->x=x;r->y=y;
}
/* This immutable task is consumed by either renderer. Commit slot history only
 * after its Back image has actually reached Front through a successful swap. */
static void m2_make_task(m2_scene_state_t *s,m2_task_t *t,uint32_t scene,uint32_t back) {
    uint32_t i,slot=back==UINT32_C(0x00800000) ? 1u : 0u;
    t->scene=scene;t->back_base=back;t->back_slot=slot;
    t->frame_number=s->frame_number;t->image_index=s->frame_number%M2_IMAGE_COUNT;
    t->rect_count=scene==0u ? RECT_COUNT : 0u;
    t->clear_full=scene==0u && s->slot_needs_clear[slot];
    t->old_count=scene==0u && !t->clear_full && s->slot_has_rects[slot] ? RECT_COUNT : 0u;
    for(i=0;i<t->old_count;++i) t->old_rects[i]=s->slot_rects[slot][i];
    if(scene==0u) for(i=0;i<RECT_COUNT;++i) t->new_rects[i]=s->motion[i];
}
static void m2_commit_task(m2_scene_state_t *s,const m2_task_t *t) {
    uint32_t i;
    if(t->scene==0u) {
        for(i=0;i<RECT_COUNT;++i) {
            s->slot_rects[t->back_slot][i]=t->new_rects[i];
            m2_step_one(&s->motion[i]);
        }
        s->slot_has_rects[t->back_slot]=1u;
        s->slot_needs_clear[t->back_slot]=0u;
    } else s->slot_has_rects[t->back_slot]=0u;
    ++s->frame_number;
}
#endif
