`timescale 1ns/1ps
// Core-clock C-side command boundary. B samples raw command fields at accept;
// src_range_valid and command_base belong to that command one cycle later.
module c_command_service #(
    parameter FRAME_WIDTH=1920,FRAME_HEIGHT=1080,FRAME_STRIDE=7680,
    parameter [31:0] BUFFER0_BASE=0,BUFFER1_BASE=32'h00800000
)(
    input wire clk,rst_n,init_done,
    input wire [31:0] op,x,y,width,height,color,src_addr,src_stride,
    input wire start,
    output wire accept,draw_ready,src_range_valid,
    input wire writer_busy,writer_done,
    input wire [31:0] writer_error,
    input wire read_fault,swap_request,clear_done,boundary_tick,blank_active,
    input wire reader_safe,reader_fifo_empty,
    output wire writer_owned,front_index,back_index,front_valid,swap_pending,swap_done,
    output wire [31:0] front_base,back_base,command_base,reader_base,source_front_base,
    output wire reader_flush,reader_launch,
    output wire [31:0] boundary_count,swap_count,missed_boundary_count,
    input wire [31:0] relative_awaddr,
    output wire [31:0] absolute_awaddr,
    output reg platform_fault,
    output reg [31:0] accepted_op,accepted_x,accepted_y,accepted_width,
    output reg [31:0] accepted_height,accepted_color,accepted_src_addr,accepted_src_stride
);
wire fault_now=platform_fault || read_fault || writer_error==32'h25;
assign absolute_awaddr=command_base+relative_awaddr;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        platform_fault<=0;accepted_op<=0;accepted_x<=0;accepted_y<=0;
        accepted_width<=0;accepted_height<=0;accepted_color<=0;
        accepted_src_addr<=0;accepted_src_stride<=0;
    end else begin
        if(read_fault || writer_error==32'h25) platform_fault<=1;
        if(accept) begin
            accepted_op<=op;accepted_x<=x;accepted_y<=y;
            accepted_width<=width;accepted_height<=height;accepted_color<=color;
            accepted_src_addr<=src_addr;accepted_src_stride<=src_stride;
        end
    end
end
c_front_range_guard #(.FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT),
    .FRAME_STRIDE(FRAME_STRIDE)) range_guard (
    .clk(clk),.rst_n(rst_n),.accept(accept),.op(op),.src_addr(src_addr),
    .src_stride(src_stride),.width(width),.height(height),.front_base(front_base),
    .src_range_valid(src_range_valid),.source_front_base(source_front_base));
c_buffer_manager #(.BUFFER0_BASE(BUFFER0_BASE),.BUFFER1_BASE(BUFFER1_BASE)) manager (
    .clk(clk),.rst_n(rst_n),.init_done(init_done),.platform_fault(fault_now),
    .cmd_request(start),.writer_busy(writer_busy),.writer_done(writer_done),.writer_error(writer_error),
    .swap_request(swap_request),.clear_done(clear_done),.boundary_tick(boundary_tick),
    .blank_active(blank_active),.reader_safe(reader_safe),.reader_fifo_empty(reader_fifo_empty),
    .command_accept(accept),.draw_ready(draw_ready),.writer_owned(writer_owned),
    .front_index(front_index),.back_index(back_index),.front_valid(front_valid),
    .swap_pending(swap_pending),.swap_done(swap_done),.front_base(front_base),.back_base(back_base),
    .command_base(command_base),.reader_base(reader_base),.reader_flush(reader_flush),
    .reader_launch(reader_launch),.boundary_count(boundary_count),.swap_count(swap_count),
    .missed_boundary_count(missed_boundary_count));
endmodule
