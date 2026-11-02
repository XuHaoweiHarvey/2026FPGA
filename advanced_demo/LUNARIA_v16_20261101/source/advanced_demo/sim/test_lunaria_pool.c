#include "../software/lunaria/lunaria_pool.h"
#include <assert.h>
#include <stdio.h>
static uint32_t ram[2][LN_POOL_BYTES/4], back=LN_POOL_SLOT1, session, sessions;
static lunaria_t game;
void ln_pool_io_begin(void) { assert(!session); session=1; sessions++; }
void ln_pool_io_end(void) { assert(session); session=0; }
uint32_t ln_pool_io_back(void) { assert(session); return back; }
static uint32_t *word(uint32_t physical) {
  uint32_t slot=physical>=LN_POOL_SLOT1, offset=physical-slot*LN_POOL_SLOT1;
  assert(session && !(physical&3u));
  assert(offset>=LN_POOL_OFFSET && offset<LN_POOL_OFFSET+LN_POOL_BYTES);
  return &ram[slot][(offset-LN_POOL_OFFSET)/4];
}
uint32_t ln_pool_io_read(uint32_t physical) { return *word(physical); }
void ln_pool_io_write(uint32_t physical,uint32_t value) {
  assert((physical>=LN_POOL_SLOT1?LN_POOL_SLOT1:0u)==back); *word(physical)=value;
}
int main(void) {
  uint32_t i,round;
  ln_clear_bullets(&game);
  for (i=0;i<LN_POOL_RESIDENT;++i) {
    ln_bullet(&game,i)->active=1;
    ln_bullet(&game,i)->x=(int32_t)i;
  }
  for (round=0;round<80;++round) {
    back^=LN_POOL_SLOT1;
    for(i=0;i<LN_CAPACITY;++i)
      assert(ln_bullet_read(&game,i)->active==(i<LN_POOL_RESIDENT));
    ln_pool_flush();
  }
  assert(!sessions); /* Even a full-capacity scan cannot evict resident slots. */
  ln_clear_bullets(&game);
  for(i=0;i<LN_CAPACITY;++i) {
    ln_bullet_t *b=ln_bullet(&game,i);
    b->active=1; b->x=(int32_t)i; b->y=-(int32_t)i; b->age=(uint16_t)i;
  }
  ln_pool_flush();
  for(round=0;round<80;++round) {
    back^=LN_POOL_SLOT1;
    for(i=0;i<LN_CAPACITY;++i) {
      const ln_bullet_t *b=ln_bullet_read(&game,i);
      assert(b->active && b->x==(int32_t)i && b->y==-(int32_t)i && b->age==i+round);
      ln_bullet(&game,i)->age++;
    }
    ln_pool_flush();
    /* Reverse traversal across all cache boundaries; no stale slot data. */
    for(i=LN_CAPACITY;i>0;--i) assert(ln_bullet_read(&game,i-1)->age==i+round);
  }
  /* Reset must discard a dirty page without flushing/reviving old bullets. */
  ln_bullet(&game,4095)->active=1;
  ln_clear_bullets(&game);
  for(i=0;i<LN_CAPACITY;++i) assert(!ln_bullet_read(&game,i)->active);
  ln_pool_flush(); assert(!session);
  puts("PASS 512 resident slots without DDR; 4096 live slots, 80 swaps, forward/reverse page eviction, dirty reset; aligned back-only scratch writes");
  return 0;
}
