`timescale 1ns/1ps
// FIFO level must already be synchronized into clk, as in the existing reader.
module c_display_read_priority #(
    parameter FIFO_LOW=384,FIFO_HIGH=512
)(
    input wire clk,rst_n,reader_active,
    input wire [31:0] fifo_level,
    output wire display_urgent
);
reg urgent;
assign display_urgent=reader_active && urgent;
always @(posedge clk or negedge rst_n)
    if(!rst_n) urgent<=1;
    else if(!reader_active || fifo_level<=FIFO_LOW) urgent<=1;
    else if(fifo_level>=FIFO_HIGH) urgent<=0;
// synthesis translate_off
initial if(FIFO_LOW<1 || FIFO_HIGH<=FIFO_LOW) $fatal(1,"Invalid read priority watermarks");
// synthesis translate_on
endmodule
