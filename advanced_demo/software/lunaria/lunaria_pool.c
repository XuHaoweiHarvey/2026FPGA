#include "lunaria_pool.h"
#ifdef LN_EXTERNAL_POOL
typedef char bullet_size_must_be_32[(sizeof(ln_bullet_t) == 32) ? 1 : -1];
typedef char scratch_above_view[(LN_POOL_OFFSET + LN_POOL_BYTES < 300u * 7680u) ? 1 : -1];
static ln_bullet_t resident[LN_POOL_RESIDENT];
static const ln_bullet_t empty_bullet = {0};
static union {
  ln_bullet_t bullets[LN_POOL_PAGE];
  uint32_t words[LN_POOL_PAGE * 8u];
} cache;
static uint8_t location[LN_POOL_PAGES]; /* 0: cleared, 1: slot0, 2: slot1 */
static uint32_t page = UINT32_MAX, dirty;
static void flush_open_session(void) {
  uint32_t i, base, active = 0;
  if (!dirty) return;
  for (i = 0; i < LN_POOL_PAGE; ++i) active |= cache.bullets[i].active;
  if (!active) {
    location[page] = 0;
    dirty = 0;
    return;
  }
  base = ln_pool_io_back();
  for (i = 0; i < LN_POOL_PAGE * 8u; ++i)
    ln_pool_io_write(base + LN_POOL_OFFSET + page * LN_POOL_PAGE * 32u + i * 4u,
                     cache.words[i]);
  location[page] = (uint8_t)(base == LN_POOL_SLOT1 ? 2u : 1u);
  dirty = 0;
}
void ln_pool_flush(void) {
  if (!dirty) return;
  ln_pool_io_begin();
  flush_open_session();
  ln_pool_io_end();
}
static void load(uint32_t next) {
  uint32_t i, io, base;
  if (page == next) return;
  io = dirty || location[next];
  if (io) ln_pool_io_begin();
  flush_open_session();
  base = (location[next] == 2u ? LN_POOL_SLOT1 : 0u) + LN_POOL_OFFSET +
         next * LN_POOL_PAGE * 32u;
  for (i = 0; i < LN_POOL_PAGE * 8u; ++i)
    cache.words[i] = location[next] ? ln_pool_io_read(base + i * 4u) : 0;
  if (io) ln_pool_io_end();
  page = next;
}
ln_bullet_t *ln_bullet(lunaria_t *g, uint32_t index) {
  (void)g;
  if (index < LN_POOL_RESIDENT) return &resident[index];
  load(index / LN_POOL_PAGE);
  dirty = 1;
  return &cache.bullets[index % LN_POOL_PAGE];
}
const ln_bullet_t *ln_bullet_read(const lunaria_t *g, uint32_t index) {
  (void)g;
  if (index < LN_POOL_RESIDENT) return &resident[index];
  /* Never evict an occupied page or enter DDR just to inspect an empty one. */
  if (page != index / LN_POOL_PAGE && !location[index / LN_POOL_PAGE])
    return &empty_bullet;
  load(index / LN_POOL_PAGE);
  return &cache.bullets[index % LN_POOL_PAGE];
}
void ln_clear_bullets(lunaria_t *g) {
  uint32_t i;
  (void)g;
  for (i = 0; i < LN_POOL_RESIDENT; ++i) resident[i].active = 0;
  for (i = 0; i < LN_POOL_PAGES; ++i) location[i] = 0;
  page = UINT32_MAX;
  dirty = 0;
}
#endif
