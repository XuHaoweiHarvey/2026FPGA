#include <stdint.h>
#include "../software/m2_demo/scene.h"
#include "../software/m2_demo/assets.h"
#include "../software/m2_demo/metrics.h"
#include "../software/m2_demo/render.h"

volatile uint32_t g_m2_check_result;
__attribute__((noinline,noreturn)) void m2_checks_done(void) {
    for(;;) __asm__ volatile ("nop");
}
#define CHECK(expr,code) do {if(!(expr)) {g_m2_check_result=(code);m2_checks_done();}} while(0)

static uint32_t rect_equal(const m2_rect_t *a,const m2_rect_t *b) {
    return a->x==b->x && a->y==b->y && a->vx==b->vx && a->vy==b->vy &&
           a->w==b->w && a->h==b->h && a->color==b->color;
}
int main(void) {
    static m2_scene_state_t cpu,fpga;
    static m2_task_t a,b;
    static m2_rect_t prior_cpu[2][RECT_COUNT],prior_fpga[2][RECT_COUNT];
    static m2_metric_t cm,fm;
    static volatile uint32_t source[640*480],target[640*480];
    uint32_t frame,i,slot,back,image,y,x;
    m2_scene_reset(&cpu);m2_scene_reset(&fpga);
    for(frame=0;frame<12u;++frame) {
        slot=frame&1u;back=slot ? UINT32_C(0x00800000) : 0u;
        m2_make_task(&cpu,&a,0u,back);
        m2_make_task(&fpga,&b,0u,back^UINT32_C(0x00800000));
        CHECK(a.frame_number==frame && b.frame_number==frame,1);
        CHECK(a.back_slot==slot && b.back_slot==1u-slot && a.rect_count==RECT_COUNT,2);
        CHECK(a.clear_full==(frame<2u) && b.clear_full==a.clear_full,3);
        CHECK(a.old_count==(frame<2u ? 0u : RECT_COUNT) && b.old_count==a.old_count,4);
        for(i=0;i<RECT_COUNT;++i) {
            CHECK(rect_equal(&a.new_rects[i],&b.new_rects[i]),5);
            CHECK(a.new_rects[i].x>=0 && a.new_rects[i].y>=0 &&
                  (uint32_t)a.new_rects[i].x+a.new_rects[i].w<=M2_VIEW_W &&
                  (uint32_t)a.new_rects[i].y+a.new_rects[i].h<=M2_VIEW_H,6);
            if(frame>=2u) CHECK(rect_equal(&a.old_rects[i],&prior_cpu[slot][i]) &&
                                  rect_equal(&b.old_rects[i],&prior_fpga[1u-slot][i]) &&
                                  rect_equal(&a.old_rects[i],&b.old_rects[i]),7);
            prior_cpu[slot][i]=a.new_rects[i];
            prior_fpga[1u-slot][i]=b.new_rects[i];
        }
        m2_commit_task(&cpu,&a);m2_commit_task(&fpga,&b);
    }
    m2_scene_reset(&cpu);m2_scene_reset(&fpga);
    for(frame=0;frame<9u;++frame) {
        back=(frame&1u) ? UINT32_C(0x00800000) : 0u;
        m2_make_task(&cpu,&a,1u,back);m2_make_task(&fpga,&b,1u,back);
        CHECK(a.image_index==frame%3u && a.image_index==b.image_index,8);
        CHECK(!a.clear_full && !a.old_count && !a.rect_count &&
              !b.clear_full && !b.old_count && !b.rect_count,9);
        m2_commit_task(&cpu,&a);m2_commit_task(&fpga,&b);
    }
    CHECK(m2_image_base(0u)==UINT32_C(0x01000000) &&
          m2_image_base(1u)==UINT32_C(0x0112c000) &&
          m2_image_base(2u)==UINT32_C(0x01258000),10);
    CHECK(m2_image_pixel(0,123,45)!=m2_image_pixel(1,123,45) &&
          m2_image_pixel(1,123,45)!=m2_image_pixel(2,123,45),11);
    for(image=0;image<3u;++image) {
        for(y=0;y<480u;++y)
            for(x=0;x<640u;++x) source[y*640u+x]=m2_image_pixel(image,x,y);
        for(y=0;y<480u;++y)
            m2_copy_image_row_cpu(target+y*640u,source+y*640u);
        for(y=0;y<480u;++y)
            for(x=0;x<640u;++x)
                CHECK(target[y*640u+x]==m2_image_pixel(image,x,y),24);
    }
    CHECK(!m2_speedup_x100(&cm,&fm),12);
    CHECK(!m2_metric_add(&cm,1000,0,100) && !cm.valid,13);
    CHECK(!m2_metric_add(&cm,1000,200,300) && !cm.valid,14);
    CHECK(!m2_metric_add(&cm,1000,1000,1100) && cm.valid &&
          cm.fps_x100==1000 && cm.last_frames==3 && cm.last_render_ticks==300,15);
    CHECK(!m2_metric_add(&fm,1000,0,50) && !fm.valid,16);
    m2_metric_publish(&fm,1000);
    CHECK(fm.valid && fm.fps_x100==2000 && m2_speedup_x100(&cm,&fm)==200,17);
    CHECK(m2_metric_add(&fm,1000,20,20)==1u && fm.fps_x100==2000,18);
    CHECK(!m2_metric_add(&cm,1000,1200,1300) && cm.fps_x100==1000,19);
    m2_metric_publish(&cm,1000);
    CHECK(cm.fps_x100==1000 && cm.last_frames==1,20);
    CHECK(!m2_stage_done(0u,0u,7000u,1000u,5u),21);
    CHECK(!m2_stage_done(1u,1000u,5999u,1000u,5u),22);
    CHECK(m2_stage_done(2u,1000u,6000u,1000u,5u),23);
    g_m2_check_result=0;
    m2_checks_done();
}
