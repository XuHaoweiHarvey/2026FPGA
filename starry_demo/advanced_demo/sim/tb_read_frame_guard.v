`timescale 1ns/1ps
module tb_read_frame_guard;
reg clk=0,rst_n=0,launch=0,idle=1,av=0,ar=1,rv=0,rr=1,last=0;
reg [31:0] base=32'h00800000,addr=0;
reg [7:0] len=127;
reg [1:0] resp=0;
wire safe,active;
wire [31:0] outstanding,beats,reserved,error;
always #5 clk=~clk;
read_frame_guard dut(.clk(clk),.rst_n(rst_n),.launch(launch),.frame_base(base),
 .reader_idle(idle),.araddr(addr),.arlen(len),.arsize(3'd4),.arburst(2'd1),.arvalid(av),.arready(ar),
 .rvalid(rv),.rready(rr),.rlast(last),.rid(4'd0),.rresp(resp),.safe(safe),.active(active),
 .outstanding(outstanding),.data_beats(beats),.reserved_beats(reserved),.error_code(error));
task reset;
begin
 @(negedge clk);rst_n=0;launch=0;av=0;rv=0;last=0;rr=1;resp=0;idle=1;
 repeat(3) @(negedge clk);rst_n=1;@(negedge clk);
end endtask
task start;
begin launch=1;@(negedge clk);launch=0;idle=0;end endtask
task issue;
input [31:0] address;
begin addr=address;av=1;@(negedge clk);av=0;end endtask
integer burst,j;
initial begin
 reset();if(!safe) $fatal(1,"Initial reader not safe");start();
 for(burst=0;burst<4050;burst=burst+1) begin
  issue(base+burst*2048);
  if(safe || outstanding!=1) $fatal(1,"AR treated as completion");
  for(j=0;j<128;j=j+1) begin
   rv=1;last=(j==127);
   if(burst==4049 && j==127) begin
    rr=0;repeat(10) @(negedge clk);
    if(safe || beats!=518399 || reserved!=518400 || outstanding!=1) $fatal(1,"Missing last R bypassed");
    rr=1;
   end
   @(negedge clk);
  end
  rv=0;last=0;@(negedge clk);
 end
 if(beats!=518400 || reserved!=518400 || outstanding!=0 || safe || error!=0)
  $fatal(1,"Frame count or FIFO pipeline guard failed");
 repeat(8) @(negedge clk);if(safe) $fatal(1,"Ignored pipeline idle");
 idle=1;repeat(3) @(negedge clk);if(!safe || active) $fatal(1,"Frame never completed");
 // A second frame resets only per-frame counters, preserving address snapshot.
 base=0;start();issue(0);rv=1;resp=2;@(negedge clk);rv=0;
 if(error!='h2003 || safe) $fatal(1,"RRESP fault not latched");
 repeat(10) @(negedge clk);if(error!='h2003) $fatal(1,"RRESP fault not sticky");
 reset();start();issue(16);if(error!='h2002 || safe) $fatal(1,"Wrong AR address accepted");
 reset();start();issue(base);rv=1;last=1;@(negedge clk);rv=0;
 if(error!='h2002) $fatal(1,"Early RLAST accepted");
 reset();start();launch=1;@(negedge clk);launch=0;
 if(error!='h2001) $fatal(1,"Unsafe relaunch accepted");
 $display("PASS read guard: 518400 R beats/4050 bursts, stalled last R, FIFO pipeline, full-frame base reset, sticky RRESP/address/RLAST/relaunch errors");
 $finish;
end
initial begin #10000000;$fatal(1,"Read guard timeout");end
endmodule
