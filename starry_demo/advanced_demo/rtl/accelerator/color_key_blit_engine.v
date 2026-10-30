`timescale 1ns/1ps
// Independent color-key BLIT prototype. Not wired to the v4 APB/top project.
// Reuse the existing DMA and suppress all four byte strobes for a key pixel.
// XRGB8888: compare RGB[23:0]; X[31:24] is ignored, not an alpha channel.
module color_key_blit_engine #(
    parameter FRAME_WIDTH = 1920,
    parameter FRAME_HEIGHT = 1080,
    parameter FRAME_STRIDE = 7680,
    parameter MAX_BURST_BEATS = 32,
    parameter WATCHDOG_BITS = 27
)(
    input wire clk, rst_n, enabled, start,
    input wire color_key_enable,
    input wire [23:0] color_key_rgb,
    input wire [31:0] src_addr, src_stride,
    input wire [31:0] dst_x, dst_y, width, height,
    output wire busy, done,
    output wire [31:0] error_code, command_count,

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
reg key_enable_latched;
reg [23:0] key_rgb_latched;
wire [15:0] copy_wstrb;

// Exactly the existing engine's acceptance condition, including sticky FAULT
// (busy=1). Writes to the live key inputs cannot change an in-flight W beat.
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        key_enable_latched <= 0;
        key_rgb_latched <= 0;
    end else if (start && enabled && !busy) begin
        key_enable_latched <= color_key_enable;
        key_rgb_latched <= color_key_rgb;
    end
end

genvar pixel;
generate for (pixel = 0; pixel < 4; pixel = pixel + 1) begin : pixel_strobes
    assign wstrb[pixel*4+:4] = key_enable_latched &&
        wdata[pixel*32+:24] == key_rgb_latched ? 4'b0000 : copy_wstrb[pixel*4+:4];
end endgenerate

// Even an all-transparent beat/burst keeps its AWLEN, WLAST and B handshake.
// Never gate WVALID on the mask: that would strand an accepted write burst.
// The destination is the existing Back contents, with no destination read.
blit_engine #(
    .FRAME_WIDTH(FRAME_WIDTH), .FRAME_HEIGHT(FRAME_HEIGHT),
    .FRAME_STRIDE(FRAME_STRIDE), .MAX_BURST_BEATS(MAX_BURST_BEATS),
    .WATCHDOG_BITS(WATCHDOG_BITS)
) copy_engine (
    .clk(clk), .rst_n(rst_n), .enabled(enabled), .start(start),
    .src_addr(src_addr), .src_stride(src_stride),
    .dst_x(dst_x), .dst_y(dst_y), .width(width), .height(height),
    .busy(busy), .done(done), .error_code(error_code), .command_count(command_count),
    .araddr(araddr), .arlen(arlen), .arvalid(arvalid), .arready(arready),
    .rdata(rdata), .rid(rid), .rresp(rresp), .rlast(rlast),
    .rvalid(rvalid), .rready(rready),
    .awaddr(awaddr), .awlen(awlen), .awvalid(awvalid), .awready(awready),
    .wdata(wdata), .wstrb(copy_wstrb), .wlast(wlast),
    .wvalid(wvalid), .wready(wready),
    .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready)
);
endmodule
