`timescale 1ns/1ps
// Aligned XRGB8888 rectangle copy, one burst at a time, one clock domain.
// ARADDR is absolute; AWADDR is relative to the command's latched Back.
// A wrapper must add Back exactly once and preserve its 4KiB alignment.
module blit_engine #(
    parameter FRAME_WIDTH = 1920,
    parameter FRAME_HEIGHT = 1080,
    parameter FRAME_STRIDE = 7680,
    parameter MAX_BURST_BEATS = 32,
    parameter WATCHDOG_BITS = 27
)(
    input wire clk, rst_n, enabled, start,
    input wire [31:0] src_addr, src_stride,
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
    output reg [127:0] wdata,
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
localparam [3:0] IDLE = 0, CHECK = 1, PREP = 2, RD_ADDR = 3,
    RD_DATA = 4, WR_ADDR = 5, WR_LOAD = 6, WR_DATA = 7,
    WR_RESP = 8, ADVANCE = 9, FAULT = 10,
    CHECK_SPAN = 11, CHECK_END = 12, CHECK_RANGE = 13;
localparam [63:0] FRAME_BYTES = 64'd1 * FRAME_STRIDE * FRAME_HEIGHT;

reg [3:0] state;
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

// Keep full precision for rejection of invalid, overflowing addresses. Register
// subtraction, multiplication, addition and range checking on separate cycles:
// the original combined expression reached 51 logic levels at 100 MHz.
wire [63:0] row_bytes = {32'b0, copy_width} << 2;
wire [63:0] destination_start = {32'b0, y} * FRAME_STRIDE +
    ({32'b0, x} << 2);
wire invalid_geometry = copy_width == 0 || copy_height == 0 ||
    {32'b0, x} + {32'b0, copy_width} > FRAME_WIDTH ||
    {32'b0, y} + {32'b0, copy_height} > FRAME_HEIGHT ||
    source[3:0] != 0 || source_stride[3:0] != 0 ||
    x[1:0] != 0 || copy_width[1:0] != 0 ||
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
    (awvalid && awready) || (wvalid && wready) || (bvalid && bready);
wire timed_out = &watchdog;

assign busy = state != IDLE;
assign araddr = src_cursor;
assign arlen = burst_beats - 1'b1;
assign arvalid = state == RD_ADDR;
assign rready = state == RD_DATA;
assign awaddr = dst_cursor;
assign awlen = burst_beats - 1'b1;
assign awvalid = state == WR_ADDR;
assign wstrb = 16'hffff;
assign wvalid = state == WR_DATA;
assign wlast = wvalid && last_beat;
assign bready = state == WR_RESP;

// No reset on the storage array. Only entries received by a complete read
// burst can be used. WR_LOAD below provides a synchronous memory read cycle.
always @(posedge clk) begin
    if (rst_n && state == RD_DATA && rvalid && rready)
        beat_mem[beat_index] <= rdata;
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= IDLE;
        done <= 0; error_code <= 0; command_count <= 0;
        source <= 0; source_stride <= 0; x <= 0; y <= 0;
        copy_width <= 0; copy_height <= 0;
        src_row <= 0; dst_row <= 0; src_cursor <= 0; dst_cursor <= 0;
        rows_left <= 0; beats_left <= 0;
        burst_beats <= 0; beat_index <= 0; watchdog <= 0; wdata <= 0;
        segment_read_error <= 0;
        invalid_geometry_latched <= 0; rows_before_last <= 0;
        destination_start_latched <= 0; source_span <= 0; source_end <= 0;
    end else begin
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
                rows_left <= copy_height; beats_left <= copy_width >> 2;
                state <= PREP;
            end
        end
        PREP: begin
            if (error_code != 0 || timed_out) begin
                done <= 1; state <= IDLE;
            end else begin
                burst_beats <= segment_beats[8:0]; beat_index <= 0;
                segment_read_error <= 0;
                state <= RD_ADDR;
            end
        end
        RD_ADDR: if (arready) begin
            beat_index <= 0; state <= RD_DATA;
        end
        RD_DATA: if (rvalid) begin
            if (rlast != last_beat) begin
                // An invalid length/termination cannot safely be repaired by
                // this master. Keep BUSY, block commands, require platform reset.
                error_code <= ERR_PROTOCOL; state <= FAULT;
            end else begin
                if (bad_read && error_code == 0 && !timed_out)
                    error_code <= ERR_READ;
                if (bad_read)
                    segment_read_error <= 1;
                if (last_beat) begin
                    if (bad_read || segment_read_error || error_code != 0 || timed_out) begin
                        done <= 1; state <= IDLE;
                    end else begin
                        beat_index <= 0; state <= WR_ADDR;
                    end
                end else
                    beat_index <= beat_index + 1'b1;
            end
        end
        WR_ADDR: if (awready) begin
            beat_index <= 0; state <= WR_LOAD;
        end
        WR_LOAD: begin
            wdata <= beat_mem[beat_index]; state <= WR_DATA;
        end
        WR_DATA: if (wready) begin
            if (last_beat)
                state <= WR_RESP;
            else begin
                beat_index <= beat_index + 1'b1; state <= WR_LOAD;
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
                    beats_left <= copy_width >> 2; state <= PREP;
                end
            end else begin
                src_cursor <= src_cursor + segment_bytes;
                dst_cursor <= dst_cursor + segment_bytes;
                beats_left <= beats_left - burst_beats; state <= PREP;
            end
        end
        FAULT: begin
            // No automatic recovery from malformed RLAST. A CPU/debug reset
            // must not be connected here as a transaction-cancellation method.
            state <= FAULT;
        end
        default: begin error_code <= ERR_PROTOCOL; state <= FAULT; end
        endcase
    end
end

// synthesis translate_off
initial begin
    if (FRAME_WIDTH < 4 || FRAME_HEIGHT < 1 || FRAME_WIDTH % 4 != 0 ||
        FRAME_STRIDE != 64'd4 * FRAME_WIDTH || FRAME_BYTES > 64'h100000000 ||
        MAX_BURST_BEATS < 1 || MAX_BURST_BEATS > 32 || WATCHDOG_BITS < 4)
        $fatal(1, "Unsupported BLIT parameters");
end
// synthesis translate_on
endmodule
