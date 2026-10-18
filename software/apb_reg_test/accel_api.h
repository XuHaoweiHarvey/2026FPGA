#ifndef ACCEL_API_H
#define ACCEL_API_H
#include "accel_regs.h"

/* Polling-only API. CPU accesses only APB; src_addr is a DDR address for DMA.
 * Returns 0 on success, hardware ERROR_CODE or an E0xx/E1xx software error otherwise.
 * One CPU owns the command stream. Rebuild the entire Back before presenting it. */
#ifndef ACCEL_POLL_LIMIT
#define ACCEL_POLL_LIMIT UINT32_C(20000000)
#endif
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
typedef struct {
    uint32_t status,error_code,buffer_status,front_base,back_base;
    uint32_t command_count,swap_count,boundary_count,reader_error;
    uint32_t reader_base,reader_outstanding,reader_data_beats,reader_reserved_beats;
    uint32_t missed_boundaries,display_underflow_count,service_status;
    uint32_t writer_throttle_cycles,writer_bursts,reader_frame_completions;
    uint32_t reader_ar_stall_cycles,reader_ar_max_stall;
    uint32_t reader_r_stall_cycles,reader_r_max_stall;
    uint32_t reader_fifo_level,writer_max_cycles,service_read_quota,service_watermarks;
} accel_diagnostics_t;

/* Independent RO reads, not an atomic hardware snapshot. No counter clear. */
static inline void diagnostics_read(volatile accel_diagnostics_t *d) {
#define SNAP(field,reg) d->field=accel_read(reg)
    SNAP(status,ACCEL_STATUS);SNAP(error_code,ACCEL_ERROR_CODE);
    SNAP(buffer_status,ACCEL_BUFFER_STATUS);SNAP(front_base,ACCEL_FRONT_BASE);
    SNAP(back_base,ACCEL_BACK_BASE);SNAP(command_count,ACCEL_COMMAND_COUNT);
    SNAP(swap_count,ACCEL_SWAP_COUNT);SNAP(boundary_count,ACCEL_BOUNDARY_COUNT);
    SNAP(reader_error,ACCEL_READER_ERROR);SNAP(reader_base,ACCEL_READER_BASE);
    SNAP(reader_outstanding,ACCEL_READER_OUTSTANDING);
    SNAP(reader_data_beats,ACCEL_READER_DATA_BEATS);
    SNAP(reader_reserved_beats,ACCEL_READER_RESERVED_BEATS);
    SNAP(missed_boundaries,ACCEL_MISSED_BOUNDARY_COUNT);
    SNAP(display_underflow_count,ACCEL_DISPLAY_UNDERFLOW_COUNT);
    SNAP(service_status,ACCEL_SERVICE_STATUS);
    SNAP(writer_throttle_cycles,ACCEL_WRITER_THROTTLE_CYCLES);
    SNAP(writer_bursts,ACCEL_WRITER_BURSTS);
    SNAP(reader_frame_completions,ACCEL_READER_FRAME_COMPLETIONS);
    SNAP(reader_ar_stall_cycles,ACCEL_READER_AR_STALL_CYCLES);
    SNAP(reader_ar_max_stall,ACCEL_READER_AR_MAX_STALL);
    SNAP(reader_r_stall_cycles,ACCEL_READER_R_STALL_CYCLES);
    SNAP(reader_r_max_stall,ACCEL_READER_R_MAX_STALL);
    SNAP(reader_fifo_level,ACCEL_READER_FIFO_LEVEL);
    SNAP(writer_max_cycles,ACCEL_WRITER_MAX_CYCLES);
    SNAP(service_read_quota,ACCEL_SERVICE_READ_QUOTA);
    SNAP(service_watermarks,ACCEL_SERVICE_WATERMARKS);
#undef SNAP
}

/* Re-running CPU Debug must first drain an earlier command/pending swap.
 * No reset, START, error clear, or swap is issued by initialization. */
static inline uint32_t accel_init(void) {
    uint32_t i,s,bs,e;
    if(accel_read(ACCEL_ID)!=ACCEL_ID_EXPECTED ||
       accel_read(ACCEL_VERSION)!=ACCEL_VERSION_EXPECTED) return UINT32_C(0xE000);
    for(i=0;i<ACCEL_POLL_LIMIT;++i) {
        e=accel_read(ACCEL_ERROR_CODE);if(e) return e;
        s=accel_read(ACCEL_STATUS);bs=accel_read(ACCEL_BUFFER_STATUS);
        if((s&ACCEL_INIT_DONE) && !(s&ACCEL_BUSY) && (bs&FRAME_FRONT_VALID) &&
           !(bs&(FRAME_SWAP_PENDING|FRAME_WRITER_OWNED))) break;
    }
    if(i==ACCEL_POLL_LIMIT) return UINT32_C(0xE001);
    if(accel_read(ACCEL_WIDTH)!=1920 || accel_read(ACCEL_HEIGHT)!=1080 ||
       accel_read(ACCEL_STRIDE)!=7680 || accel_read(ACCEL_CAPABILITIES)!=0x7Bu ||
       accel_read(ACCEL_SERVICE_READ_QUOTA)!=128 ||
       accel_read(ACCEL_SERVICE_WATERMARKS)!=UINT32_C(0x02000180) ||
       !(accel_read(ACCEL_SERVICE_STATUS)&(1u<<5))) return UINT32_C(0xE003);
    return 0;
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
           !(accel_read(ACCEL_BUFFER_STATUS)&FRAME_WRITER_OWNED)) {
            /* Completion may arrive after the earlier ERROR_CODE read.
             * Recheck after DONE/ownership so a failed final response cannot
             * be reported as successful completion. */
            return accel_error();
        }
    }
    return UINT32_C(0xE101);
}
static inline uint32_t accel_submit(uint32_t op,uint32_t src_addr,uint32_t src_stride,
                                  uint32_t x,uint32_t y,uint32_t width,uint32_t height,uint32_t color) {
    uint32_t before,i,e,bs=accel_read(ACCEL_BUFFER_STATUS);
    if(!(bs&FRAME_FRONT_VALID) || (bs&(FRAME_SWAP_PENDING|FRAME_WRITER_OWNED)) ||
       (accel_read(ACCEL_STATUS)&ACCEL_BUSY)) return UINT32_C(0xE102);
    e=accel_error();if(e) return e;
    before=accel_read(ACCEL_COMMAND_COUNT);
    accel_write(ACCEL_COMMAND_OP,op);
    accel_write(ACCEL_SRC_ADDR,src_addr);accel_write(ACCEL_SRC_STRIDE,src_stride);
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
static inline uint32_t accel_fill_rect(uint32_t x,uint32_t y,uint32_t width,uint32_t height,uint32_t color) {
    return accel_submit(ACCEL_OP_FILL,0,0,x,y,width,height,color);
}
/* Source is an absolute address in current Front; stride=7680. Destination x
 * and width are multiples of four. A successful submit only acknowledges START;
 * call accel_wait_done(), then explicitly request/wait for a swap. */
static inline uint32_t accel_blit(uint32_t src_addr,uint32_t src_stride,uint32_t x,uint32_t y,
                                uint32_t width,uint32_t height) {
    return accel_submit(ACCEL_OP_BLIT,src_addr,src_stride,x,y,width,height,0);
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
/* E naming aliases retain the validated D API and ticket semantics. */
static inline uint32_t display_swap_request(uint32_t *ticket) { return frame_swap_request(ticket); }
static inline uint32_t display_wait_swap_done(uint32_t ticket) { return frame_wait_swap_done(ticket); }
static inline uint32_t display_get_front_buffer(void) { return frame_get_front(); }
static inline uint32_t display_get_back_buffer(void) { return frame_get_back(); }
static inline uint32_t display_wait_frames(uint32_t frames) {
    uint32_t i,e,start=accel_read(ACCEL_BOUNDARY_COUNT);
    for(i=0;i<ACCEL_POLL_LIMIT;++i) {
        e=accel_error();if(e) return e;
        if((uint32_t)(accel_read(ACCEL_BOUNDARY_COUNT)-start)>=frames) return 0;
    }
    return UINT32_C(0xE106);
}
#endif
