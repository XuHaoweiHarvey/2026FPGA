`timescale 1ns/1ps
// Front remains the legacy source. M2 also permits three sealed full images
// for ordinary BLIT only; no arbitrary DDR source interval is exposed.
// Sample the SAME parameters/roles as graphics_engine and buffer_manager on
// command_accept. graphics_engine reads this registered result one cycle later.
// This module never gates acceptance: invalid commands still count and end 0x21.
module blit_source_guard #(
    parameter FRAME_WIDTH = 1920,
    parameter FRAME_HEIGHT = 1080,
    parameter FRAME_STRIDE = 7680
)(
    input wire clk, rst_n, command_accept,
    input wire [31:0] front_base, back_base,
    input wire [31:0] src_addr, src_stride, width, height, op,
    input wire asset_ready,
    output reg src_range_valid
);
localparam [63:0] FRAME_BYTES = 64'd1 * FRAME_STRIDE * FRAME_HEIGHT;
wire [63:0] front_end = {32'b0, front_base} + FRAME_BYTES;
wire [31:0] source_offset = src_addr - front_base;
// Divisors are elaboration-time constants, not a programmable divider.
// The production stride is 7680 (not a power of two).
wire [31:0] source_row = source_offset / FRAME_STRIDE;
wire [31:0] source_x = (source_offset % FRAME_STRIDE) >> 2;
// Extend before adding, so huge width/height cannot wrap into a valid rectangle.
wire [32:0] source_right = {1'b0, source_x} + {1'b0, width};
wire [32:0] source_bottom = {1'b0, source_row} + {1'b0, height};
wire front_ok = front_base != back_base && front_base[1:0] == 0 &&
    front_end <= 64'h100000000 && src_addr >= front_base &&
    {32'b0, source_offset} < FRAME_BYTES && src_addr[1:0] == 0 &&
    src_stride == FRAME_STRIDE && width != 0 && height != 0 &&
    source_right <= FRAME_WIDTH && source_bottom <= FRAME_HEIGHT;
wire asset_base_ok = src_addr==32'h01000000 || src_addr==32'h0112c000 ||
                     src_addr==32'h01258000;
wire asset_ok = asset_base_ok && asset_ready && op==32'd1 &&
    src_stride==32'd2560 && width==32'd640 && height==32'd480;
wire range_ok = front_ok || asset_ok;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) src_range_valid <= 0;
    else if (command_accept) src_range_valid <= range_ok;
end

// Only the source WINDOW policy lives here. The B executor separately checks
// its 16-byte source alignment and four-pixel destination/width restrictions.
// FILL and illegal opcodes ignore this result in graphics_engine.
// synthesis translate_off
initial if (FRAME_WIDTH <= 0 || FRAME_HEIGHT <= 0 ||
            FRAME_STRIDE != 64'd4 * FRAME_WIDTH || FRAME_BYTES > 64'h100000000)
    $fatal(1, "Source guard requires a packed XRGB8888 frame within 32-bit space");
// synthesis translate_on
endmodule
