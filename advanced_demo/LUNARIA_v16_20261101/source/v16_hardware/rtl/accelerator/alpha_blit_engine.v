`timescale 1ns/1ps
// Straight-alpha read/modify/write BLIT. One source and one Back read per segment.
// ARADDR is absolute; AWADDR is relative to the command's latched Back.
// A wrapper must add Back exactly once and preserve its 4KiB alignment.
module alpha_blit_engine #(
    parameter FRAME_WIDTH = 1920,
    parameter FRAME_HEIGHT = 1080,
    parameter FRAME_STRIDE = 7680,
    parameter MAX_BURST_BEATS = 32,
    parameter WATCHDOG_BITS = 27,
    parameter STREAM_ENABLE = 0,
    // Fixed immutable atlas tile: 16x16 ARGB enemy bullet at x=144,y=0.
    // Caller must enforce the platform sprite seal/source guard lifetime.
    parameter SPRITE_CACHE_ENABLE = 0,
    // v12: tagged 32-pixel source rows (128 rows / 16 KiB), plus one W beat
    // per clock. Defaults preserve the fixed 16x16 v10/v11 cache contract.
    parameter WIDE_CACHE_ENABLE = 0, FAST_WRITE_ENABLE = 0,
    parameter BEAM_ENABLE = 0,
    // Two result banks overlap the next segment's reads/mix with AXI writes.
    // Commands remain ordered and completion always waits for every response.
    parameter TILE_PORT_ENABLE=0, OVERLAP_ENABLE = 0, READ_AHEAD_ENABLE = 0
)(
    input wire clk, rst_n, enabled, start,
    input wire [31:0] src_addr, src_stride, back_base,
    input wire [7:0] global_alpha,
    input wire beam_mode,
    input wire tile_local,
    input wire [127:0] tile_read_data,
    output wire [31:0] tile_read_address,tile_write_address,
    output wire [127:0] tile_write_data,
    output wire tile_write_enable,
    input wire [23:0] beam_rgb,
    input wire [31:0] dst_x, dst_y, width, height,
    output wire busy,
    output reg done,
    output reg [31:0] error_code, command_count,
    output wire [511:0] perf_counters,
    output wire [255:0] read_perf_counters,

    output wire [31:0] araddr,
    output wire [7:0] arlen,
    output wire arvalid,
    input wire arready,
    input wire [127:0] rdata,
    input wire [3:0] rid,
    input wire [1:0] rresp,
    input wire rlast, rvalid,
    output wire rready,

    output wire [31:0] awaddr,
    output wire [7:0] awlen,
    output wire awvalid,
    input wire awready,
    output wire [127:0] wdata,
    output wire [15:0] wstrb,
    output wire wlast, wvalid,
    input wire wready,
    input wire [3:0] bid,
    input wire [1:0] bresp,
    input wire bvalid,
    output wire bready
);
// Prototype-local errors: these are NOT new shared APB error assignments.
localparam [31:0] ERR_PARAM = 32'h21, ERR_READ = 32'h22,
    ERR_WRITE = 32'h23, ERR_TIMEOUT = 32'h24, ERR_PROTOCOL = 32'h25;
localparam [4:0] IDLE = 0, CHECK = 1, PREP = 2, RD_ADDR = 3,
    RD_DATA = 4, WR_ADDR = 5, WR_LOAD = 6, WR_DATA = 7,
    WR_RESP = 8, ADVANCE = 9, FAULT = 10,
    CHECK_SPAN = 11, CHECK_END = 12, CHECK_RANGE = 13,
    BG_ADDR = 14, BG_DATA = 15, MIX_LOAD = 16, MIX_START = 17, MIX_WAIT = 18,
    DRAIN_R = 19, MIX_STREAM = 20, CACHE_LOOKUP = 21,
    BEAM_SCAN = 22, BEAM_ROW = 23, FINISH_WRITES = 24;
localparam [63:0] FRAME_BYTES = 64'd1 * FRAME_STRIDE * FRAME_HEIGHT;

reg [4:0] state;
reg [31:0] saved_back_base;
reg [7:0] saved_alpha;
reg [127:0] background_mem [0:MAX_BURST_BEATS-1];
reg [127:0] source_read_data,background_read_data;
wire [127:0] mix_result;
wire mix_valid;
reg mix_input_valid;
reg [8:0] mix_issue_index, mix_return_index;
reg [127:0] cache_read_data;
reg saved_beam,saved_tile;
reg [23:0] saved_beam_rgb;
reg signed [31:0] beam_nx, beam_ny, beam_distance, beam_row_distance;
reg signed [31:0] beam_segment_distance, beam_mix_distance;
reg [127:0] beam_read_data;
// Procedural ARGB, no texture reads. Distance is Q14 pixels perpendicular
// to the beam; src packs signed nx/ny, stride carries distance at rect origin.
function [31:0] beam_pixel;
    input signed [31:0] distance;
    reg [31:0] magnitude, q;
    reg [7:0] a;
    reg [23:0] rgb;
    begin
        magnitude = distance < 0 ? -distance : distance;
        q = magnitude >> 12;
        a = 0; rgb = saved_beam_rgb;
        if (saved_alpha < 128) begin
            if (q < 8) a = 255 - q*32;
        end else if (q < 32) begin
            if (q < 8) a = 255;
            else if (q < 16) a = 255 - (q-8)*8;
            else if (q < 24) a = 191 - (q-16)*16;
            else a = 63 - (q-24)*8;
            if (q < 6) rgb = 24'hfff4ff;
        end
        beam_pixel = {a,rgb};
    end
endfunction
function [127:0] beam_quad;
    input signed [31:0] distance;
    begin
        beam_quad = {beam_pixel(distance+beam_nx*3),beam_pixel(distance+beam_nx*2),
                     beam_pixel(distance+beam_nx),beam_pixel(distance)};
    end
endfunction
wire signed [31:0] beam_last_distance = beam_distance + beam_nx*3;
wire signed [31:0] beam_radius = saved_alpha < 128 ? 32'sd32768 : 32'sd131072;
wire beam_visible = saved_alpha != 0 &&
    ((beam_distance < beam_radius && beam_last_distance > -beam_radius) ||
     (beam_last_distance < beam_radius && beam_distance > -beam_radius));
wire [127:0] pixel_foreground = BEAM_ENABLE && saved_beam ? beam_read_data :
    SPRITE_CACHE_ENABLE && cache_use ? cache_read_data : source_read_data;
alpha_pixel_pipeline pixels (
    .clk(clk),.rst_n(rst_n),.in_valid(STREAM_ENABLE ? mix_input_valid : state==MIX_START),
    .foreground(pixel_foreground),.background(saved_tile?tile_read_data:background_read_data),.global_alpha(saved_alpha),
    .out_valid(mix_valid),.result(mix_result));
assign tile_read_address=dst_cursor+(mix_read_index<<4);
assign tile_write_address=dst_cursor+(store_index<<4);
assign tile_write_data=mix_result;
assign tile_write_enable=saved_tile && mixed_store && error_code==0 && !timed_out;
reg [31:0] source, source_stride, x, y, copy_width, copy_height;
reg [31:0] src_row, dst_row, src_cursor, dst_cursor;
reg [31:0] rows_left, beats_left;
reg [8:0] burst_beats, beat_index;
reg [WATCHDOG_BITS-1:0] watchdog;
reg [127:0] beat_mem [0:MAX_BURST_BEATS-1];
reg segment_read_error;
// Issue the target read immediately after the source AR is accepted. Both
// share ID0 and return in source/target order. Never withdraw an exposed AR.
reg bg_prefetch_pending,bg_prefetch_accepted;
wire prefetch_ar = READ_AHEAD_ENABLE && bg_prefetch_pending;
wire prefetch_take = prefetch_ar && arready;

reg invalid_geometry_latched;
reg [31:0] rows_before_last, destination_start_latched;
reg [63:0] source_span, source_end;

localparam [2:0] PW_IDLE=0, PW_ADDR=1, PW_LOAD=2, PW_DATA=3, PW_RESP=4;
reg [2:0] write_state;
reg produce_bank, consume_bank;
reg [1:0] result_ready;
reg [31:0] result_addr[0:1];
reg [8:0] result_beats[0:1];
reg [127:0] result_mem[0:63];
reg [127:0] result_read_data;
reg [8:0] write_index;
reg [WATCHDOG_BITS-1:0] write_watchdog;
wire write_timed_out = OVERLAP_ENABLE && (&write_watchdog);
wire write_activity = (awvalid && awready) || (wvalid && wready) || (bvalid && bready);
wire write_last = write_index == result_beats[consume_bank]-1'b1;
wire enqueue_result = OVERLAP_ENABLE && !saved_tile && mix_valid && error_code==0 && !timed_out &&
    ((state==MIX_WAIT && last_beat) ||
     (state==MIX_STREAM && mix_return_index==burst_beats-1'b1));
wire [8:0] next_write_index = write_state==PW_DATA ? write_index+9'd1 : write_index;

// Counters wrap modulo 2^32. Slots are documented in LUNARIA_DDR_V14.md.
reg [31:0] perf[0:15];
reg perf_background_read;
always @(posedge clk or negedge rst_n)
    if(!rst_n) perf_background_read<=0;
    else if(state==RD_ADDR && arready) perf_background_read<=0;
    else if(state==BG_ADDR) perf_background_read<=1;
wire [15:0] perf_event = {
    (busy && write_state!=PW_IDLE && state!=FINISH_WRITES && state!=PREP),
    (state==PREP && result_ready[produce_bank]),
    mixed_store, (bready && !bvalid), (wvalid && !wready),
    (awvalid && !awready), (rready && !rvalid), (arvalid && !arready),
    (state==CACHE_LOOKUP && !(cache_eligible && sprite_cache_valid[cache_row] && cache_tag_read==src_cursor[31:7])),
    (state==CACHE_LOOKUP && cache_eligible && sprite_cache_valid[cache_row] && cache_tag_read==src_cursor[31:7]),
    (wvalid && wready), (perf_background_read && rvalid && rready),
    (!perf_background_read && rvalid && rready), busy, (state==IDLE && start && enabled), 1'b1};
genvar perf_slot;
generate for(perf_slot=0;perf_slot<16;perf_slot=perf_slot+1) begin: counters
    assign perf_counters[perf_slot*32+:32] = OVERLAP_ENABLE ? perf[perf_slot] : 32'b0;
    always @(posedge clk or negedge rst_n)
        if(!rst_n) perf[perf_slot]<=0;
        else if(OVERLAP_ENABLE && perf_event[perf_slot]) perf[perf_slot]<=perf[perf_slot]+1'b1;
end endgenerate

// Read latency diagnostics count overlapping outstanding requests separately.
reg source_first_pending,target_first_pending,source_seen,target_seen;
wire source_ar_take=state==RD_ADDR && arready;
wire target_ar_take=arvalid && arready && !source_ar_take;
wire source_return=state==RD_DATA && rvalid && rready;
wire target_return=state==BG_DATA && rvalid && rready;
wire [7:0] read_event={target_ar_take,source_ar_take,
    (state==BG_DATA && target_seen && !rvalid),
    (state==RD_DATA && source_seen && !rvalid),
    (target_first_pending && !target_return),
    (source_first_pending && !source_return),
    (arvalid && !arready && state!=RD_ADDR),
    (arvalid && !arready && state==RD_ADDR)};
always @(posedge clk or negedge rst_n)
    if(!rst_n) begin source_first_pending<=0;target_first_pending<=0;source_seen<=0;target_seen<=0;end
    else begin
        if(source_ar_take)begin source_first_pending<=1;source_seen<=0;end
        if(target_ar_take)begin target_first_pending<=1;target_seen<=0;end
        if(source_return)begin source_first_pending<=0;source_seen<=1;end
        if(target_return)begin target_first_pending<=0;target_seen<=1;end
        if(state==IDLE)begin source_first_pending<=0;target_first_pending<=0;end
    end
reg [31:0] read_perf[0:7];
generate for(perf_slot=0;perf_slot<8;perf_slot=perf_slot+1)begin: read_counters
    assign read_perf_counters[perf_slot*32+:32]=READ_AHEAD_ENABLE ? read_perf[perf_slot] : 0;
    always @(posedge clk or negedge rst_n)
        if(!rst_n)read_perf[perf_slot]<=0;
        else if(READ_AHEAD_ENABLE && read_event[perf_slot])read_perf[perf_slot]<=read_perf[perf_slot]+1'b1;
end endgenerate

// 64 x 128 bits, no data reset: infer block RAM, reset only validity tags.
// A row becomes valid only after an entire successful four-beat source read.
// Clipped draws can hit valid rows, but cannot populate partial rows.
localparam CACHE_INDEX_BITS = WIDE_CACHE_ENABLE ? 7 : 4;
localparam CACHE_OFFSET_BITS = WIDE_CACHE_ENABLE ? 3 : 2;
localparam CACHE_ROWS = 1 << CACHE_INDEX_BITS;
localparam CACHE_WORDS = 1 << (CACHE_INDEX_BITS + CACHE_OFFSET_BITS);
reg [127:0] sprite_cache [0:CACHE_WORDS-1];
reg [CACHE_ROWS-1:0] sprite_cache_valid;
reg [CACHE_INDEX_BITS-1:0] cache_row;
reg [CACHE_OFFSET_BITS-1:0] cache_offset;
reg [24:0] cache_tags[0:127];
// Exact transparent span metadata, committed with the existing row-valid tag.
// One bit describes four source pixels; nonzero alpha always remains visible.
reg [7:0] cache_opaque_beats[0:127];
reg [7:0] cache_opaque_read;
reg [8:0] transparent_tail;
reg [8:0] visible_first, visible_end;
integer span_i;
always @* begin
    visible_first=burst_beats; visible_end=0;
    for(span_i=0;span_i<8;span_i=span_i+1)
        if(span_i<burst_beats && cache_offset+span_i<8 &&
           cache_opaque_read[cache_offset+span_i] && saved_alpha!=0) begin
            if(visible_first==burst_beats)visible_first=span_i;
            visible_end=span_i+1;
        end
end
reg [24:0] cache_tag_read;
wire [6:0] wide_index = src_cursor[13:7] ^ src_cursor[20:14];
reg cache_use, cache_fill;
reg cache_address_match;
reg [3:0] cache_address_row;
integer cache_decode_row;
always @* begin
    cache_address_match = 0; cache_address_row = 0;
    for (cache_decode_row=0; cache_decode_row<16; cache_decode_row=cache_decode_row+1)
        if (src_cursor[31:6] == ((32'h01384240 + cache_decode_row*32'd2560) >> 6)) begin
            cache_address_match = 1; cache_address_row = cache_decode_row;
        end
end
wire cache_eligible = SPRITE_CACHE_ENABLE && source_stride == 32'd2560 &&
    (WIDE_CACHE_ENABLE ?
      (src_cursor >= 32'h01384000 && src_cursor < 32'h014b0000 &&
       segment_beats <= (32'd8 - {29'b0,src_cursor[6:4]})) :
      (cache_address_match && segment_beats <= (32'd4 - {30'b0,src_cursor[5:4]})));
wire [8:0] mix_read_index = STREAM_ENABLE ? mix_issue_index : beat_index;
wire [8:0] source_read_index = state == MIX_LOAD || state == MIX_STREAM ? mix_read_index :
    (FAST_WRITE_ENABLE && state==WR_DATA ? beat_index+9'd1 : beat_index);
wire [CACHE_INDEX_BITS+CACHE_OFFSET_BITS-1:0] cache_read_index =
    {cache_row,{CACHE_OFFSET_BITS{1'b0}}} + cache_offset + mix_read_index;

// Keep full precision for rejection of invalid, overflowing addresses. Register
// subtraction, multiplication, addition and range checking on separate cycles:
// the original combined expression reached 51 logic levels at 100 MHz.
wire [63:0] row_bytes = {32'b0, copy_width} << 2;
wire [63:0] destination_start = {32'b0, y} * FRAME_STRIDE +
    ({32'b0, x} << 2);
wire invalid_geometry = copy_width == 0 || copy_height == 0 ||
    {32'b0, x} + {32'b0, copy_width} > FRAME_WIDTH ||
    {32'b0, y} + {32'b0, copy_height} > FRAME_HEIGHT ||
    saved_back_base[11:0] != 0 ||
    {32'b0,saved_back_base}+FRAME_BYTES > 64'h100000000 ||
    x[1:0] != 0 || copy_width[1:0] != 0 ||
    (saved_beam ? (beam_nx < -16384 || beam_nx > 16384 ||
        beam_ny < -16384 || beam_ny > 16384 || (beam_nx==0 && beam_ny==0) ||
        $signed(source_stride) < -536870912 || $signed(source_stride) > 536870912) :
    (source[3:0] != 0 || source_stride[3:0] != 0 ||
    x[1:0] != 0 || copy_width[1:0] != 0 ||
    {32'b0, source_stride} < row_bytes));

wire [31:0] src_page_beats = (32'd4096 - {20'b0, src_cursor[11:0]}) >> 4;
wire [31:0] dst_page_beats = (32'd4096 - {20'b0, dst_cursor[11:0]}) >> 4;
wire [31:0] capped_beats = beats_left < MAX_BURST_BEATS ? beats_left : MAX_BURST_BEATS;
wire [31:0] src_capped = capped_beats < src_page_beats ? capped_beats : src_page_beats;
wire [31:0] segment_beats = src_capped < dst_page_beats ? src_capped : dst_page_beats;
wire [8:0] advance_beats = burst_beats + transparent_tail;
wire [31:0] segment_bytes = {19'b0, advance_beats, 4'b0};
wire last_beat = beat_index == burst_beats - 1'b1;
wire bad_read = rresp != 2'b00 || rid != 4'b0000;
wire bad_write = bresp != 2'b00 || bid != 4'b0000;
wire activity = (arvalid && arready) || (rvalid && rready) ||
    (awvalid && awready) || (wvalid && wready) || (bvalid && bready) ||
    state == BEAM_SCAN || state == BEAM_ROW || state == MIX_LOAD || (state == MIX_STREAM &&
        (mix_issue_index < burst_beats || mix_valid));
wire timed_out = &watchdog;

assign busy = state != IDLE;
assign araddr = (state==BG_ADDR || prefetch_ar) ? saved_back_base+dst_cursor : src_cursor;
assign arlen = burst_beats - 1'b1;
assign arvalid = state == RD_ADDR || prefetch_ar ||
    (state == BG_ADDR && !bg_prefetch_accepted);
assign rready = state == RD_DATA || state == BG_DATA || state == DRAIN_R;
assign awaddr = OVERLAP_ENABLE ? result_addr[consume_bank] : dst_cursor;
assign awlen = OVERLAP_ENABLE ? result_beats[consume_bank]-1'b1 : burst_beats - 1'b1;
assign awvalid = OVERLAP_ENABLE ? write_state==PW_ADDR : state == WR_ADDR;
assign wstrb = 16'hffff;
assign wdata = OVERLAP_ENABLE ? result_read_data : source_read_data;
assign wvalid = OVERLAP_ENABLE ? write_state==PW_DATA : state == WR_DATA;
assign wlast = wvalid && (OVERLAP_ENABLE ? write_last : last_beat);
assign bready = OVERLAP_ENABLE ? write_state==PW_RESP : state == WR_RESP;

wire source_store = state == RD_DATA && rvalid && rready;
wire mixed_store = mix_valid && (state == MIX_WAIT || (STREAM_ENABLE && state == MIX_STREAM));
wire [8:0] store_index = STREAM_ENABLE && !source_store ? mix_return_index : beat_index;
wire [127:0] store_data = source_store ? rdata : mix_result;

// No reset on the storage array. Only entries received by a complete read
// burst can be used. WR_LOAD below provides a synchronous memory read cycle.
always @(posedge clk) begin
    if (rst_n && (source_store || (!OVERLAP_ENABLE && mixed_store)))
        beat_mem[store_index] <= store_data;
    if (rst_n && OVERLAP_ENABLE && mixed_store)
        result_mem[{produce_bank,store_index[4:0]}] <= mix_result;
    if (OVERLAP_ENABLE && (write_state==PW_LOAD ||
        (write_state==PW_DATA && wready && !write_last)))
        result_read_data <= result_mem[{consume_bank,next_write_index[4:0]}];
    if (rst_n && state == BG_DATA && rvalid && rready)
        background_mem[beat_index] <= rdata;
    if (rst_n && SPRITE_CACHE_ENABLE && cache_fill && state == RD_DATA && rvalid && rready)
        sprite_cache[{cache_row,beat_index[CACHE_OFFSET_BITS-1:0]}] <= rdata;
    if (WIDE_CACHE_ENABLE && state==PREP) begin
        cache_tag_read <= cache_tags[wide_index];
        cache_opaque_read <= cache_opaque_beats[wide_index];
    end
    if (READ_AHEAD_ENABLE && WIDE_CACHE_ENABLE && rst_n && cache_fill && source_store)
        cache_opaque_beats[cache_row][beat_index[2:0]] <=
            |{rdata[127:120],rdata[95:88],rdata[63:56],rdata[31:24]};
    if (WIDE_CACHE_ENABLE && rst_n && cache_fill && source_store && last_beat &&
        rlast && !bad_read && !segment_read_error && error_code==0 && !timed_out)
        cache_tags[cache_row] <= src_cursor[31:7];
    // Dedicated synchronous read register has no reset or bypass mux, so the
    // synthesis tool can absorb it into BRAM instead of making 8192 flip-flops.
    if (SPRITE_CACHE_ENABLE && (state == MIX_LOAD ||
        (state == MIX_STREAM && mix_issue_index < burst_beats)))
        cache_read_data <= sprite_cache[cache_read_index];
    if (state == WR_LOAD || (FAST_WRITE_ENABLE && state==WR_DATA && wready && !last_beat) || state == MIX_LOAD ||
        (STREAM_ENABLE && state == MIX_STREAM && mix_issue_index < burst_beats))
        source_read_data <= beat_mem[source_read_index];
    if (state == MIX_LOAD ||
        (STREAM_ENABLE && state == MIX_STREAM && mix_issue_index < burst_beats))
        background_read_data <= background_mem[mix_read_index];
    if (BEAM_ENABLE && saved_beam && (state==MIX_LOAD ||
        (STREAM_ENABLE && state==MIX_STREAM && mix_issue_index < burst_beats)))
        beam_read_data <= beam_quad(beam_mix_distance);
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= IDLE;
        done <= 0; error_code <= 0; command_count <= 0;
        saved_back_base<=0;saved_alpha<=0;
        saved_tile<=0;saved_beam<=0;saved_beam_rgb<=0;beam_nx<=0;beam_ny<=0;
        beam_distance<=0;beam_row_distance<=0;beam_segment_distance<=0;beam_mix_distance<=0;
        source <= 0; source_stride <= 0; x <= 0; y <= 0;
        copy_width <= 0; copy_height <= 0;
        src_row <= 0; dst_row <= 0; src_cursor <= 0; dst_cursor <= 0;
        rows_left <= 0; beats_left <= 0;
        burst_beats <= 0; beat_index <= 0; watchdog <= 0;
        transparent_tail<=0;segment_read_error <= 0;bg_prefetch_pending<=0;bg_prefetch_accepted<=0;
        invalid_geometry_latched <= 0; rows_before_last <= 0;
        destination_start_latched <= 0; source_span <= 0; source_end <= 0;
        mix_input_valid<=0;mix_issue_index<=0;mix_return_index<=0;
        sprite_cache_valid<=0;cache_row<=0;cache_offset<=0;cache_use<=0;cache_fill<=0;
        produce_bank<=0;consume_bank<=0;result_ready<=0;
        write_state<=PW_IDLE;write_index<=0;write_watchdog<=0;
        result_addr[0]<=0;result_addr[1]<=0;result_beats[0]<=0;result_beats[1]<=0;
    end else begin
        mix_input_valid <= 0;
        if(prefetch_take) begin bg_prefetch_pending<=0;bg_prefetch_accepted<=1;end
        if (state == IDLE || activity)
            watchdog <= 0;
        else if (!timed_out)
            watchdog <= watchdog + 1'b1;

        // A timeout records failure but NEVER cancels an exposed VALID or
        // forgets an accepted transaction. First error wins, except malformed
        // RLAST enters the fail-stop FAULT state and reports ERR_PROTOCOL.
        if (state != IDLE && timed_out && error_code == 0)
            error_code <= ERR_TIMEOUT;

        case (state)
        IDLE: if (start && enabled) begin
            bg_prefetch_pending<=0;bg_prefetch_accepted<=0;
            saved_tile<=TILE_PORT_ENABLE && tile_local;
            saved_back_base<=back_base;saved_alpha<=global_alpha;
            saved_beam<=BEAM_ENABLE && beam_mode;saved_beam_rgb<=beam_rgb;
            beam_nx<={{16{src_addr[15]}},src_addr[15:0]};
            beam_ny<={{16{src_addr[31]}},src_addr[31:16]};
            beam_distance<=src_stride;beam_row_distance<=src_stride;
            source <= src_addr; source_stride <= src_stride;
            x <= dst_x; y <= dst_y; copy_width <= width; copy_height <= height;
            done <= 0; error_code <= 0; watchdog <= 0;
            command_count <= command_count + 1'b1;
            state <= CHECK;
        end
        CHECK: begin
            invalid_geometry_latched <= invalid_geometry;
            // Zero height is rejected independently, so this 32-bit decrement
            // is exact for every legal command without a 64-bit subtractor.
            rows_before_last <= copy_height - 32'd1;
            destination_start_latched <= destination_start[31:0];
            state <= CHECK_SPAN;
        end
        CHECK_SPAN: begin
            source_span <= {32'b0, rows_before_last} * {32'b0, source_stride};
            state <= CHECK_END;
        end
        CHECK_END: begin
            source_end <= source_span + {32'b0, source} + row_bytes;
            state <= CHECK_RANGE;
        end
        CHECK_RANGE: begin
            // No AXI VALID is exposed until all registered checks succeed.
            if (invalid_geometry_latched || (!saved_beam && source_end > 64'h100000000)) begin
                error_code <= ERR_PARAM; done <= !OVERLAP_ENABLE; state <= OVERLAP_ENABLE ? FINISH_WRITES : IDLE;
            end else begin
                src_row <= source; src_cursor <= source;
                dst_row <= destination_start_latched; dst_cursor <= destination_start_latched;
                rows_left <= copy_height; beats_left <= copy_width >> 2;
                state <= PREP;
            end
        end
        PREP: begin
            mix_issue_index<=0;mix_return_index<=0;
            if (error_code != 0 || timed_out) begin
                done <= !OVERLAP_ENABLE; state <= OVERLAP_ENABLE ? FINISH_WRITES : IDLE;
            end else if (!OVERLAP_ENABLE || !result_ready[produce_bank]) begin
                burst_beats <= segment_beats[8:0]; beat_index <= 0;transparent_tail<=0;
                segment_read_error <= 0;
                if (BEAM_ENABLE && saved_beam) begin
                    burst_beats<=0;cache_use<=0;cache_fill<=0;state<=BEAM_SCAN;
                end else if (WIDE_CACHE_ENABLE && SPRITE_CACHE_ENABLE) begin
                    cache_row <= wide_index;
                    cache_offset <= src_cursor[6:4];
                    cache_use <= 0; cache_fill <= 0;
                    state <= CACHE_LOOKUP;
                end else begin
                    cache_row <= cache_address_row;
                    cache_offset <= src_cursor[5:4];
                    cache_use <= cache_eligible && sprite_cache_valid[cache_address_row];
                    cache_fill <= cache_eligible && !sprite_cache_valid[cache_address_row] &&
                        src_cursor[5:4] == 0 && segment_beats == 4;
                    state <= cache_eligible && sprite_cache_valid[cache_address_row] ? (saved_tile ? MIX_LOAD : BG_ADDR) : RD_ADDR;
                end
            end
        end
        BEAM_SCAN: begin
            // Scan four pixels per cycle, but issue DDR only for the visible
            // contiguous span. Collect bursts without crossing a row or 4KiB.
            if (beam_visible) begin
                if (burst_beats==0) beam_segment_distance<=beam_distance;
                beam_distance<=beam_distance+beam_nx*4;
                burst_beats<=burst_beats+1'b1;
                if (burst_beats+1==beats_left || burst_beats+1==MAX_BURST_BEATS ||
                    burst_beats+1==dst_page_beats) state<=saved_tile ? MIX_LOAD : BG_ADDR;
            end else if (burst_beats!=0) state<=saved_tile ? MIX_LOAD : BG_ADDR;
            else if (beats_left==1) state<=BEAM_ROW;
            else begin
                dst_cursor<=dst_cursor+16;beats_left<=beats_left-1'b1;
                beam_distance<=beam_distance+beam_nx*4;
            end
        end
        BEAM_ROW: begin
            if (rows_left==1) begin done<=!OVERLAP_ENABLE;state<=OVERLAP_ENABLE ? FINISH_WRITES : IDLE;end
            else begin
                rows_left<=rows_left-1'b1;dst_row<=dst_row+FRAME_STRIDE;
                dst_cursor<=dst_row+FRAME_STRIDE;beats_left<=copy_width>>2;
                beam_row_distance<=beam_row_distance+beam_ny;
                beam_distance<=beam_row_distance+beam_ny;state<=PREP;
            end
        end
        CACHE_LOOKUP: begin
            if (cache_eligible && sprite_cache_valid[cache_row] && cache_tag_read==src_cursor[31:7]) begin
                cache_use<=1; cache_fill<=0; state<=saved_tile ? MIX_LOAD : BG_ADDR;
                if(READ_AHEAD_ENABLE) begin
                    if(visible_end==0) state<=ADVANCE;
                    else begin
                        src_cursor<=src_cursor+(visible_first<<4);
                        dst_cursor<=dst_cursor+(visible_first<<4);
                        beats_left<=beats_left-visible_first;
                        cache_offset<=cache_offset+visible_first;
                        burst_beats<=visible_end-visible_first;
                        transparent_tail<=burst_beats-visible_end;
                    end
                end
            end else begin
                cache_use<=0;
                cache_fill<=cache_eligible && src_cursor[6:4]==0 && burst_beats==8;
                // A failed refill must never expose partially replaced pixels.
                if(cache_eligible && src_cursor[6:4]==0 && burst_beats==8)
                    sprite_cache_valid[cache_row]<=0;
                state<=RD_ADDR;
            end
        end
        RD_ADDR: if (arready) begin
            if(READ_AHEAD_ENABLE && !saved_tile)bg_prefetch_pending<=1;
            beat_index <= 0; state <= RD_DATA;
        end
        RD_DATA: if (rvalid) begin
            if (rlast != last_beat) begin
                // An invalid length/termination cannot safely be repaired by
                // this master. Keep BUSY, block commands, require platform reset.
                error_code <= ERR_PROTOCOL;
                if(rlast) begin done<=!READ_AHEAD_ENABLE && !OVERLAP_ENABLE;state<=(READ_AHEAD_ENABLE && !saved_tile) ? BG_ADDR : OVERLAP_ENABLE ? FINISH_WRITES : IDLE;end
                else state<=DRAIN_R;
            end else begin
                if (bad_read && error_code == 0 && !timed_out)
                    error_code <= ERR_READ;
                if (bad_read)
                    segment_read_error <= 1;
                if (last_beat) begin
                    if (bad_read || segment_read_error || error_code != 0 || timed_out) begin
                        done <= !READ_AHEAD_ENABLE && !OVERLAP_ENABLE; state <= (READ_AHEAD_ENABLE && !saved_tile) ? BG_ADDR : OVERLAP_ENABLE ? FINISH_WRITES : IDLE;
                    end else begin
                        if (SPRITE_CACHE_ENABLE && cache_fill)
                            sprite_cache_valid[cache_row] <= 1;
                        beat_index <= 0; state <= saved_tile ? MIX_LOAD : BG_ADDR;
                    end
                end else
                    beat_index <= beat_index + 1'b1;
            end
        end
        BG_ADDR: if(bg_prefetch_accepted || arready) begin
            bg_prefetch_accepted<=0;
            beat_index<=0;state<=BG_DATA;
        end
        BG_DATA: if(rvalid) begin
            if(rlast!=last_beat) begin
                error_code<=ERR_PROTOCOL;
                if(rlast) begin done<=!OVERLAP_ENABLE;state<=OVERLAP_ENABLE ? FINISH_WRITES : IDLE;end
                else state<=DRAIN_R;
            end else begin
                if(bad_read && error_code==0 && !timed_out) error_code<=ERR_READ;
                if(bad_read) segment_read_error<=1;
                if(last_beat) begin
                    if(bad_read || segment_read_error || error_code!=0 || timed_out) begin
                        done<=!OVERLAP_ENABLE;state<=OVERLAP_ENABLE ? FINISH_WRITES : IDLE;
                    end else begin
                        beat_index<=0;mix_issue_index<=0;mix_return_index<=0;state<=MIX_LOAD;
                        beam_mix_distance<=beam_segment_distance;
                    end
                end else beat_index<=beat_index+1'b1;
            end
        end
        MIX_LOAD: begin
            if (saved_beam) beam_mix_distance<=beam_mix_distance+beam_nx*4;
            // Synchronous reads from the two segment memories.
            if (STREAM_ENABLE) begin
                mix_input_valid<=1;mix_issue_index<=1;state<=MIX_STREAM;
            end else state<=MIX_START;
        end
        MIX_START: state<=MIX_WAIT;
        MIX_WAIT: if(mix_valid) begin
            if(error_code!=0 || timed_out) begin done<=!OVERLAP_ENABLE;state<=OVERLAP_ENABLE ? FINISH_WRITES : IDLE;end
            else if(last_beat) begin beat_index<=0;state<=(OVERLAP_ENABLE || saved_tile) ? ADVANCE : WR_ADDR;end
            else begin beat_index<=beat_index+1'b1;state<=MIX_LOAD;end
        end
        MIX_STREAM: begin
            // Registered RAM reads feed the existing four-pixel pipeline every
            // clock. Results return in order into a separate write cursor.
            if (mix_issue_index < burst_beats) begin
                mix_input_valid<=1;mix_issue_index<=mix_issue_index+1'b1;
                if (saved_beam) beam_mix_distance<=beam_mix_distance+beam_nx*4;
            end
            if (mix_valid) begin
                if (mix_return_index == burst_beats-1'b1) begin
                    if(error_code!=0 || timed_out) begin done<=!OVERLAP_ENABLE;state<=OVERLAP_ENABLE ? FINISH_WRITES : IDLE;end
                    else begin beat_index<=0;state<=(OVERLAP_ENABLE || saved_tile) ? ADVANCE : WR_ADDR;end
                end else mix_return_index<=mix_return_index+1'b1;
            end
        end
        DRAIN_R: if(rvalid && rlast) begin
            // Keep the malformed burst outstanding until its actual RLAST.
            // Drain before releasing Back to protect the shared display reader.
            if(READ_AHEAD_ENABLE && (bg_prefetch_pending || bg_prefetch_accepted)) begin
                beat_index<=0;state<=saved_tile ? MIX_LOAD : BG_ADDR;
            end else begin done<=!OVERLAP_ENABLE;state<=OVERLAP_ENABLE ? FINISH_WRITES : IDLE;end
        end
        WR_ADDR: if (awready) begin
            beat_index <= 0; state <= WR_LOAD;
        end
        WR_LOAD: begin
            state <= WR_DATA;
        end
        WR_DATA: if (wready) begin
            if (last_beat)
                state <= WR_RESP;
            else begin
                beat_index <= beat_index + 1'b1;
                state <= FAST_WRITE_ENABLE ? WR_DATA : WR_LOAD;
            end
        end
        WR_RESP: if (bvalid) begin
            if (bad_write && error_code == 0 && !timed_out)
                error_code <= ERR_WRITE;
            if (bad_write || error_code != 0 || timed_out) begin
                done <= !OVERLAP_ENABLE; state <= OVERLAP_ENABLE ? FINISH_WRITES : IDLE;
            end else
                state <= ADVANCE;
        end
        ADVANCE: begin
            if (saved_beam) begin
                if (beats_left==burst_beats) state<=BEAM_ROW;
                else begin
                    dst_cursor<=dst_cursor+segment_bytes;
                    beats_left<=beats_left-burst_beats;state<=PREP;
                end
            end else if (beats_left == advance_beats) begin
                if (rows_left == 1) begin
                    done <= !OVERLAP_ENABLE; state <= OVERLAP_ENABLE ? FINISH_WRITES : IDLE;
                end else begin
                    rows_left <= rows_left - 1'b1;
                    src_row <= src_row + source_stride;
                    dst_row <= dst_row + FRAME_STRIDE;
                    src_cursor <= src_row + source_stride;
                    dst_cursor <= dst_row + FRAME_STRIDE;
                    beats_left <= copy_width >> 2; state <= PREP;
                end
            end else begin
                src_cursor <= src_cursor + segment_bytes;
                dst_cursor <= dst_cursor + segment_bytes;
                beats_left <= beats_left - advance_beats; state <= PREP;
            end
        end
        FAULT: begin state<=FAULT;end
        FINISH_WRITES: if(result_ready==0 && write_state==PW_IDLE) begin
            done<=1;state<=IDLE;
        end
        default: begin error_code <= ERR_PROTOCOL; state <= FAULT; end
        endcase

        if(OVERLAP_ENABLE) begin
            if(enqueue_result) begin
                result_ready[produce_bank]<=1;
                result_addr[produce_bank]<=dst_cursor;
                result_beats[produce_bank]<=burst_beats;
                produce_bank<=!produce_bank;
            end
            // Per-writer watchdog: progress on the read channel must not hide
            // a stalled AW/W/B. An exposed transaction is always drained.
            if(write_state==PW_IDLE || write_activity) write_watchdog<=0;
            else if(!write_timed_out) write_watchdog<=write_watchdog+1'b1;
            if(write_timed_out && error_code==0) error_code<=ERR_TIMEOUT;
            case(write_state)
            PW_IDLE: if(result_ready[consume_bank]) begin
                if(error_code!=0 || timed_out || write_timed_out) begin
                    result_ready[consume_bank]<=0;consume_bank<=!consume_bank;
                end else begin write_index<=0;write_state<=PW_ADDR;end
            end
            PW_ADDR: if(awready) write_state<=PW_LOAD;
            PW_LOAD: write_state<=PW_DATA;
            PW_DATA: if(wready) begin
                if(write_last) write_state<=PW_RESP;
                else write_index<=write_index+1'b1;
            end
            PW_RESP: if(bvalid) begin
                if(bad_write && error_code==0 && !timed_out && !write_timed_out)
                    error_code<=ERR_WRITE;
                result_ready[consume_bank]<=0;consume_bank<=!consume_bank;
                write_state<=PW_IDLE;
            end
            default: write_state<=PW_IDLE;
            endcase
        end
    end
end

// synthesis translate_off
initial begin
    if (FRAME_WIDTH < 4 || FRAME_HEIGHT < 1 || FRAME_WIDTH % 4 != 0 ||
        FRAME_STRIDE != 64'd4 * FRAME_WIDTH || FRAME_BYTES > 64'h100000000 ||
        MAX_BURST_BEATS < 1 || MAX_BURST_BEATS > 32 || WATCHDOG_BITS < 4)
        $fatal(1, "Unsupported alpha BLIT parameters");
end
// synthesis translate_on
endmodule
