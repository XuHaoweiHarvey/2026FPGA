`timescale 1ns/1ps
// Front-only policy for the first BLIT integration. Platform reset only.
// Result is registered at accept and valid from the following cycle.
module c_front_range_guard #(
    parameter FRAME_WIDTH=1920, FRAME_HEIGHT=1080, FRAME_STRIDE=7680
)(
    input wire clk, rst_n, accept,
    input wire [31:0] op, src_addr, src_stride, width, height, front_base,
    output reg src_range_valid,
    output reg [31:0] source_front_base
);
wire [63:0] offset_bytes={32'b0,src_addr}-{32'b0,front_base};
wire [63:0] source_row=offset_bytes/FRAME_STRIDE;
wire [63:0] source_column_bytes=offset_bytes%FRAME_STRIDE;
wire [63:0] row_bytes={32'b0,width}<<2;
wire [63:0] front_end={32'b0,front_base}+64'd1*FRAME_STRIDE*FRAME_HEIGHT;
wire valid_blit=src_addr>=front_base && src_addr[3:0]==0 &&
    src_stride==FRAME_STRIDE && width!=0 && height!=0 &&
    source_column_bytes+row_bytes<=64'd4*FRAME_WIDTH &&
    source_row+{32'b0,height}<=FRAME_HEIGHT && front_end<=64'h100000000;
always @(posedge clk or negedge rst_n)
    if(!rst_n) begin src_range_valid<=0; source_front_base<=0; end
    else if(accept) begin
        source_front_base<=front_base;
        // Unknown op is B's 0x26 responsibility; range applies only to BLIT.
        src_range_valid<=op==32'd1 ? valid_blit : 1'b1;
    end
// synthesis translate_off
initial if(FRAME_WIDTH<1 || FRAME_HEIGHT<1 || FRAME_STRIDE!=4*FRAME_WIDTH)
    $fatal(1,"Unsupported source frame geometry");
// synthesis translate_on
endmodule
