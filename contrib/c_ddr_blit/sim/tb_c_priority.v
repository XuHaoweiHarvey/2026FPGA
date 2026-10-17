`timescale 1ns/1ps
module tb_c_priority;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,reader_active=0;reg [31:0] fifo_level=0;
wire display_urgent;
c_display_read_priority dut(.*);
task step;
input active;input [31:0] level;input expected;
begin
 @(negedge clk);reader_active=active;fifo_level=level;
 @(posedge clk);#1;if(display_urgent!==expected) $fatal(1,"priority hysteresis");
end endtask
initial begin
 repeat(2) @(negedge clk);rst_n=1;
 step(0,0,0);step(1,0,1);step(1,511,1);step(1,512,0);
 step(1,385,0);step(1,384,1);step(0,0,0);step(1,500,1);
 $display("PASS C display priority: low/high hysteresis and frame restart");$finish;
end
endmodule
