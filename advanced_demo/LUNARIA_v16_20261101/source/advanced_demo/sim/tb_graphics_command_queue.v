`timescale 1ns/1ps
module tb_graphics_command_queue;
parameter DEPTH=3;
reg clk=0,rst_n=0,enable=1,push=0,pop=0,flush=0;
reg [31:0] push_data=0;
wire ready,valid;
wire [31:0] head_data;
wire [$clog2(DEPTH+1)-1:0] count;
wire [31:0] accepted_count;
integer checks=0;
always #5 clk=~clk;
graphics_command_queue #(.DEPTH(DEPTH),.WIDTH(32)) dut(
 .clk(clk),.rst_n(rst_n),.enable(enable),.push(push),.push_data(push_data),.ready(ready),
 .pop(pop),.valid(valid),.head_data(head_data),.flush(flush),.count(count),
 .accepted_count(accepted_count));
task enqueue;
input [31:0] value;
begin
 @(negedge clk);push_data=value;push=1;
 #1;if(!ready) $fatal(1,"Queue rejected descriptor %h with free space",value);
 @(posedge clk);#1;push=0;checks=checks+1;
end endtask
task dequeue;
input [31:0] expected;
begin
 @(negedge clk);
 if(!valid || head_data!==expected) $fatal(1,"Queue head %h expected %h",head_data,expected);
 pop=1;@(posedge clk);#1;pop=0;checks=checks+1;
end endtask
initial begin
 repeat(3)@(negedge clk);rst_n=1;
 enqueue(32'h11);enqueue(32'h22);enqueue(32'h33);
 if(count!=DEPTH || ready || accepted_count!=3) $fatal(1,"Full/count/accept accounting failed");
 @(negedge clk);pop=1;push=1;push_data=32'h44;
 @(posedge clk);#1;pop=0;push=0;
 if(count!=DEPTH-1 || accepted_count!=3 || head_data!==32'h22)
  $fatal(1,"Full simultaneous pop/push must pop only; count=%0d head=%h",count,head_data);
 enqueue(32'h44);
 dequeue(32'h22);dequeue(32'h33);dequeue(32'h44);
 if(count!=0 || valid || accepted_count!=4) $fatal(1,"Wrap/drain accounting failed");
 enqueue(32'h55);enqueue(32'h66);
 @(negedge clk);flush=1;@(posedge clk);#1;flush=0;
 if(count!=0 || valid || accepted_count!=6) $fatal(1,"Flush must discard pending work, preserving accept count");
 enable=0;@(negedge clk);
 if(ready || valid) $fatal(1,"Disabled queue exposed ready/valid");
 $display("PASS graphics command queue: %0d checks, order/wrap/full/backpressure/flush",checks);
 $finish;
end
initial begin #10000;$fatal(1,"Command queue test watchdog");end
endmodule
