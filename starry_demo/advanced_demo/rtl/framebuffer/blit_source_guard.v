`timescale 1ns/1ps
// Front remains the legacy source. M2 also permits three sealed full images
// for ordinary BLIT only; no arbitrary DDR source interval is exposed.
// Sample the SAME parameters/roles as graphics_engine and buffer_manager on
// command_accept. graphics_engine reads this registered result one cycle later.
// This module never gates acceptance: invalid commands still count and end 0x21.
module blit_source_guard #(
    parameter FRAME_WIDTH = 1920,
    parameter FRAME_HEIGHT = 1080,
    parameter FRAME_STRIDE = 7680,
    parameter ALPHA_ENABLE = 0
)(
    input wire clk, rst_n, command_accept,
    input wire [31:0] front_base, back_base,
    input wire [31:0] src_addr, src_stride, width, height, op,
    input wire asset_ready,
    input wire sprite_ready,
    output reg src_range_valid
);
localparam [63:0] FRAME_BYTES = 64'd1 * FRAME_STRIDE * FRAME_HEIGHT;
localparam SOURCE_OFFSET_BITS = FRAME_BYTES > 1 ? $clog2(FRAME_BYTES) : 1;
localparam [SOURCE_OFFSET_BITS-1:0] SOURCE_STRIDE_N = FRAME_STRIDE;
wire [63:0] front_end = {32'b0, front_base} + FRAME_BYTES;
wire [31:0] source_offset = src_addr - front_base;
wire [SOURCE_OFFSET_BITS-1:0] source_offset_narrow = source_offset[SOURCE_OFFSET_BITS-1:0];
// Divisors are elaboration-time constants, not a programmable divider.
// Narrow the dividend to the largest legal frame offset before constant
// division. The full-width range test below still rejects wrapped/oversized
// addresses, while the smaller divider keeps the command-accept path shallow.
wire [SOURCE_OFFSET_BITS-1:0] source_row = source_offset_narrow / SOURCE_STRIDE_N;
wire [SOURCE_OFFSET_BITS-1:0] source_x = (source_offset_narrow % SOURCE_STRIDE_N) >> 2;
// Extend before adding, so huge width/height cannot wrap into a valid rectangle.
wire [32:0] source_right = {1'b0, source_x} + {1'b0, width};
wire [32:0] source_bottom = {1'b0, source_row} + {1'b0, height};
wire sprite_address = src_addr >= 32'h01384000 && src_addr < 32'h014b0000;
localparam SPRITE_OFFSET_BITS = $clog2(64'd640 * 480 * 4);
localparam [SPRITE_OFFSET_BITS-1:0] SPRITE_STRIDE_N = 32'd2560;
wire [31:0] sprite_offset=src_addr-32'h01384000;
wire [SPRITE_OFFSET_BITS-1:0] sprite_offset_narrow=sprite_offset[SPRITE_OFFSET_BITS-1:0];
wire [SPRITE_OFFSET_BITS-1:0] sprite_row=sprite_offset_narrow/SPRITE_STRIDE_N;
wire [SPRITE_OFFSET_BITS-1:0] sprite_x=(sprite_offset_narrow%SPRITE_STRIDE_N)>>2;
wire [32:0] sprite_right={1'b0,sprite_x}+{1'b0,width};
wire [32:0] sprite_bottom={1'b0,sprite_row}+{1'b0,height};
wire front_ok = front_base != back_base && front_base[1:0] == 0 &&
    front_end <= 64'h100000000 && src_addr >= front_base &&
    {32'b0, source_offset} < FRAME_BYTES && src_addr[1:0] == 0 &&
    src_stride == FRAME_STRIDE && width != 0 && height != 0 &&
    source_right <= FRAME_WIDTH && source_bottom <= FRAME_HEIGHT;
wire asset_base_ok = src_addr==32'h01000000 || src_addr==32'h0112c000 ||
                     src_addr==32'h01258000;
wire asset_ok = asset_base_ok && asset_ready && op==32'd1 &&
    src_stride==32'd2560 && width==32'd640 && height==32'd480;
wire sprite_ok=ALPHA_ENABLE && sprite_address && (op==32'd2 || op==32'd3) &&
    sprite_ready && src_addr[3:0]==0 && src_stride==32'd2560 &&
    width!=0 && height!=0 && sprite_right<=33'd640 && sprite_bottom<=33'd480;
wire [31:0] background_offset=src_addr-32'h02000000;
localparam BACKGROUND_OFFSET_BITS = $clog2(32'h027e9000 - 32'h02000000);
localparam [BACKGROUND_OFFSET_BITS-1:0] BACKGROUND_STRIDE_N = 32'd7680;
wire [BACKGROUND_OFFSET_BITS-1:0] background_offset_narrow=background_offset[BACKGROUND_OFFSET_BITS-1:0];
wire [BACKGROUND_OFFSET_BITS-1:0] background_row=background_offset_narrow/BACKGROUND_STRIDE_N;
wire [BACKGROUND_OFFSET_BITS-1:0] background_x=(background_offset_narrow%BACKGROUND_STRIDE_N)>>2;
wire [32:0] background_right={1'b0,background_x}+{1'b0,width};
wire [32:0] background_bottom={1'b0,background_row}+{1'b0,height};
wire background_ok=ALPHA_ENABLE && asset_ready && op==32'd1 &&
    src_addr>=32'h02000000 && src_addr<32'h027e9000 && src_addr[3:0]==0 &&
    src_stride==32'd7680 && width!=0 && height!=0 &&
    background_right<=33'd1920 && background_bottom<=33'd1080;
wire range_ok = front_ok || asset_ok || sprite_ok || background_ok;

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
