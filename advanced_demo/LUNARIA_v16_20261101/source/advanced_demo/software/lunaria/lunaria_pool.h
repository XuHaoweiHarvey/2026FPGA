#ifndef LUNARIA_POOL_H
#define LUNARIA_POOL_H
#include "lunaria.h"
/* Scratch is inside each valid framebuffer, above the visible source window.
 * It is never part of a blit, display read, background or sealed atlas.
 * Pages remember their latest slot across swaps; writes always target back. */
#define LN_POOL_OFFSET 0x00010000u
#define LN_POOL_BYTES (LN_CAPACITY * 32u)
/* Small scenes stay entirely on chip; DDR is only overflow storage. */
#define LN_POOL_RESIDENT 512u
#define LN_POOL_PAGE 32u
#define LN_POOL_PAGES (LN_CAPACITY / LN_POOL_PAGE)
#define LN_POOL_SLOT1 0x00800000u
void ln_pool_flush(void);
void ln_pool_io_begin(void);
void ln_pool_io_end(void);
uint32_t ln_pool_io_back(void);
uint32_t ln_pool_io_read(uint32_t physical);
void ln_pool_io_write(uint32_t physical, uint32_t word);
#endif
