`timescale 1ns/1ps
// Observe every event, including delta-cycle glitches invisible to posedge-clk
// sampling. frame_start directly drives a FIFO asynchronous reset.
module tb_rgb_tpg_pulse;
localparam H=64,V=8,HB=12,VB=4;
localparam PERIOD=(H/4+HB)*(V+VB);
reg clk=0,rst_n=0;
always #10 clk=~clk;
wire start;
rgb_tpg #(.H_ACTIVE(H),.V_ACTIVE(V),.H_BLANK_CYCLES(HB),.V_BLANK_LINES(VB)) dut (
    .clk(clk),.rst_n(rst_n),.frame_start(start));
realtime last_start=0;
integer pulses=0;
always @(posedge start) if(rst_n) begin
    if(pulses!=0 && $realtime-last_start!=PERIOD*20)
        $fatal(1,"Spurious asynchronous frame_start: interval=%0t expected=%0t",$realtime-last_start,PERIOD*20.0);
    last_start=$realtime;pulses=pulses+1;
end
initial begin
    repeat(5) @(negedge clk);rst_n=1;
    repeat(PERIOD*4) @(negedge clk);
    if(pulses!=4) $fatal(1,"Frame pulse count=%0d",pulses);
    $display("PASS frame_start: four registered pulses, no line-boundary async reset glitch");$finish;
end
endmodule
