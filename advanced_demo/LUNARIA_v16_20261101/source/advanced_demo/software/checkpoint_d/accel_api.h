#ifndef ACCEL_API_H
#define ACCEL_API_H
#include "accel_regs.h"

/* Polling-only API. No CPU accesses to DDR; all addresses below are APB offsets.
 * Returns 0 on success, hardware ERROR_CODE or an E1xx software error otherwise.
 * One CPU owns the command stream. Rebuild the entire Back before presenting it. */
#define ACCEL_POLL_LIMIT UINT32_C(20000000)
static inline void accel_write(uint32_t offset,uint32_t value) {
    __asm__ volatile ("fence iorw,iorw" ::: "memory");
    *(volatile uint32_t *)(ACCEL_BASE+offset)=value;
    __asm__ volatile ("fence iorw,iorw" ::: "memory");
}
static inline uint32_t accel_read(uint32_t offset) {
    uint32_t value;
    __asm__ volatile ("fence iorw,iorw" ::: "memory");
    value=*(volatile uint32_t *)(ACCEL_BASE+offset);
    __asm__ volatile ("fence iorw,iorw" ::: "memory");
    return value;
}
static inline uint32_t accel_error(void) {
    return accel_read(ACCEL_ERROR_CODE);
}
static inline uint32_t frame_get_front(void) { return accel_read(ACCEL_FRONT_BASE); }
static inline uint32_t frame_get_back(void) { return accel_read(ACCEL_BACK_BASE); }
static inline uint32_t accel_wait_done(void) {
    uint32_t i,s,e;
    for(i=0;i<ACCEL_POLL_LIMIT;++i) {
        e=accel_error();if(e) return e;
        s=accel_read(ACCEL_STATUS);
        if((s&(ACCEL_BUSY|ACCEL_DONE))==ACCEL_DONE &&
           !(accel_read(ACCEL_BUFFER_STATUS)&FRAME_WRITER_OWNED)) return 0;
    }
    return UINT32_C(0xE101);
}
static inline uint32_t accel_fill_rect(uint32_t x,uint32_t y,uint32_t width,uint32_t height,uint32_t color) {
    uint32_t before,i,e,bs=accel_read(ACCEL_BUFFER_STATUS);
    if(!(bs&FRAME_FRONT_VALID) || (bs&(FRAME_SWAP_PENDING|FRAME_WRITER_OWNED)) ||
       (accel_read(ACCEL_STATUS)&ACCEL_BUSY)) return UINT32_C(0xE102);
    e=accel_error();if(e) return e;
    before=accel_read(ACCEL_COMMAND_COUNT);
    accel_write(ACCEL_RECT_X,x);accel_write(ACCEL_RECT_Y,y);
    accel_write(ACCEL_RECT_WIDTH,width);accel_write(ACCEL_RECT_HEIGHT,height);
    accel_write(ACCEL_RECT_COLOR,color);
    accel_write(ACCEL_CONTROL,1);
    /* A new count acknowledges this START, so an old sticky DONE cannot win. */
    for(i=0;i<ACCEL_POLL_LIMIT;++i) {
        e=accel_error();if(e) return e;
        if(accel_read(ACCEL_COMMAND_COUNT)==before+1u) return 0;
    }
    return UINT32_C(0xE103);
}
static inline uint32_t frame_swap_request(uint32_t *ticket) {
    uint32_t e=accel_error(),bs=accel_read(ACCEL_BUFFER_STATUS);
    if(e) return e;
    if(!(bs&FRAME_FRONT_VALID) || (bs&FRAME_SWAP_PENDING)) return UINT32_C(0xE104);
    *ticket=accel_read(ACCEL_SWAP_COUNT)+1u;
    accel_write(ACCEL_SWAP_CONTROL,FRAME_REQUEST|FRAME_CLEAR_DONE);
    return accel_error();
}
static inline uint32_t frame_wait_swap_done(uint32_t ticket) {
    uint32_t i,e,bs;
    for(i=0;i<ACCEL_POLL_LIMIT;++i) {
        e=accel_error();if(e) return e;
        bs=accel_read(ACCEL_BUFFER_STATUS);
        if((bs&(FRAME_SWAP_PENDING|FRAME_SWAP_DONE))==FRAME_SWAP_DONE &&
           accel_read(ACCEL_SWAP_COUNT)==ticket) return 0;
    }
    return UINT32_C(0xE105);
}
#endif
