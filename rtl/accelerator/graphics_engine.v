`timescale 1ns/1ps
// B-side command dispatcher; enabled in the formal double-buffered platform.
// START is the manager's final command_accept; ACCEPT reports local acceptance.
// C registers src_range_valid on that edge; CHECK_SOURCE samples it next cycle.
// Source addresses are absolute bytes; destination AW is relative to Back.
module graphics_engine #(
    parameter FRAME_WIDTH = 1920, FRAME_HEIGHT = 1080, FRAME_STRIDE = 7680,
    parameter MAX_BURST_BEATS = 32, WATCHDOG_BITS = 27,
    parameter [31:0] OP_FILL = 32'd0, OP_BLIT = 32'd1,
    parameter [31:0] ERR_OPCODE = 32'h26,
    // B-local opt-in only. Formal v4 leaves this disabled; OP_COLOR_KEY is
    // not an assigned APB opcode. The key uses the accepted color[23:0].
    parameter COLOR_KEY_ENABLE = 0,
    parameter [31:0] OP_COLOR_KEY = 32'd2
)(
    input wire clk, rst_n, enabled, start,
    input wire [31:0] op, x, y, width, height, color,
    input wire [31:0] src_addr, src_stride,
    input wire src_range_valid,
    output wire accept,
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
localparam IDLE = 0, CHECK_SOURCE = 1, LAUNCH = 2, RUN = 3;
localparam [31:0] ERR_BLIT_PARAM = 32'h21;
reg [1:0] state;
reg selected_blit, selected_color_key, source_range_checked;
reg [31:0] saved_x, saved_y, saved_width, saved_height, saved_color;
reg [31:0] source, source_stride;
wire fill_busy, fill_done, blit_busy, blit_done;
wire [31:0] fill_error, blit_error;
wire [31:0] fill_awaddr, blit_awaddr;
wire [7:0] fill_awlen, blit_awlen;
wire fill_awvalid, blit_awvalid, fill_wvalid, blit_wvalid;
wire fill_wlast, blit_wlast, fill_bready, blit_bready;
wire [127:0] fill_wdata, blit_wdata;
wire [15:0] fill_wstrb, blit_wstrb;
wire [15:0] copy_wstrb;
wire [31:0] blit_araddr;
wire [7:0] blit_arlen;
wire blit_arvalid, blit_rready;
wire fill_active = state == RUN && !selected_blit;
wire blit_active = state == RUN && selected_blit;
wire selected_done = selected_blit ? blit_done : fill_done;
wire selected_busy = selected_blit ? blit_busy : fill_busy;
wire [31:0] selected_error = selected_blit ? blit_error : fill_error;
wire requested_color_key = COLOR_KEY_ENABLE && op == OP_COLOR_KEY;
wire requested_copy = op == OP_BLIT || requested_color_key;

// Ordinary and color-key copies share blit_unit, its burst buffer and all
// error/drain states. Mask at the common output using ACCEPT-time snapshots.
// The disabled generate branch preserves the formal v4 data path.
genvar pixel;
generate if (COLOR_KEY_ENABLE) begin : key_strobes
    for (pixel = 0; pixel < 4; pixel = pixel + 1) begin : lanes
        assign copy_wstrb[pixel*4+:4] = selected_color_key &&
            blit_wdata[pixel*32+:24] == saved_color[23:0] ?
            4'b0000 : blit_wstrb[pixel*4+:4];
    end
end else begin : plain_strobes
    assign copy_wstrb = blit_wstrb;
end endgenerate

assign busy = state != IDLE;
// No queue and no second trigger: the platform must feed its final grant to
// START. Invalid opcodes/ranges are still accepted and counted, then rejected.
assign accept = rst_n && state == IDLE && enabled && start;
assign araddr = blit_araddr;
assign arlen = blit_arlen;
assign arvalid = blit_active && blit_arvalid;
assign rready = blit_active && blit_rready;
assign awaddr = selected_blit ? blit_awaddr : fill_awaddr;
assign awlen = selected_blit ? blit_awlen : fill_awlen;
assign awvalid = state == RUN && (selected_blit ? blit_awvalid : fill_awvalid);
assign wdata = selected_blit ? blit_wdata : fill_wdata;
assign wstrb = selected_blit ? copy_wstrb : fill_wstrb;
assign wlast = state == RUN && (selected_blit ? blit_wlast : fill_wlast);
assign wvalid = state == RUN && (selected_blit ? blit_wvalid : fill_wvalid);
assign bready = state == RUN && (selected_blit ? blit_bready : fill_bready);

// SETTLE_FRAMES=0 matches the double-buffered platform: command completion
// means memory work finished. A later explicit swap controls presentation.
fill_rect_writer #(
    .FRAME_WIDTH(FRAME_WIDTH), .FRAME_HEIGHT(FRAME_HEIGHT),
    .FRAME_STRIDE(FRAME_STRIDE), .MAX_BURST_BEATS(MAX_BURST_BEATS),
    .WATCHDOG_BITS(WATCHDOG_BITS), .SETTLE_FRAMES(0)
) fill_unit (
    .clk(clk), .rst_n(rst_n), .enabled(1'b1),
    .start(state == LAUNCH && !selected_blit),
    .rect_x(saved_x), .rect_y(saved_y), .rect_width(saved_width), .rect_height(saved_height),
    .rect_color(saved_color), .display_frame_tick(1'b0),
    .busy(fill_busy), .done(fill_done), .error_code(fill_error), .command_count(),
    .awaddr(fill_awaddr), .awlen(fill_awlen), .awvalid(fill_awvalid),
    .awready(fill_active && awready), .wdata(fill_wdata), .wstrb(fill_wstrb),
    .wlast(fill_wlast), .wvalid(fill_wvalid), .wready(fill_active && wready),
    .bid(bid), .bresp(bresp), .bvalid(fill_active && bvalid), .bready(fill_bready)
);

blit_engine #(
    .FRAME_WIDTH(FRAME_WIDTH), .FRAME_HEIGHT(FRAME_HEIGHT),
    .FRAME_STRIDE(FRAME_STRIDE), .MAX_BURST_BEATS(MAX_BURST_BEATS),
    .WATCHDOG_BITS(WATCHDOG_BITS)
) blit_unit (
    .clk(clk), .rst_n(rst_n), .enabled(1'b1),
    .start(state == LAUNCH && selected_blit && source_range_checked),
    .src_addr(source), .src_stride(source_stride),
    .dst_x(saved_x), .dst_y(saved_y), .width(saved_width), .height(saved_height),
    .busy(blit_busy), .done(blit_done), .error_code(blit_error), .command_count(),
    .araddr(blit_araddr), .arlen(blit_arlen), .arvalid(blit_arvalid),
    .arready(blit_active && arready), .rdata(rdata), .rid(rid), .rresp(rresp),
    .rlast(rlast), .rvalid(blit_active && rvalid), .rready(blit_rready),
    .awaddr(blit_awaddr), .awlen(blit_awlen), .awvalid(blit_awvalid),
    .awready(blit_active && awready), .wdata(blit_wdata), .wstrb(blit_wstrb),
    .wlast(blit_wlast), .wvalid(blit_wvalid), .wready(blit_active && wready),
    .bid(bid), .bresp(bresp), .bvalid(blit_active && bvalid), .bready(blit_bready)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= IDLE; selected_blit <= 0; selected_color_key <= 0; source_range_checked <= 0;
        saved_x <= 0; saved_y <= 0; saved_width <= 0; saved_height <= 0; saved_color <= 0;
        source <= 0; source_stride <= 0;
        done <= 0; error_code <= 0; command_count <= 0;
    end else begin
        case (state)
        IDLE: if (accept) begin
            saved_x <= x; saved_y <= y; saved_width <= width; saved_height <= height;
            saved_color <= color; source <= src_addr; source_stride <= src_stride;
            done <= 0; error_code <= 0; command_count <= command_count + 1'b1;
            if (op != OP_FILL && !requested_copy) begin
                // Count the accepted request, report an error, never touch AXI.
                done <= 1; error_code <= ERR_OPCODE;
            end else begin
                selected_blit <= requested_copy;
                selected_color_key <= requested_color_key;
                state <= requested_copy ? CHECK_SOURCE : LAUNCH;
            end
        end
        CHECK_SOURCE: begin
            // C latches its result on ACCEPT, using the same parameters/Front.
            // Sample that registered result here, never the previous command's
            // value on the acceptance edge. No child/AXI can start yet.
            source_range_checked <= src_range_valid;
            if (!src_range_valid) begin
                error_code <= ERR_BLIT_PARAM;
                done <= 1;
                state <= IDLE;
            end else state <= LAUNCH;
        end
        LAUNCH: begin
            // The selected child samples its one-cycle START on this edge.
            // Wait until RUN to observe DONE: its old sticky result is now
            // cleared (or replaced by a fresh invalid-geometry completion).
            state <= RUN;
        end
        RUN: begin
            // Expose errors while draining, and also while BLIT is in FAULT.
            // Neither enabled nor new external parameters can cancel a DMA.
            error_code <= selected_error;
            if (selected_done && !selected_busy) begin
                done <= 1;
                state <= IDLE;
            end
        end
        endcase
    end
end

// synthesis translate_off
initial if (OP_FILL == OP_BLIT || (COLOR_KEY_ENABLE &&
    (OP_COLOR_KEY == OP_FILL || OP_COLOR_KEY == OP_BLIT)))
    $fatal(1, "Enabled graphics opcodes must differ");
// synthesis translate_on
endmodule
