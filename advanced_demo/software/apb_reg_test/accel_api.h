#ifndef ACCEL_API_H
#define ACCEL_API_H
#include "accel_regs.h"

/* Polling-only API. CPU accesses only APB; src_addr is a DDR address for DMA.
 * Returns 0 on success, hardware ERROR_CODE or an E0xx/E1xx software error otherwise.
 * One CPU owns the command stream. v7 has an eight-entry descriptor queue;
 * v6 retains the synchronous command contract. */
#ifndef ACCEL_POLL_LIMIT
#define ACCEL_POLL_LIMIT UINT32_C(20000000)
#endif

/* Firmware has one command producer after accel_init(). Cache immutable
 * capabilities, the acknowledged command counter, and persistent descriptor
 * registers so the hot path does not reread/rewrite unchanged APB state. */
static uint32_t accel_cached_capabilities;
static uint32_t accel_cached_command_count;
static uint32_t accel_cached_command_op,accel_cached_source_addr,accel_cached_source_stride;
static uint32_t accel_cached_rect_x,accel_cached_rect_y;
static uint32_t accel_cached_rect_width,accel_cached_rect_height,accel_cached_rect_color;
static uint32_t accel_cached_capabilities_valid;
static uint32_t accel_cached_command_count_valid;
static uint32_t accel_cached_descriptor_valid;
static uint32_t accel_command_batch_active;
static uint32_t accel_batch_start_count,accel_batch_command_count;

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
    uint32_t i,s,bs,e,version,caps;
    accel_cached_capabilities_valid=0u;
    accel_cached_command_count_valid=0u;
    accel_cached_descriptor_valid=0u;
    version=accel_read(ACCEL_VERSION);
    if(accel_read(ACCEL_ID)!=ACCEL_ID_EXPECTED ||
       (version!=ACCEL_VERSION_EXPECTED && version!=UINT32_C(0x00070000))) return UINT32_C(0xE000);
    for(i=0;i<ACCEL_POLL_LIMIT;++i) {
        e=accel_read(ACCEL_ERROR_CODE);if(e) return e;
        s=accel_read(ACCEL_STATUS);bs=accel_read(ACCEL_BUFFER_STATUS);
        if((s&ACCEL_INIT_DONE) && !(s&ACCEL_BUSY) && (bs&FRAME_FRONT_VALID) &&
           !(bs&(FRAME_SWAP_PENDING|FRAME_WRITER_OWNED))) break;
    }
    if(i==ACCEL_POLL_LIMIT) return UINT32_C(0xE001);
    caps=accel_read(ACCEL_CAPABILITIES);
    if(accel_read(ACCEL_WIDTH)!=1920 || accel_read(ACCEL_HEIGHT)!=1080 ||
       accel_read(ACCEL_STRIDE)!=7680 ||
       ((caps&~ACCEL_CAP_FULLSCREEN_BACKGROUND)!=ACCEL_CAPABILITIES_EXPECTED &&
        (caps&~ACCEL_CAP_FULLSCREEN_BACKGROUND)!=(ACCEL_CAPABILITIES_EXPECTED|ACCEL_CAP_COMMAND_QUEUE)) ||
       accel_read(ACCEL_SERVICE_READ_QUOTA)!=128 ||
       accel_read(ACCEL_SERVICE_WATERMARKS)!=UINT32_C(0x02000180) ||
       !(accel_read(ACCEL_SERVICE_STATUS)&(1u<<5))) return UINT32_C(0xE003);
    accel_cached_capabilities=caps;
    accel_cached_command_count=accel_read(ACCEL_COMMAND_COUNT);
    accel_cached_capabilities_valid=1u;
    accel_cached_command_count_valid=1u;
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

/* The game owns one command stream and does not swap buffers until a frame is
 * drained. Validate ownership once, then use queue-ready backpressure alone
 * for each descriptor. Frame end drains DMA and checks the accepted count. */
static inline uint32_t accel_command_batch_begin(void) {
    uint32_t i,e,bs,status;
    uint32_t caps=accel_cached_capabilities_valid ? accel_cached_capabilities :
                  accel_read(ACCEL_CAPABILITIES);
    accel_command_batch_active=0u;
    accel_batch_command_count=0u;
    if(!(caps&ACCEL_CAP_COMMAND_QUEUE)) return 0u;
    for(i=0u;i<ACCEL_POLL_LIMIT;++i) {
        e=accel_error();if(e) return e;
        bs=accel_read(ACCEL_BUFFER_STATUS);
        if(!(bs&FRAME_FRONT_VALID) || (bs&FRAME_SWAP_PENDING)) return UINT32_C(0xE102);
        status=accel_read(ACCEL_STATUS);
        if(status&ACCEL_COMMAND_QUEUE_READY) {
            accel_batch_start_count=accel_read(ACCEL_COMMAND_COUNT);
            accel_command_batch_active=1u;
            return 0u;
        }
    }
    return UINT32_C(0xE102);
}

static inline uint32_t accel_command_batch_end(void) {
    uint32_t e,expected,accepted;
    if(!accel_command_batch_active) return accel_wait_done();
    accel_command_batch_active=0u;
    e=accel_wait_done();
    if(e) return e;
    expected=accel_batch_start_count+accel_batch_command_count;
    accepted=accel_read(ACCEL_COMMAND_COUNT);
    if(accepted!=expected) return UINT32_C(0xE103);
    accel_cached_command_count=accepted;
    accel_cached_command_count_valid=1u;
    return 0u;
}

static inline uint32_t accel_submit(uint32_t op,uint32_t src_addr,uint32_t src_stride,
                                  uint32_t x,uint32_t y,uint32_t width,uint32_t height,uint32_t color) {
    uint32_t before=0u,i,e,bs,status;
    uint32_t caps=accel_cached_capabilities_valid ? accel_cached_capabilities :
                  accel_read(ACCEL_CAPABILITIES);
    if(caps&ACCEL_CAP_COMMAND_QUEUE) {
        for(i=0;i<ACCEL_POLL_LIMIT;++i) {
            status=accel_read(ACCEL_STATUS);
            if(status&ACCEL_COMMAND_QUEUE_READY) break;
            e=accel_error();if(e) return e;
            if(!accel_command_batch_active) {
                bs=accel_read(ACCEL_BUFFER_STATUS);
                if(!(bs&FRAME_FRONT_VALID) || (bs&FRAME_SWAP_PENDING)) return UINT32_C(0xE102);
            }
        }
        if(i==ACCEL_POLL_LIMIT) return UINT32_C(0xE102);
    } else {
        bs=accel_read(ACCEL_BUFFER_STATUS);
        if(!(bs&FRAME_FRONT_VALID) || (bs&(FRAME_SWAP_PENDING|FRAME_WRITER_OWNED)) ||
           (accel_read(ACCEL_STATUS)&ACCEL_BUSY)) return UINT32_C(0xE102);
        e=accel_error();if(e) return e;
    }
    if(!(accel_command_batch_active && (caps&ACCEL_CAP_COMMAND_QUEUE)))
        before=accel_cached_command_count_valid ? accel_cached_command_count :
               accel_read(ACCEL_COMMAND_COUNT);

    /* Bracket a whole descriptor with one ordering fence pair. Volatile stores
     * remain ordered, and the final CONTROL write still commits the snapshot. */
    {
        volatile uint32_t *regs=(volatile uint32_t *)ACCEL_BASE;
        uint32_t valid=accel_cached_descriptor_valid;
        __asm__ volatile ("fence iorw,iorw" ::: "memory");
        if(!valid || accel_cached_command_op!=op) {
            regs[ACCEL_COMMAND_OP/4u]=op;accel_cached_command_op=op;
        }
        if(!valid || accel_cached_source_addr!=src_addr) {
            regs[ACCEL_SRC_ADDR/4u]=src_addr;accel_cached_source_addr=src_addr;
        }
        if(!valid || accel_cached_source_stride!=src_stride) {
            regs[ACCEL_SRC_STRIDE/4u]=src_stride;accel_cached_source_stride=src_stride;
        }
        if(!valid || accel_cached_rect_x!=x) {
            regs[ACCEL_RECT_X/4u]=x;accel_cached_rect_x=x;
        }
        if(!valid || accel_cached_rect_y!=y) {
            regs[ACCEL_RECT_Y/4u]=y;accel_cached_rect_y=y;
        }
        if(!valid || accel_cached_rect_width!=width) {
            regs[ACCEL_RECT_WIDTH/4u]=width;accel_cached_rect_width=width;
        }
        if(!valid || accel_cached_rect_height!=height) {
            regs[ACCEL_RECT_HEIGHT/4u]=height;accel_cached_rect_height=height;
        }
        if(!valid || accel_cached_rect_color!=color) {
            regs[ACCEL_RECT_COLOR/4u]=color;accel_cached_rect_color=color;
        }
        regs[ACCEL_CONTROL/4u]=1u;
        __asm__ volatile ("fence iorw,iorw" ::: "memory");
        accel_cached_descriptor_valid=1u;
    }
    if(accel_command_batch_active && (caps&ACCEL_CAP_COMMAND_QUEUE)) {
        ++accel_batch_command_count;
        return 0u;
    }
    /* A new count acknowledges this START, so an old sticky DONE cannot win. */
    for(i=0;i<ACCEL_POLL_LIMIT;++i) {
        if(accel_read(ACCEL_COMMAND_COUNT)==before+1u) {
            accel_cached_command_count=before+1u;
            accel_cached_command_count_valid=1u;
            return (caps&ACCEL_CAP_COMMAND_QUEUE) ? 0u : accel_wait_done();
        }
        /* The success path needs only the counter read. Check error when the
         * expected admission has not happened yet, and on the next submit. */
        e=accel_error();if(e) return e;
    }
    return UINT32_C(0xE103);
}
static inline uint32_t accel_fill_rect(uint32_t x,uint32_t y,uint32_t width,uint32_t height,uint32_t color) {
    return accel_submit(ACCEL_OP_FILL,0,0,x,y,width,height,color);
}
/* Source is an absolute address in current Front; stride=7680. Destination x
 * and width are multiples of four. On v7 submit acknowledges queue admission;
 * drain with accel_wait_done() before a swap. v6 remains synchronous. */
static inline uint32_t accel_blit(uint32_t src_addr,uint32_t src_stride,uint32_t x,uint32_t y,
                                uint32_t width,uint32_t height) {
    return accel_submit(ACCEL_OP_BLIT,src_addr,src_stride,x,y,width,height,0);
}
/* Same source/alignment/completion contract as BLIT. Matching RGB pixels leave
 * the existing Back pixel untouched. Prepare Back's background first; X is not
 * alpha. No implicit wait, swap, image loading, or destination-background read. */
static inline uint32_t accel_color_key_blit(uint32_t src_addr,uint32_t src_stride,uint32_t x,uint32_t y,
                                          uint32_t width,uint32_t height,uint32_t key_rgb) {
    return accel_submit(ACCEL_OP_COLOR_KEY,src_addr,src_stride,x,y,width,height,key_rgb & UINT32_C(0x00FFFFFF));
}
/* Alpha source pixels use ARGB8888. global_alpha scales each source alpha;
 * the destination X byte is retained. Both coordinates and width must be
 * four-pixel aligned, and the command reads/writes only sealed sprite pixels. */
static inline uint32_t accel_alpha_blend(uint32_t src_addr,uint32_t src_stride,
                                         uint32_t x,uint32_t y,uint32_t width,
                                         uint32_t height,uint32_t global_alpha) {
    return accel_submit(ACCEL_OP_ALPHA_BLEND,src_addr,src_stride,x,y,width,height,
                       global_alpha&UINT32_C(0xFF));
}
static inline uint32_t accel_sprite_begin(void) {
    uint32_t i,s;
    s=accel_read(ACCEL_SPRITE_STATUS);
    if(!(s&UINT32_C(0x80000000)) || (s&3u)) return UINT32_C(0xE201);
    accel_write(ACCEL_SPRITE_CONTROL,1u);
    for(i=0;i<ACCEL_POLL_LIMIT;++i) {
        s=accel_read(ACCEL_SPRITE_STATUS);
        if(s&2u) return UINT32_C(0xE202);
        if(s&1u) return 0;
    }
    return UINT32_C(0xE203);
}
static inline uint32_t accel_sprite_seal(void) {
    uint32_t i,s=accel_read(ACCEL_SPRITE_STATUS);
    if(!(s&1u) || (s&2u)) return UINT32_C(0xE204);
    accel_write(ACCEL_SPRITE_CONTROL,2u);
    for(i=0;i<ACCEL_POLL_LIMIT;++i) {
        s=accel_read(ACCEL_SPRITE_STATUS);
        if(s&1u) return UINT32_C(0xE205);
        if(s&2u) return 0;
    }
    return UINT32_C(0xE206);
}
static inline uint32_t accel_alpha_pixel_reference(uint32_t src,uint32_t dst,
                                                    uint32_t global_alpha) {
    uint32_t a=((src>>24)*(global_alpha&255u)+127u)/255u;
    uint32_t r=((((src>>16)&255u)*a+((dst>>16)&255u)*(255u-a)+127u)/255u);
    uint32_t g=((((src>>8)&255u)*a+((dst>>8)&255u)*(255u-a)+127u)/255u);
    uint32_t b=(((src&255u)*a+(dst&255u)*(255u-a)+127u)/255u);
    return (dst&UINT32_C(0xFF000000))|(r<<16)|(g<<8)|b;
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
