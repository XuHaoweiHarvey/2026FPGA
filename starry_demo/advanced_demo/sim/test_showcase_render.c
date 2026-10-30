/* Render the commands emitted by the real firmware, including its two HUD caches. */
#define _CRT_SECURE_NO_WARNINGS
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static uint32_t mock_slot, mock_boundary;
static uint32_t canvas[2][480][640];
static uint32_t draw_sequence, boss_sequence, hit_sequence;
static void raster(uint32_t op, uint32_t src, uint32_t stride, uint32_t x,
                   uint32_t y, uint32_t w, uint32_t h, uint32_t color);
static uint32_t mock_read(uint32_t offset) { return offset==0x7cu ? mock_boundary : 0u; }
static uint32_t mock_mmio(uintptr_t address) { (void)address; return 0; }
#define MOCK_GAME_DRAW raster
#define MOCK_GAME_REG_READ mock_read
#define MOCK_GAME_MMIO_READ mock_mmio
#define MOCK_GAME_BACK_BUFFER (mock_slot ? 0x800000u : 0u)
#define UART_KEY_READ32 mock_mmio
#define SURVIVAL_GAME_HOST_SYNTAX
#define GAME_FLASH_ENABLE 0
#define main board_game_main
#include "../software/interactive_demo/game_main.c"
#undef main

static void raster(uint32_t op, uint32_t src, uint32_t stride, uint32_t x,
                   uint32_t y, uint32_t w, uint32_t h, uint32_t color) {
    uint32_t px, py;
    ++draw_sequence;
    if(op==2u && src==SPRITE_PHYS+320u*SPRITE_STRIDE) boss_sequence=draw_sequence;
    if(op==3u && src>=SPRITE_PHYS+160u*4u && src<SPRITE_PHYS+256u*4u)
        hit_sequence=draw_sequence;
    for(py=y; py<y+h; ++py) for(px=x; px<x+w; ++px) {
        uint32_t pixel=color, offset, *dest, a, channel, blended=0;
        if(px<VIEW_X || px>=VIEW_X+VIEW_W || py<VIEW_Y || py>=VIEW_Y+VIEW_H) continue;
        dest=&canvas[mock_slot][py-VIEW_Y][px-VIEW_X];
        if(op) {
            offset=src+(py-y)*stride+(px-x)*4u;
            if(op==1u) {
                assert(offset>=FULL_BACKGROUND_PHYS);
                offset=(offset-FULL_BACKGROUND_PHYS)/4;
                pixel=display_background_pixel(offset%1920u,offset/1920u);
            } else {
                assert(offset>=SPRITE_PHYS);
                offset=(offset-SPRITE_PHYS)/4;
                pixel=atlas_pixel(offset%640u,offset/640u);
                if(op==2u && (pixel&0xffffffu)==color) continue;
            }
        }
        if(op!=3u) { *dest=pixel&0xffffffu; continue; }
        a=((pixel>>24)*color+127u)/255u;
        for(channel=0; channel<24; channel+=8) {
            uint32_t value=(((pixel>>channel)&255u)*a+((*dest>>channel)&255u)*(255u-a)+127u)/255u;
            blended|=value<<channel;
        }
        *dest=blended;
    }
}
static void preview(const char *name) {
    uint32_t x,y;
    char path[160];
    FILE *f;
    int result=snprintf(path,sizeof(path),"output/showcase_%s.ppm",name);
    assert(result>0 && result<(int)sizeof(path));
    f=fopen(path,"wb"); assert(f);
    fprintf(f,"P6\n640 480\n255\n");
    for(y=0;y<480;++y) for(x=0;x<640;++x) {
        uint32_t p=canvas[mock_slot][y][x];
        unsigned char rgb[3]={(unsigned char)(p>>16),(unsigned char)(p>>8),(unsigned char)p};
        assert(fwrite(rgb,1,3,f)==3);
    }
    fclose(f);
}
static uint32_t center_hash(void) {
    uint32_t x,y,hash=2166136261u;
    for(y=192;y<214;++y) for(x=260;x<372;++x)
        hash=(hash^canvas[mock_slot][y][x])*16777619u;
    return hash;
}
static void frame(uint32_t now) {
    ++mock_boundary;
    render_frame(now);
    assert(!(g_game_presentation.publication&1u));
}
static void hit_atlas(void) {
    uint32_t frame,x,y;
    for(frame=0;frame<6;++frame) for(y=0;y<16;++y) for(x=0;x<16;++x)
        assert(atlas_pixel(160+frame*16+x,y)==
               game_team_sprite_pixel(frame*32+x*2,GAME_TEAM_EXPLOSION_Y+y*2));
}
static void victory_persists(void) {
    uint32_t i, expected=0;
    g_game.game_over=1; g_game.campaign_result=1;
    g_game.showcase_state=GAME_SHOWCASE_VICTORY; g_game.score=4321;
    g_game.boss.active=0;
    memset(g_game.effects,0,sizeof(g_game.effects));
    for(i=0;i<8;++i) {
        uint32_t actual;
        mock_slot=i&1u;
        frame(10000+i*16);
        actual=center_hash();
        if(!i) { expected=actual; preview("victory"); }
        assert(actual==expected);
        {
            const char *text="VICTORY";
            uint32_t letter,x,y,ink=0;
            for(letter=0;letter<7;++letter) for(y=0;y<21;++y) for(x=0;x<16;++x) {
                uint32_t pixel=atlas_pixel(game_font_index(text[letter])*16+x,GAME_FONT_Y+48+y);
                if((pixel&0xffffffu)==COLOR_KEY) continue;
                assert(canvas[mock_slot][192+y][264+letter*16+x]==(pixel&0xffffffu));
                ++ink;
            }
            assert(ink>100);
        }
    }
}
static void boundaries(void) {
    g_debug_status.measurement_state=1;
    g_measure_start=1000; g_measure_window_ms=1000;
    g_measure_boundary_base=100; g_presentation_measure_started=0;
    mock_boundary=102; measure_frame(1016);
    assert(g_game_runtime.measurement_repeated_frames==1);
    assert(g_game_presentation.presentation_intervals==0);
    mock_boundary=103; measure_frame(1032);
    mock_boundary=105; measure_frame(1048);
    assert(g_game_presentation.presentation_intervals==2);
    assert(g_game_presentation.missing_boundaries==1 && g_game_presentation.max_boundary_gap==2);
    g_game_presentation.last_boundary=UINT32_MAX;
    mock_boundary=0; measure_frame(1064);
    assert(g_game_presentation.missing_boundaries==1); /* unsigned counter wrap */
    g_debug_status.measurement_state=0;
}
int main(void) {
    uint32_t i;
    hit_atlas();
    assert(display_background_pixel(VIEW_X,VIEW_Y)==game_background_pixel(0,0));
    assert(display_background_pixel(VIEW_X+639,VIEW_Y+479)==game_background_pixel(1917,1077));
    survival_game_reset(&g_game,0); survival_game_begin_showcase(&g_game,0);
    g_game.campaign_stage=3; g_game.wave=3; g_game.started_ms=0;
    for(i=0;i<5;++i) {
        g_game.enemies[i].active=1; g_game.enemies[i].x=(int16_t)(80+i*100);
        g_game.enemies[i].y=(int16_t)(100+i%2*40);
        g_game.enemy_bullets[i].active=1; g_game.enemy_bullets[i].x=(int16_t)(90+i*100);
        g_game.enemy_bullets[i].y=250;
    }
    frame(15000); preview("wave3");
    memset(g_game.enemies,0,sizeof(g_game.enemies));
    g_game.campaign_stage=4; g_game.boss.active=1; g_game.boss.hp=40;
    g_game.boss.attack_phase=2; g_game.boss.x=280; g_game.boss.y=100;
    g_game.boss_phase_ms=15000; g_game.showcase_state=GAME_SHOWCASE_BOSS;
    g_game.effects[0].active=1; g_game.effects[0].kind=GAME_EFFECT_HIT;
    g_game.effects[0].x=300; g_game.effects[0].y=140; g_game.effects[0].expires_ms=15120;
    frame(15016);
    assert(hit_sequence>boss_sequence && boss_sequence>0);
    assert(canvas[mock_slot][56][12]==0xe85a70u);
    assert(canvas[mock_slot][56][424]==PANEL); /* 40/60 HP */
    preview("boss_hit");
    victory_persists(); boundaries();
    puts("PASS actual draw commands: six downsampled hit frames, hit above Boss, HP bar, both-buffer VICTORY, display-boundary endpoints/wrap");
    return 0;
}
