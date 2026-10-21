`timescale 1ns/1ps
module tb_fifo_sequence;
reg wclk=0,rclk=0,rst=1,we=0,re=0;
always #10 wclk=~wclk;
always #6.734 rclk=~rclk;
reg [127:0] wd=0;
wire [127:0] rd;
wire empty,full;
DC_FIFO #(.DATA_WIDTH(128),.FIFO_DEPTH(1024)) dut(.Reset(rst),.WrClk(wclk),.WrEn(we),.WrData(wd),.WrFull(full),.RdClk(rclk),.RdEn(re),.RdData(rd),.RdEmpty(empty));
integer n;
initial begin
 repeat(20) @(negedge wclk);rst=0;
 repeat(20) @(negedge wclk);
 for(integer chunk=0;chunk<6;chunk=chunk+1) begin
  for(n=0;n<256;n=n+1) begin wd=chunk*256+n;we=1;@(negedge wclk);end
  we=0;repeat(20) @(negedge rclk);
  for(n=0;n<256;n=n+1) begin
   if(empty) $fatal(1,"FIFO early empty at chunk %0d index %0d",chunk,n);
   re=1;@(posedge rclk);#2;
   if(rd!==chunk*256+n) $fatal(1,"FIFO sequence chunk=%0d index=%0d got=%0d",chunk,n,rd);
   @(negedge rclk);
  end
  re=0;repeat(20) @(negedge wclk);
 end
 re=0;$display("PASS FIFO sequence: 1536 distinct beats across address wrap");$finish;
end
endmodule
