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
    parameter PIXEL_X_ENABLE = 0
)(
    input wire clk, rst_n, enabled, start,
    input wire [31:0] src_addr, src_stride, back_base,
    input wire [7:0] global_alpha,
    input wire [31:0] dst_x, dst_y, width, height,
    output wire busy,
    output reg done,
    output reg [31:0] error_code, command_count,

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
    DRAIN_R = 19, MIX_STREAM = 20, PAD_SOURCE = 21, CACHE_LOAD = 22, CACHE_DATA = 23;
localparam [63:0] FRAME_BYTES = 64'd1 * FRAME_STRIDE * FRAME_HEIGHT;

reg [4:0] state;
reg [127:0] previous_source;
// v13: 128 direct-mapped 64-byte source lines (8 KiB), immutable sealed atlas.
// Each 16-byte beat has a validity bit: narrow 8/12-pixel tiles fill on their
// own, without requiring a previous 16-pixel draw of the same source line.
// Hash row bits as well as column bits to avoid stride-2560 conflict chains.
reg [127:0] line_cache [0:511];
reg [25:0] line_tags [0:127];
reg [511:0] line_valid;
reg [127:0] line_data;
wire [6:0] line_slot = src_cursor[12:6] ^ src_cursor[19:13];
wire [8:0] planned_reads = segment_beats - ((pixel_shift != 0 && final_segment) ? 1 : 0);
wire line_eligible = PIXEL_X_ENABLE && SPRITE_CACHE_ENABLE && source_stride == 2560 &&
    src_cursor >= 32'h01384000 && src_cursor < 32'h014b0000 &&
    planned_reads != 0 && planned_reads <= 4-src_cursor[5:4];
wire [3:0] line_valid_beats = line_valid[{line_slot,2'b00} +: 4];
wire line_tag_match = (|line_valid_beats) && line_tags[line_slot] == src_cursor[31:6];
wire [3:0] requested_beats = planned_reads == 4 ? 4'b1111 :
    planned_reads == 3 ? 4'b0111 : planned_reads == 2 ? 4'b0011 : 4'b0001;
wire [3:0] line_request_mask = requested_beats << src_cursor[5:4];
wire line_hit = line_eligible && line_tag_match &&
    (line_valid_beats & line_request_mask) == line_request_mask;
reg line_fill;
reg [3:0] line_fill_mask;
wire [127:0] source_payload = state == CACHE_DATA ? line_data : rdata;
wire source_received = state == CACHE_DATA || (state == RD_DATA && rvalid);

wire [1:0] pixel_shift = PIXEL_X_ENABLE ? x[1:0] : 2'b0;
wire [31:0] row_beats = (copy_width >> 2) + (pixel_shift != 0);
wire final_segment = beats_left == segment_beats;
wire [8:0] source_beats = burst_beats - ((pixel_shift != 0 && beats_left == burst_beats) ? 1'b1 : 1'b0);
wire source_last = beat_index == source_beats - 1'b1;
wire [255:0] shifted_pair = {source_payload,previous_source} >> ((4-pixel_shift)*32);

reg [31:0] saved_back_base;
reg [7:0] saved_alpha;
reg [127:0] background_mem [0:MAX_BURST_BEATS-1];
reg [127:0] source_read_data,background_read_data;
wire [127:0] mix_result;
wire mix_valid;
reg mix_input_valid;
reg [8:0] mix_issue_index, mix_return_index;
reg [127:0] cache_read_data;
wire [127:0] pixel_foreground = SPRITE_CACHE_ENABLE && cache_use ? cache_read_data : source_read_data;
alpha_pixel_pipeline pixels (
    .clk(clk),.rst_n(rst_n),.in_valid(STREAM_ENABLE ? mix_input_valid : state==MIX_START),
    .foreground(pixel_foreground),.background(background_read_data),.global_alpha(saved_alpha),
    .out_valid(mix_valid),.result(mix_result));
reg [31:0] source, source_stride, x, y, copy_width, copy_height;
reg [31:0] src_row, dst_row, src_cursor, dst_cursor;
reg [31:0] rows_left, beats_left;
reg [8:0] burst_beats, beat_index;
reg [WATCHDOG_BITS-1:0] watchdog;
reg [127:0] beat_mem [0:MAX_BURST_BEATS-1];
reg segment_read_error;
reg invalid_geometry_latched;
reg [31:0] rows_before_last, destination_start_latched;
reg [63:0] source_span, source_end;

// 64 x 128 bits, no data reset: infer block RAM, reset only validity tags.
// A row becomes valid only after an entire successful four-beat source read.
// Clipped draws can hit valid rows, but cannot populate partial rows.
reg [127:0] sprite_cache [0:63];
reg [15:0] sprite_cache_valid;
reg [3:0] cache_row;
reg [1:0] cache_offset;
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
wire cache_eligible = SPRITE_CACHE_ENABLE && pixel_shift == 0 && cache_address_match &&
    source_stride == 32'd2560 && segment_beats <= (32'd4 - {30'b0,src_cursor[5:4]});
wire [8:0] mix_read_index = STREAM_ENABLE ? mix_issue_index : beat_index;
wire [8:0] source_read_index = state == WR_DATA ? beat_index + 1'b1 :
    state == MIX_LOAD || state == MIX_STREAM ? mix_read_index : beat_index;
wire [5:0] cache_read_index = {cache_row,2'b00} + {4'b0,cache_offset} + mix_read_index[5:0];

// Keep full precision for rejection of invalid, overflowing addresses. Register
// subtraction, multiplication, addition and range checking on separate cycles:
// the original combined expression reached 51 logic levels at 100 MHz.
wire [63:0] row_bytes = {32'b0, copy_width} << 2;
wire [63:0] destination_start = {32'b0, y} * FRAME_STRIDE +
    ({32'b0, (x & 32'hfffffffc)} << 2);
wire invalid_geometry = copy_width == 0 || copy_height == 0 ||
    {32'b0, x} + {32'b0, copy_width} > FRAME_WIDTH ||
    {32'b0, y} + {32'b0, copy_height} > FRAME_HEIGHT ||
    saved_back_base[11:0] != 0 ||
    {32'b0,saved_back_base}+FRAME_BYTES > 64'h100000000 ||
    source[3:0] != 0 || source_stride[3:0] != 0 ||
    (!PIXEL_X_ENABLE && x[1:0] != 0) || copy_width[1:0] != 0 ||
    {32'b0, source_stride} < row_bytes;

wire [31:0] src_page_beats = (32'd4096 - {20'b0, src_cursor[11:0]}) >> 4;
wire [31:0] dst_page_beats = (32'd4096 - {20'b0, dst_cursor[11:0]}) >> 4;
wire [31:0] capped_beats = beats_left < MAX_BURST_BEATS ? beats_left : MAX_BURST_BEATS;
wire [31:0] src_capped = capped_beats < src_page_beats ? capped_beats : src_page_beats;
wire [31:0] segment_beats = src_capped < dst_page_beats ? src_capped : dst_page_beats;
wire [31:0] segment_bytes = {19'b0, burst_beats, 4'b0};
wire last_beat = beat_index == burst_beats - 1'b1;
wire bad_read = rresp != 2'b00 || rid != 4'b0000;
wire bad_write = bresp != 2'b00 || bid != 4'b0000;
wire activity = (arvalid && arready) || (rvalid && rready) ||
    (awvalid && awready) || (wvalid && wready) || (bvalid && bready) ||
    state == MIX_LOAD || (state == MIX_STREAM &&
        (mix_issue_index < burst_beats || mix_valid));
wire timed_out = &watchdog;

assign busy = state != IDLE;
assign araddr = state==BG_ADDR ? saved_back_base+dst_cursor : src_cursor;
assign arlen = (state == RD_ADDR ? source_beats : burst_beats) - 1'b1;
assign arvalid = state == RD_ADDR || state == BG_ADDR;
assign rready = state == RD_DATA || state == BG_DATA || state == DRAIN_R;
assign awaddr = dst_cursor;
assign awlen = burst_beats - 1'b1;
assign awvalid = state == WR_ADDR;
assign wstrb = 16'hffff;
assign wdata = source_read_data;
assign wvalid = state == WR_DATA;
assign wlast = wvalid && last_beat;
assign bready = state == WR_RESP;

wire source_store = source_received;
wire mixed_store = mix_valid && (state == MIX_WAIT || (STREAM_ENABLE && state == MIX_STREAM));
wire [8:0] store_index = state == PAD_SOURCE ? burst_beats - 1'b1 : STREAM_ENABLE && !source_store ? mix_return_index : beat_index;
wire [127:0] store_data = state == PAD_SOURCE ? previous_source >> ((4-pixel_shift)*32) : source_store ? (pixel_shift != 0 ? shifted_pair[127:0] : source_payload) : mix_result;

// No reset on the storage array. Only entries received by a complete read
// burst can be used. WR_LOAD below provides a synchronous memory read cycle.
always @(posedge clk) begin
    // One synchronous BRAM prefetch, then one cached source beat each clock.
    if (state == CACHE_LOAD || (state == CACHE_DATA && !source_last))
        line_data <= line_cache[{line_slot,2'b00} + src_cursor[5:4] + beat_index + (state == CACHE_DATA)];
    if (state == RD_DATA && rvalid && line_fill)
        line_cache[{line_slot,2'b00} + src_cursor[5:4] + beat_index] <= rdata;
    if (rst_n && (source_store || mixed_store || state == PAD_SOURCE))
        beat_mem[store_index] <= store_data;
    if (rst_n && state == BG_DATA && rvalid && rready)
        background_mem[beat_index] <= rdata;
    if (rst_n && SPRITE_CACHE_ENABLE && cache_fill && state == RD_DATA && rvalid && rready)
        sprite_cache[{cache_row,beat_index[1:0]}] <= rdata;
    // Dedicated synchronous read register has no reset or bypass mux, so the
    // synthesis tool can absorb it into BRAM instead of making 8192 flip-flops.
    if (SPRITE_CACHE_ENABLE && (state == MIX_LOAD ||
        (state == MIX_STREAM && mix_issue_index < burst_beats)))
        cache_read_data <= sprite_cache[cache_read_index];
    if ((state == WR_DATA && wready && !last_beat) || state == WR_LOAD || state == MIX_LOAD ||
        (STREAM_ENABLE && state == MIX_STREAM && mix_issue_index < burst_beats))
        source_read_data <= beat_mem[source_read_index];
    if (state == MIX_LOAD ||
        (STREAM_ENABLE && state == MIX_STREAM && mix_issue_index < burst_beats))
        background_read_data <= background_mem[mix_read_index];
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= IDLE; previous_source <= 0; line_valid <= 0; line_fill <= 0; line_fill_mask <= 0;
        done <= 0; error_code <= 0; command_count <= 0;
        saved_back_base<=0;saved_alpha<=0;
        source <= 0; source_stride <= 0; x <= 0; y <= 0;
        copy_width <= 0; copy_height <= 0;
        src_row <= 0; dst_row <= 0; src_cursor <= 0; dst_cursor <= 0;
        rows_left <= 0; beats_left <= 0;
        burst_beats <= 0; beat_index <= 0; watchdog <= 0;
        segment_read_error <= 0;
        invalid_geometry_latched <= 0; rows_before_last <= 0;
        destination_start_latched <= 0; source_span <= 0; source_end <= 0;
        mix_input_valid<=0;mix_issue_index<=0;mix_return_index<=0;
        sprite_cache_valid<=0;cache_row<=0;cache_offset<=0;cache_use<=0;cache_fill<=0;
    end else begin
        mix_input_valid <= 0;
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
            saved_back_base<=back_base;saved_alpha<=global_alpha;
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
            if (invalid_geometry_latched || source_end > 64'h100000000) begin
                error_code <= ERR_PARAM; done <= 1; state <= IDLE;
            end else begin
                src_row <= source; src_cursor <= source;
                dst_row <= destination_start_latched; dst_cursor <= destination_start_latched;
                rows_left <= copy_height; beats_left <= row_beats; previous_source <= 0;
                state <= PREP;
            end
        end
        PREP: begin
            if (error_code != 0 || timed_out) begin
                done <= 1; state <= IDLE;
            end else begin
                burst_beats <= segment_beats[8:0]; beat_index <= 0;
                segment_read_error <= 0;
                line_fill <= line_eligible && !line_hit;
                if (line_eligible && !line_hit) begin
                    // Commit valid beats only after the complete successful R
                    // burst. A failed fill cannot expose old or partial data.
                    line_fill_mask <= (line_tag_match ? line_valid_beats : 4'b0) | line_request_mask;
                    line_valid[{line_slot,2'b00} +: 4] <= 0;
                end
                cache_row <= cache_address_row;
                cache_offset <= src_cursor[5:4];
                cache_use <= cache_eligible && sprite_cache_valid[cache_address_row];
                cache_fill <= cache_eligible && !sprite_cache_valid[cache_address_row] &&
                    src_cursor[5:4] == 0 && segment_beats == 4;
                state <= pixel_shift != 0 && final_segment && segment_beats == 1 ? PAD_SOURCE :
                    cache_eligible && sprite_cache_valid[cache_address_row] ? BG_ADDR :
                    line_hit ? CACHE_LOAD : RD_ADDR;
            end
        end
        RD_ADDR: if (arready) begin
            beat_index <= 0; state <= RD_DATA;
        end
        CACHE_LOAD: state <= CACHE_DATA;
        CACHE_DATA, RD_DATA: if (source_received) begin
            previous_source <= source_payload;
            if (state == RD_DATA && rlast != source_last) begin
                // An invalid length/termination cannot safely be repaired by
                // this master. Keep BUSY, block commands, require platform reset.
                error_code <= ERR_PROTOCOL;
                if(rlast) begin done<=1;state<=IDLE;end
                else state<=DRAIN_R;
            end else begin
                if (state == RD_DATA && bad_read && error_code == 0 && !timed_out)
                    error_code <= ERR_READ;
                if (state == RD_DATA && bad_read)
                    segment_read_error <= 1;
                if (source_last) begin
                    if ((state == RD_DATA && bad_read) || segment_read_error || error_code != 0 || timed_out) begin
                        done <= 1; state <= IDLE;
                    end else begin
                        if (state == RD_DATA && line_fill) begin
                            line_valid[{line_slot,2'b00} +: 4] <= line_fill_mask;
                            line_tags[line_slot] <= src_cursor[31:6];
                        end
                        if (SPRITE_CACHE_ENABLE && cache_fill && state == RD_DATA)
                            sprite_cache_valid[cache_row] <= 1;
                        beat_index <= 0; state <= pixel_shift != 0 && beats_left == burst_beats ? PAD_SOURCE : BG_ADDR;
                    end
                end else begin
                    beat_index <= beat_index + 1'b1;
                    // CACHE_DATA pipelines the next BRAM read alongside this
                    // beat's store, so no per-beat CACHE_LOAD bubble is needed.
                end
            end
        end
        PAD_SOURCE: begin beat_index <= 0; state <= BG_ADDR; end
        BG_ADDR: if(arready) begin
            beat_index<=0;state<=BG_DATA;
        end
        BG_DATA: if(rvalid) begin
            if(rlast!=last_beat) begin
                error_code<=ERR_PROTOCOL;
                if(rlast) begin done<=1;state<=IDLE;end
                else state<=DRAIN_R;
            end else begin
                if(bad_read && error_code==0 && !timed_out) error_code<=ERR_READ;
                if(bad_read) segment_read_error<=1;
                if(last_beat) begin
                    if(bad_read || segment_read_error || error_code!=0 || timed_out) begin
                        done<=1;state<=IDLE;
                    end else begin
                        beat_index<=0;mix_issue_index<=0;mix_return_index<=0;state<=MIX_LOAD;
                    end
                end else beat_index<=beat_index+1'b1;
            end
        end
        MIX_LOAD: begin
            // Synchronous reads from the two segment memories.
            if (STREAM_ENABLE) begin
                mix_input_valid<=1;mix_issue_index<=1;state<=MIX_STREAM;
            end else state<=MIX_START;
        end
        MIX_START: state<=MIX_WAIT;
        MIX_WAIT: if(mix_valid) begin
            if(error_code!=0 || timed_out) begin done<=1;state<=IDLE;end
            else if(last_beat) begin beat_index<=0;state<=WR_ADDR;end
            else begin beat_index<=beat_index+1'b1;state<=MIX_LOAD;end
        end
        MIX_STREAM: begin
            // Registered RAM reads feed the existing four-pixel pipeline every
            // clock. Results return in order into a separate write cursor.
            if (mix_issue_index < burst_beats) begin
                mix_input_valid<=1;mix_issue_index<=mix_issue_index+1'b1;
            end
            if (mix_valid) begin
                if (mix_return_index == burst_beats-1'b1) begin
                    if(error_code!=0 || timed_out) begin done<=1;state<=IDLE;end
                    else begin beat_index<=0;state<=WR_ADDR;end
                end else mix_return_index<=mix_return_index+1'b1;
            end
        end
        DRAIN_R: if(rvalid && rlast) begin
            // Keep the malformed burst outstanding until its actual RLAST.
            // Drain before releasing Back to protect the shared display reader.
            done<=1;state<=IDLE;
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
                beat_index <= beat_index + 1'b1; state <= WR_DATA;
            end
        end
        WR_RESP: if (bvalid) begin
            if (bad_write && error_code == 0 && !timed_out)
                error_code <= ERR_WRITE;
            if (bad_write || error_code != 0 || timed_out) begin
                done <= 1; state <= IDLE;
            end else
                state <= ADVANCE;
        end
        ADVANCE: begin
            if (beats_left == burst_beats) begin
                if (rows_left == 1) begin
                    done <= 1; state <= IDLE;
                end else begin
                    rows_left <= rows_left - 1'b1;
                    src_row <= src_row + source_stride;
                    dst_row <= dst_row + FRAME_STRIDE;
                    src_cursor <= src_row + source_stride;
                    dst_cursor <= dst_row + FRAME_STRIDE;
                    beats_left <= row_beats; previous_source <= 0; state <= PREP;
                end
            end else begin
                src_cursor <= src_cursor + segment_bytes;
                dst_cursor <= dst_cursor + segment_bytes;
                beats_left <= beats_left - burst_beats; state <= PREP;
            end
        end
        FAULT: begin state<=FAULT;end
        default: begin error_code <= ERR_PROTOCOL; state <= FAULT; end
        endcase
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
