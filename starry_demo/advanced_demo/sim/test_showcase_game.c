#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "../software/interactive_demo/game_logic.h"
#include "../software/interactive_demo/uart_keyboard_protocol.h"

static void advance(survival_game_t *g, uint32_t duration, uint8_t buttons) {
    while (duration) {
        uint32_t dt = duration > 16u ? 16u : duration;
        survival_game_step(g, buttons, g->last_ms + dt);
        duration -= dt;
    }
}
static uint32_t shots(const survival_game_t *g) {
    uint32_t i, n = 0;
    for (i=0; i<GAME_ENEMY_BULLET_CAPACITY; ++i) n += g->enemy_bullets[i].active != 0;
    return n;
}
static uint32_t effects(const survival_game_t *g, uint8_t kind, uint32_t now) {
    uint32_t i, n = 0;
    for (i=0; i<GAME_EFFECT_LIMIT; ++i)
        n += g->effects[i].active && g->effects[i].kind == kind &&
             (int32_t)(g->effects[i].expires_ms-now)>0;
    return n;
}
static void begin(survival_game_t *g, uint32_t now) {
    memset(g, 0, sizeof(*g));
    survival_game_reset(g, now);
    survival_game_begin_showcase(g, now);
}
static void boss(survival_game_t *g, uint32_t now) {
    begin(g, now);
    g->invincible_mode = 1;
    advance(g, 22032, 0);
    assert(g->showcase_state == GAME_SHOWCASE_BOSS);
    assert(g->boss.hp == 60 && g->boss.active);
    g->boss_phase_ms = g->simulation_ms - 3100u; /* stationary for collision fixtures */
    g->boss_next_fire_ms = g->simulation_ms + 10000u;
}
static void hit(survival_game_t *g, uint32_t count) {
    uint32_t i;
    for (i=0; i<count; ++i) {
        g->bullets[i].x = g->boss.x + 20;
        g->bullets[i].y = g->boss.y + GAME_BOSS_SIZE - 4;
        g->bullets[i].active = 1;
    }
    advance(g, 16, 0);
}
static void waves_and_wrap(uint32_t base) {
    survival_game_t g;
    uint32_t i;
    begin(&g, base); g.invincible_mode=1; g.score=123;
    advance(&g, 6992, 0); assert(g.campaign_stage==1);
    for (i=0; i<GAME_ENEMY_LIMIT; ++i) if (g.enemies[i].active) assert(g.enemies[i].vx==0);
    g.lives=2;
    advance(&g, 16, 0); assert(g.campaign_stage==2 && g.score==123 && g.lives==2);
    advance(&g, 6992, 0); assert(g.campaign_stage==3 && g.score==123);
    advance(&g, 7008, 0); assert(g.showcase_state==GAME_SHOWCASE_INTRO && !shots(&g));
    assert(g.boss.hp==60);
    hit(&g, 2); assert(g.boss.hp==60 && g.score==123); /* intro cannot award fake hits */
    advance(&g, 1008, 0); assert(g.showcase_state==GAME_SHOWCASE_BOSS);
}
static void phases_movement_hits_and_pause(void) {
    survival_game_t g;
    uint32_t i, deadline, phase_ms, state_ms, expires;
    int16_t x;
    boss(&g, 100);
    memset(g.enemy_bullets,0,sizeof(g.enemy_bullets));
    g.boss_next_fire_ms=g.simulation_ms;
    advance(&g,16,0); assert(shots(&g)==4);
    assert(g.boss_next_fire_ms-g.simulation_ms==112);
    memset(g.enemy_bullets,0,sizeof(g.enemy_bullets));
    g.boss_phase_ms=g.simulation_ms; g.boss_next_fire_ms=g.simulation_ms;
    advance(&g,16,0); assert(shots(&g)==4);
    assert(g.boss_next_fire_ms-g.simulation_ms==224);
    memset(g.enemy_bullets,0,sizeof(g.enemy_bullets));
    g.boss_phase_ms=g.simulation_ms-3100u; g.boss_next_fire_ms=g.simulation_ms+10000;
    x=g.boss.x; advance(&g, 160, 0); assert(g.boss.x==x);
    g.boss_phase_ms=g.simulation_ms; advance(&g, 16, 0); assert(g.boss.x!=x);
    for (i=0; i<400; ++i) {
        advance(&g, 16, 0);
        assert(g.boss.x>=32 && g.boss.x<=GAME_WORLD_WIDTH-GAME_BOSS_SIZE-32);
    }
    g.boss_phase_ms=g.simulation_ms-3100u;
    g.boss_next_fire_ms=g.simulation_ms+10000;
    g.boss.hp=41;
    g.invincible_mode=0; g.invulnerable=0;
    g.enemy_bullets[0].active=1;
    g.enemy_bullets[0].x=g.player_x+13; g.enemy_bullets[0].y=g.player_y+13;
    g.enemy_bullets[0].vx=g.enemy_bullets[0].vy=0;
    hit(&g, 1);
    assert(g.boss.hp==40 && g.boss.attack_phase==2 && g.lives==3 && shots(&g)==0);
    assert(effects(&g, GAME_EFFECT_HIT, g.simulation_ms)==1);
    assert(g.effects[0].x==g.boss.x+20 && g.effects[0].y==g.boss.y+(int32_t)GAME_BOSS_SIZE-13);
    deadline=g.boss_warning_until_ms; phase_ms=g.boss_phase_ms;
    state_ms=g.showcase_state_ms; expires=g.effects[0].expires_ms;
    survival_game_step(&g, UART_KEY_PAUSE, g.last_ms);
    advance(&g, 5000, 0);
    assert(g.paused && shots(&g)==0 && g.effects[0].expires_ms==expires+5000);
    assert(g.boss_warning_until_ms==deadline+5000 && g.boss_phase_ms==phase_ms+5000);
    assert(g.showcase_state_ms==state_ms+5000);
    survival_game_step(&g, UART_KEY_PAUSE, g.last_ms);
    advance(&g, 112, 0); assert(effects(&g,GAME_EFFECT_HIT,g.simulation_ms)==1);
    advance(&g, 16, 0); assert(!effects(&g,GAME_EFFECT_HIT,g.simulation_ms));
    advance(&g, 352, 0); assert(!shots(&g));
    advance(&g, 32, 0); assert(shots(&g)==14);
    assert(g.enemy_bullets[0].x<g.enemy_bullets[7].x);
    assert(g.enemy_bullets[0].vx>0 && g.enemy_bullets[13].vx<0);
    memset(g.enemy_bullets,0,sizeof(g.enemy_bullets));
    g.boss.hp=21; hit(&g,1);
    assert(g.boss.hp==20 && g.boss.attack_phase==3 && !shots(&g));
    advance(&g, 512, 0); assert(shots(&g)==24);
    g.boss.hp=10; hit(&g,3); assert(g.boss.hp==7);
}
static void defeat_and_restart(void) {
    survival_game_t g;
    uint32_t i, death, victory;
    boss(&g, UINT32_MAX-30000u);
    g.boss.hp=1;
    for (i=0;i<GAME_EFFECT_LIMIT;++i) {
        g.effects[i].active=1; g.effects[i].kind=GAME_EFFECT_HIT;
        g.effects[i].expires_ms=g.last_ms+2000;
    }
    g.lives=1; g.invincible_mode=0; g.invulnerable=0;
    g.enemy_bullets[0].active=1; g.enemy_bullets[0].x=g.player_x+13;
    g.enemy_bullets[0].y=g.player_y+13; g.enemy_bullets[0].vx=g.enemy_bullets[0].vy=0;
    hit(&g, GAME_BULLET_LIMIT);
    death=g.showcase_state_ms;
    assert(g.boss.hp==0 && !g.boss.active && !g.game_over && g.lives==1);
    assert(g.showcase_state==GAME_SHOWCASE_DEFEAT && g.score==1005 && !shots(&g));
    assert(effects(&g,GAME_EFFECT_DEFEAT,g.simulation_ms)==1);
    for (i=0;i<49;++i) {
        advance(&g,16,UART_KEY_FIRE);
        assert(!g.game_over && !g.boss.active && !shots(&g));
        assert(effects(&g,GAME_EFFECT_DEFEAT,g.simulation_ms)>0);
        assert(survival_game_sprite_count(&g,g.simulation_ms)<=2+GAME_EFFECT_LIMIT);
    }
    advance(&g,16,UART_KEY_FIRE);
    assert(g.game_over && g.campaign_result==1 && g.showcase_state==GAME_SHOWCASE_VICTORY);
    assert(g.showcase_state_ms-death>=800 && g.showcase_state_ms-death<832);
    victory=g.showcase_state_ms;
    advance(&g,4000,UART_KEY_FIRE); assert(g.game_over && !g.victory_armed);
    advance(&g,16,0); assert(g.victory_armed);
    advance(&g,16,UART_KEY_FIRE);
    assert(!g.game_over && g.showcase_state==GAME_SHOWCASE_WAVES && g.lives==3 && !g.score);
    assert(g.started_ms-victory>=3000);
    boss(&g,0); g.boss.hp=1; hit(&g,1);
    advance(&g,160,0);
    survival_game_step(&g,UART_KEY_PAUSE,g.last_ms);
    death=g.showcase_state_ms; i=g.defeat_bursts;
    advance(&g,3000,0);
    assert(g.paused && g.showcase_state==GAME_SHOWCASE_DEFEAT && g.defeat_bursts==i);
    assert(g.showcase_state_ms==death+3000);
    survival_game_step(&g,UART_KEY_PAUSE,g.last_ms);
    advance(&g,640,0); assert(g.showcase_state==GAME_SHOWCASE_VICTORY);
    advance(&g,2800,0); advance(&g,16,UART_KEY_FIRE); assert(g.game_over);
    advance(&g,400,UART_KEY_FIRE); assert(g.game_over); /* early press remains held */
    advance(&g,16,0); advance(&g,16,UART_KEY_FIRE); assert(!g.game_over);
    begin(&g,0); g.lives=0; advance(&g,16,0);
    assert(g.showcase_state==GAME_SHOWCASE_FAILURE && g.game_over);
    advance(&g,400,0); advance(&g,16,UART_KEY_FIRE); assert(g.game_over);
    advance(&g,112,0); advance(&g,16,UART_KEY_FIRE); assert(!g.game_over);
}
static void playthroughs_and_endurance(void) {
    survival_game_t g;
    uint32_t round, now=0, frame;
    for(round=0;round<3;++round) {
        uint32_t start=now;
        begin(&g,now); g.invincible_mode=1;
        for(frame=0;frame<6000 && !g.game_over;++frame) {
            uint8_t keys=UART_KEY_FIRE;
            if(g.boss.active) {
                int32_t target=g.boss.x+(GAME_BOSS_SIZE-GAME_PLAYER_SIZE)/2;
                if(g.player_x+3<target) keys|=UART_KEY_RIGHT;
                if(g.player_x-3>target) keys|=UART_KEY_LEFT;
            }
            now+=16; survival_game_step(&g,keys,now);
        }
        assert(g.campaign_result==1 && g.boss.hp==0);
        printf("Actual collision tracking playthrough %u: %u ms (debug invincibility)\n",round+1,now-start);
        assert(now-start>=40000 && now-start<=60000);
        advance(&g,3200,UART_KEY_FIRE); assert(g.game_over); now=g.last_ms;
    }
    begin(&g,now); g.invincible_mode=1;
    for(frame=0;frame<37500;++frame) {
        now+=16; survival_game_step(&g,0,now);
        assert(!g.game_over && g.lives==3);
        assert(g.boss.hp==60 || !g.boss.active);
        assert(shots(&g)<=256);
    }
    puts("PASS 10-minute host logic endurance; victory requires actual damage");
}
int main(void) {
    waves_and_wrap(0); waves_and_wrap(UINT32_MAX-10000u);
    phases_movement_hits_and_pause(); defeat_and_restart();
    playthroughs_and_endurance();
    puts("PASS showcase waves, phase clearing, movement, hit expiry, pause, full effects, fatal multi-hit, defeat, victory and restart");
    return 0;
}
