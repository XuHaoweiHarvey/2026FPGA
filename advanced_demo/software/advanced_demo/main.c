/* Automatic copy/key/alpha comparison. CPU and FPGA render the same 640x480
 * scene; render FPS excludes the HUD/presentation work, shown separately. */
#include "../apb_reg_test/accel_api.h"
#include "../apb_reg_test/benchmark_clock.h"
#include "../m1b_compare/hud.h"

#if !defined(SYSTEM_DDR_BMB) || SYSTEM_DDR_BMB != 0x1000
#error "Advanced demo requires the uncached M2 DDR alias"
#endif

#define VIEW_X 640u
#define VIEW_Y 300u
#define VIEW_W 640u
#define VIEW_H 480u
#define SPRITE_PHYS UINT32_C(0x01384000)
#define SPRITE_BYTES UINT32_C(0x0012c000)
#define SPRITE_STRIDE 2560u
#define SPRITE_SIZE 640u
#define SPRITE_HEIGHT 480u
#define COPY_X 64u
#define COPY_Y 320u
#define SPRITE_ALIAS (SYSTEM_DDR_BMB+SPRITE_PHYS)
#define ASSET_BASE UINT32_C(0x01000000)
#define ASSET_BYTES UINT32_C(0x0012c000)
#define ASSET_COUNT 3u
#define BACKGROUND UINT32_C(0x00101a2c)
#define KEY_RGB UINT32_C(0x00ff00ff)
#define STAGE_SECONDS 4u
#define FRAME_TIMEOUT_SECONDS 300u

enum {MODE_CPU=0,MODE_FPGA=1};
enum {PHASE_INIT=1,PHASE_ASSETS=2,PHASE_SPRITE=3,PHASE_RENDER=4,
      PHASE_HUD=5,PHASE_SWAP=6,PHASE_RUNNING=7,PHASE_FAILED=255};
enum {ERR_CONFIG=0xe800,ERR_SESSION=0xe801,ERR_ASSET=0xe802,
      ERR_SPRITE=0xe803,ERR_RENDER=0xe804,ERR_CLOCK=0xe805,
      ERR_HEALTH=0xe806,ERR_TIMEOUT=0xe807,ERR_ROLE=0xe808};

typedef struct {
    uint32_t valid,fps_x100,frames;
    uint64_t ticks,window_start;
    uint32_t window_frames;
    uint64_t window_ticks;
} render_metric_t;
typedef struct {
    uint32_t schema,phase,error,mode,frame,cycle,pass;
    uint32_t front,back,asset_status,sprite_status,cpu_ddr_status,cpu_ddr_error;
    uint32_t underflow_base,missed_base,underflow_delta,missed_delta;
    uint32_t command_base,command_delta,swap_base,swap_delta;
    uint32_t sprite_hash,asset_hash[ASSET_COUNT];
    uint32_t global_alpha,second_alpha;
    uint32_t render_fps_x100[2],present_fps_x100[2];
    uint32_t stage_presents[2];
    uint64_t render_ticks,renderer_start,first_present,last_present;
    uint32_t last_error_code;
    render_metric_t render_metric[2];
} advanced_result_t;
volatile advanced_result_t g_advanced_result;

static uint32_t read32(uintptr_t p) {return *(volatile uint32_t *)p;}
static uint64_t ticks(void) {
    uint64_t t;
    __asm__ volatile("fence iorw,iorw" ::: "memory");
    t=benchmark_clock_read(read32);
    __asm__ volatile("fence iorw,iorw" ::: "memory");
    return t;
}
static volatile uint32_t *ddr(uint32_t physical) {
    return (volatile uint32_t *)(uintptr_t)(SYSTEM_DDR_BMB+physical);
}
__attribute__((noinline,noreturn)) void advanced_demo_done(void) {
    for(;;) __asm__ volatile("nop" ::: "memory");
}
static void fail(uint32_t error) {
    g_advanced_result.error=error;g_advanced_result.phase=PHASE_FAILED;
    g_advanced_result.last_error_code=accel_error();
    g_advanced_result.cpu_ddr_error=accel_read(ACCEL_CPU_DDR_ERROR);
    g_advanced_result.cpu_ddr_status=accel_read(ACCEL_CPU_DDR_STATUS);
    g_advanced_result.asset_status=accel_read(ACCEL_ASSET_STATUS);
    g_advanced_result.sprite_status=accel_read(ACCEL_SPRITE_STATUS);
    g_advanced_result.underflow_delta=accel_read(ACCEL_DISPLAY_UNDERFLOW_COUNT)-
                                      g_advanced_result.underflow_base;
    g_advanced_result.missed_delta=accel_read(ACCEL_MISSED_BOUNDARY_COUNT)-
                                   g_advanced_result.missed_base;
    advanced_demo_done();
}
static void require(uint32_t e) {if(e) fail(e);}
static void check_health(void) {
    uint32_t u=accel_read(ACCEL_DISPLAY_UNDERFLOW_COUNT)-g_advanced_result.underflow_base;
    uint32_t m=accel_read(ACCEL_MISSED_BOUNDARY_COUNT)-g_advanced_result.missed_base;
    if(accel_error() || accel_read(ACCEL_READER_ERROR) || u || m ||
       accel_read(ACCEL_CPU_DDR_ERROR) || (accel_read(ACCEL_CPU_DDR_STATUS)&4u))
        fail(ERR_HEALTH);
    g_advanced_result.underflow_delta=u;g_advanced_result.missed_delta=m;
}
static void cpu_session_begin(void) {
    uint32_t i,s=accel_read(ACCEL_CPU_DDR_STATUS);
    if((s&7u) || accel_read(ACCEL_CPU_DDR_ERROR)) fail(ERR_SESSION);
    accel_write(ACCEL_CPU_DDR_CONTROL,1u);
    for(i=0;i<ACCEL_POLL_LIMIT;++i) {
        s=accel_read(ACCEL_CPU_DDR_STATUS);
        if(s&4u) fail(ERR_SESSION);
        if(s&1u) return;
    }
    fail(ERR_SESSION);
}
static void cpu_session_end(void) {
    uint32_t i,s;
    __asm__ volatile("fence iorw,iorw" ::: "memory");
    for(i=0;i<ACCEL_POLL_LIMIT;++i) {
        s=accel_read(ACCEL_CPU_DDR_STATUS);
        if(!(s&2u)) break;
    }
    if(i==ACCEL_POLL_LIMIT || accel_read(ACCEL_CPU_DDR_ERROR) || (s&4u))
        fail(ERR_SESSION);
    accel_write(ACCEL_CPU_DDR_CONTROL,2u);
    for(i=0;i<ACCEL_POLL_LIMIT;++i)
        if(!(accel_read(ACCEL_CPU_DDR_STATUS)&1u)) return;
    fail(ERR_SESSION);
}

static uint32_t asset_pixel(uint32_t image,uint32_t x,uint32_t y) {
    uint32_t r,g,b,band;
    if(image==0u) {
        r=(x+(y>>1))&255u;g=(y+(x>>2))&255u;
        b=(((x+y)>>5)&1u)?0xe0u:0x28u;
    } else if(image==1u) {
        band=((x>>5)^(y>>5))&1u;r=band?0xf0u:0x20u;
        g=((x>>2)^(y>>1))&255u;b=band?0x30u:0xe8u;
    } else {
        band=((x+(y<<1))>>4)&7u;r=band*29u+28u;
        g=((x^y)>>1)&255u;b=255u-(((y*3u+x)>>3)&255u);
    }
    return (r<<16)|(g<<8)|b;
}
static uint32_t asset_hash(uint32_t image,uint32_t verify) {
    uint32_t x,y,pixel,hash=UINT32_C(2166136261);
    volatile uint32_t *dst=ddr(ASSET_BASE+image*ASSET_BYTES);
    for(y=0;y<480u;++y) for(x=0;x<640u;++x) {
        pixel=verify?dst[y*640u+x]:asset_pixel(image,x,y);
        if(verify && pixel!=asset_pixel(image,x,y)) fail(ERR_ASSET);
        if(!verify) dst[y*640u+x]=pixel;
        hash=(hash^pixel)*UINT32_C(16777619);
    }
    return hash;
}
static void initialize_assets(void) {
    uint32_t i,s=accel_read(ACCEL_ASSET_STATUS);
    g_advanced_result.phase=PHASE_ASSETS;
    if(!(s&UINT32_C(0x80000000))) fail(ERR_CONFIG);
    if(!(s&2u)) {
        if(!(s&1u)) {
            accel_write(ACCEL_ASSET_CONTROL,1u);
            if(!(accel_read(ACCEL_ASSET_STATUS)&1u)) fail(ERR_ASSET);
        }
        cpu_session_begin();
        for(i=0;i<ASSET_COUNT;++i)
            g_advanced_result.asset_hash[i]=asset_hash(i,0);
        cpu_session_end();
        cpu_session_begin();
        for(i=0;i<ASSET_COUNT;++i)
            if(asset_hash(i,1)!=g_advanced_result.asset_hash[i]) fail(ERR_ASSET);
        cpu_session_end();
        accel_write(ACCEL_ASSET_CONTROL,2u);
        if(!(accel_read(ACCEL_ASSET_STATUS)&2u)) fail(ERR_ASSET);
    } else {
        cpu_session_begin();
        for(i=0;i<ASSET_COUNT;++i)
            if(asset_hash(i,1)==0u) fail(ERR_ASSET);
        cpu_session_end();
    }
    g_advanced_result.asset_status=accel_read(ACCEL_ASSET_STATUS);
}

/* ARGB atlas: radial orange/cyan light, magenta-key silhouette, and a spare
 * deterministic tile area. Every byte is initialized before sealing. */
static uint32_t sprite_pixel(uint32_t x,uint32_t y) {
    int32_t dx,dy;
    uint32_t radius2,alpha,r,g,b;
    if(x<128u && y<128u) {
        dx=(int32_t)x-63;dy=(int32_t)y-63;
        radius2=(uint32_t)(dx*dx+dy*dy);
        if(radius2>=4096u) alpha=0;
        else alpha=32u+(4095u-radius2)*220u/4095u;
        r=255u;g=72u+((x*3u+y)&63u);b=30u+((y*5u)&31u);
        return (alpha<<24)|(r<<16)|(g<<8)|b;
    }
    if(x>=160u && x<288u && y<128u) {
        uint32_t sx=x-160u,sy=y;
        dx=(int32_t)sx-63;dy=(int32_t)sy-63;
        if((uint32_t)(dx*dx+dy*dy)<49u*49u &&
           (((sx/12u)+(sy/12u))&1u)==0)
            return UINT32_C(0x00e8e8f0);
        if(sx>=48u && sx<80u && sy>=20u && sy<108u)
            return UINT32_C(0x0000d8f0);
        return KEY_RGB;
    }
    r=(x*7u+y*3u)&255u;g=(x*2u+y*9u)&255u;b=(x+y*5u)&255u;
    return (UINT32_C(0xff)<<24)|(r<<16)|(g<<8)|b;
}
static void initialize_sprite(void) {
    uint32_t x,y,pixel,hash=UINT32_C(2166136261);
    volatile uint32_t *dst=ddr(SPRITE_PHYS);
    uint32_t s=accel_read(ACCEL_SPRITE_STATUS);
    g_advanced_result.phase=PHASE_SPRITE;
    if(!(s&UINT32_C(0x80000000))) fail(ERR_CONFIG);
    if(!(s&2u)) {
        require(accel_sprite_begin());cpu_session_begin();
        for(y=0;y<SPRITE_HEIGHT;++y) for(x=0;x<SPRITE_SIZE;++x) {
            pixel=sprite_pixel(x,y);dst[y*SPRITE_SIZE+x]=pixel;
            hash=(hash^pixel)*UINT32_C(16777619);
        }
        __asm__ volatile("fence iorw,iorw" ::: "memory");
        for(y=0;y<SPRITE_HEIGHT;++y) for(x=0;x<SPRITE_SIZE;++x) {
            pixel=dst[y*SPRITE_SIZE+x];
            if(pixel!=sprite_pixel(x,y)) fail(ERR_SPRITE);
        }
        cpu_session_end();require(accel_sprite_seal());
    } else {
        cpu_session_begin();
        for(y=0;y<SPRITE_HEIGHT;++y) for(x=0;x<SPRITE_SIZE;++x) {
            pixel=dst[y*SPRITE_SIZE+x];
            if(pixel!=sprite_pixel(x,y)) fail(ERR_SPRITE);
            hash=(hash^pixel)*UINT32_C(16777619);
        }
        cpu_session_end();
    }
    g_advanced_result.sprite_hash=hash;
    g_advanced_result.sprite_status=accel_read(ACCEL_SPRITE_STATUS);
}

static uint32_t wave_alpha(uint32_t frame) {
    uint32_t phase=frame%120u;
    if(phase>60u) phase=120u-phase;
    return 48u+phase*207u/60u;
}
static void alpha_pair(uint32_t frame,uint32_t *a1,uint32_t *a2) {
    *a1=wave_alpha(frame);*a2=32u+(*a1*3u)/4u;
}
static void cpu_render(uint32_t back,uint32_t front,uint32_t frame,
                       uint32_t alpha1,uint32_t alpha2) {
    uint32_t x,y,src,dst,alpha,x0,y0;
    volatile uint32_t *db=ddr(back);
    const volatile uint32_t *fb=ddr(front);
    const volatile uint32_t *sp=ddr(SPRITE_PHYS);
    uint64_t start=ticks();
    uint32_t sx=COPY_X,sy=COPY_Y;
    (void)frame;
    g_advanced_result.phase=PHASE_RENDER;cpu_session_begin();
    for(y=0;y<VIEW_H;++y) for(x=0;x<VIEW_W;++x)
        db[(VIEW_Y+y)*1920u+VIEW_X+x]=BACKGROUND;
    for(y=0;y<128u;++y) for(x=0;x<128u;++x)
        db[(VIEW_Y+48u+y)*1920u+VIEW_X+32u+x]=
            fb[(sy+y)*1920u+sx+x];
    for(y=0;y<128u;++y) for(x=0;x<128u;++x) {
        src=sp[y*SPRITE_SIZE+160u+x];
        if((src&UINT32_C(0x00ffffff))!=KEY_RGB)
            db[(VIEW_Y+48u+y)*1920u+VIEW_X+212u+x]=src;
    }
    alpha=alpha1;x0=VIEW_X+348u;y0=VIEW_Y+160u;
    for(y=0;y<128u;++y) for(x=0;x<128u;++x) {
        src=sp[y*SPRITE_SIZE+x];dst=db[(y0+y)*1920u+x0+x];
        db[(y0+y)*1920u+x0+x]=accel_alpha_pixel_reference(src,dst,alpha);
    }
    alpha=alpha2;x0=VIEW_X+432u;y0=VIEW_Y+232u;
    for(y=0;y<128u;++y) for(x=0;x<128u;++x) {
        src=sp[y*SPRITE_SIZE+x];dst=db[(y0+y)*1920u+x0+x];
        db[(y0+y)*1920u+x0+x]=accel_alpha_pixel_reference(src,dst,alpha);
    }
    cpu_session_end();
    g_advanced_result.render_ticks=ticks()-start;
}
static void fpga_command(uint32_t error) {
    require(error);require(accel_wait_done());check_health();
}
static void fpga_render(uint32_t front,uint32_t alpha1,uint32_t alpha2) {
    uint32_t src=front+COPY_Y*7680u+COPY_X*4u;
    uint64_t start=ticks();
    g_advanced_result.phase=PHASE_RENDER;
    fpga_command(accel_fill_rect(VIEW_X,VIEW_Y,VIEW_W,VIEW_H,BACKGROUND));
    fpga_command(accel_blit(src,7680u,VIEW_X+32u,VIEW_Y+48u,128u,128u));
    fpga_command(accel_color_key_blit(SPRITE_PHYS+160u*4u,SPRITE_STRIDE,
        VIEW_X+212u,VIEW_Y+48u,128u,128u,KEY_RGB));
    fpga_command(accel_alpha_blend(SPRITE_PHYS,SPRITE_STRIDE,
        VIEW_X+348u,VIEW_Y+160u,128u,128u,alpha1));
    fpga_command(accel_alpha_blend(SPRITE_PHYS,SPRITE_STRIDE,
        VIEW_X+432u,VIEW_Y+232u,128u,128u,alpha2));
    g_advanced_result.render_ticks=ticks()-start;
}
static void hud_value(char *line,const char *prefix,uint32_t fps) {
    char *p=line;p=m1b_append(p,prefix);
    if(fps) p=m1b_fixed2(p,fps);else p=m1b_append(p,"WAIT");*p=0;
}
static void render_hud(uint32_t back,uint32_t mode) {
    char line[48];volatile uint32_t *dst=ddr(back);
    uint32_t cpu=g_advanced_result.render_fps_x100[MODE_CPU];
    uint32_t fpga=g_advanced_result.render_fps_x100[MODE_FPGA];
    g_advanced_result.phase=PHASE_HUD;
    require(accel_fill_rect(16u,16u,600u,240u,BACKGROUND));require(accel_wait_done());
    cpu_session_begin();
    m1b_hud_text(dst,28u,26u,"COPY / COLOR KEY / ALPHA",
                 UINT32_C(0x00ffffff));
    hud_value(line,"CPU RENDER FPS ",cpu);
    m1b_hud_text(dst,28u,60u,line,UINT32_C(0x004bd9ef));
    hud_value(line,"FPGA RENDER FPS ",fpga);
    m1b_hud_text(dst,28u,94u,line,UINT32_C(0x00e8e8f0));
    hud_value(line,"PRESENT FPS CPU ",g_advanced_result.present_fps_x100[MODE_CPU]);
    m1b_hud_text(dst,28u,128u,line,UINT32_C(0x00ffd878));
    hud_value(line,"PRESENT FPS FPGA ",g_advanced_result.present_fps_x100[MODE_FPGA]);
    m1b_hud_text(dst,28u,162u,line,UINT32_C(0x00ffd878));
    m1b_hud_text(dst,28u,196u,mode==MODE_CPU ?
        "CPU REFERENCE RENDER" : "FPGA BLIT AND ALPHA",UINT32_C(0x00afc0d0));
    cpu_session_end();
}
static void metric_add(uint32_t mode,uint64_t start,uint64_t finish) {
    volatile render_metric_t *m=&g_advanced_result.render_metric[mode];
    uint64_t duration;
    if(finish<=start) fail(ERR_CLOCK);
    duration=finish-start;
    if(!m->window_frames) m->window_start=start;
    m->window_ticks+=duration;++m->window_frames;++m->frames;m->ticks+=duration;
    if(finish-m->window_start>=SYSTEM_CLINT_HZ) {
        m->fps_x100=(uint32_t)((uint64_t)m->window_frames*SYSTEM_CLINT_HZ*100u/
                               m->window_ticks);
        m->valid=1;m->window_start=finish;m->window_frames=0;m->window_ticks=0;
        g_advanced_result.render_fps_x100[mode]=m->fps_x100;
    }
}
static void present(uint32_t mode,uint32_t *frame,uint64_t stage_start) {
    uint32_t ticket,back=display_get_back_buffer();
    uint32_t front=display_get_front_buffer();
    uint32_t a1,a2;
    uint64_t render_start,render_done,now;
    if(back==front || (back!=0u && back!=UINT32_C(0x00800000)) ||
       (front!=0u && front!=UINT32_C(0x00800000))) fail(ERR_ROLE);
    alpha_pair(*frame,&a1,&a2);g_advanced_result.global_alpha=a1;
    g_advanced_result.second_alpha=a2;
    render_start=ticks();
    if(mode==MODE_CPU) cpu_render(back,front,*frame,a1,a2);
    else fpga_render(front,a1,a2);
    render_done=ticks();metric_add(mode,render_start,render_done);
    render_hud(back,mode);
    g_advanced_result.phase=PHASE_SWAP;
    require(display_swap_request(&ticket));require(display_wait_swap_done(ticket));
    now=ticks();if(!g_advanced_result.stage_presents[mode])
        g_advanced_result.first_present=now;
    g_advanced_result.last_present=now;
    ++g_advanced_result.stage_presents[mode];++g_advanced_result.frame;
    ++*frame;
    g_advanced_result.present_fps_x100[mode]=(uint32_t)(
        (uint64_t)g_advanced_result.stage_presents[mode]*SYSTEM_CLINT_HZ*100u/
        (now-stage_start));
    g_advanced_result.front=display_get_front_buffer();
    g_advanced_result.back=display_get_back_buffer();
    g_advanced_result.command_delta=accel_read(ACCEL_COMMAND_COUNT)-g_advanced_result.command_base;
    g_advanced_result.swap_delta=accel_read(ACCEL_SWAP_COUNT)-g_advanced_result.swap_base;
    check_health();g_advanced_result.phase=PHASE_RUNNING;
}
static void seed_front_texture(void) {
    uint32_t x,y,ticket,i,back;
    for(i=0;i<2u;++i) {
    volatile uint32_t *dst;
    back=display_get_back_buffer();dst=ddr(back);
    require(accel_fill_rect(0,0,1920u,1080u,BACKGROUND));require(accel_wait_done());
    cpu_session_begin();
    for(y=0;y<128u;++y) for(x=0;x<128u;++x) {
        uint32_t r=(x*2u+y)&255u,g=(y*3u+(x>>1))&255u;
        uint32_t b=(((x>>4)^(y>>4))&1u)?0xe8u:0x28u;
        dst[(COPY_Y+y)*1920u+COPY_X+x]=(r<<16)|(g<<8)|b;
    }
    cpu_session_end();require(display_swap_request(&ticket));
    require(display_wait_swap_done(ticket));
    }
}
int main(void) {
    uint32_t frame=0,mode;
    uint64_t stage_start;
    __asm__ volatile("csrci mstatus,8" ::: "memory");
    g_advanced_result.schema=1;g_advanced_result.phase=PHASE_INIT;
    require(accel_init());
    if(!(accel_read(ACCEL_CPU_DDR_STATUS)&16u) ||
       !(accel_read(ACCEL_CAPABILITIES)&ACCEL_CAP_ALPHA)) fail(ERR_CONFIG);
    require(display_wait_frames(3u));
    g_advanced_result.underflow_base=accel_read(ACCEL_DISPLAY_UNDERFLOW_COUNT);
    g_advanced_result.missed_base=accel_read(ACCEL_MISSED_BOUNDARY_COUNT);
    g_advanced_result.command_base=accel_read(ACCEL_COMMAND_COUNT);
    g_advanced_result.swap_base=accel_read(ACCEL_SWAP_COUNT);
    initialize_assets();initialize_sprite();check_health();seed_front_texture();
    for(;;) for(mode=MODE_CPU;mode<=MODE_FPGA;++mode) {
        stage_start=ticks();g_advanced_result.mode=mode;
        g_advanced_result.stage_presents[mode]=0;frame=0;
        do {
            present(mode,&frame,stage_start);
        } while(ticks()-stage_start<(uint64_t)STAGE_SECONDS*SYSTEM_CLINT_HZ);
        g_advanced_result.cycle++;
        /* Ensure no stale presentation request remains after the timed stage. */
        if(accel_read(ACCEL_BUFFER_STATUS)&(FRAME_SWAP_PENDING|FRAME_WRITER_OWNED))
            fail(ERR_ROLE);
    }
    return 0;
}
