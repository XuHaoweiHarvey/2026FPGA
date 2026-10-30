`timescale 1ns/1ps
module tb_init_write_monitor;
parameter FRAME_BEATS=512;
reg clk=0,rst_n=0,source_done=0,fifo_empty=0,writer_idle=0,overflow=0;
always #5 clk=~clk;
reg [31:0] addr=0;
reg [7:0] len=127;
reg av=0,wv=0,wl=0,bv=0;
reg [1:0] resp=0;
wire done;wire [31:0] error_code,beats,aws,lasts,bs,reserved;
init_write_monitor #(.FRAME_BEATS(FRAME_BEATS),.WATCHDOG_BITS(12)) dut (
 .clk(clk),.rst_n(rst_n),.source_done(source_done),.fifo_empty(fifo_empty),
 .writer_idle(writer_idle),.source_overflow(overflow),.awaddr(addr),.awlen(len),
 .awsize(3'd4),.awburst(2'd1),.awvalid(av),.awready(1'b1),
 .wstrb(16'hffff),.wvalid(wv),.wready(1'b1),.wlast(wl),
 .bid(4'b0),.bresp(resp),.bvalid(bv),.bready(1'b1),
 .init_done(done),.init_error(error_code),.data_beats(beats),.aw_bursts(aws),
 .wlast_bursts(lasts),.b_responses(bs),.aw_reserved_beats(reserved));
task reset;
begin
 @(negedge clk);rst_n=0;av=0;wv=0;wl=0;bv=0;source_done=0;fifo_empty=0;writer_idle=0;overflow=0;resp=0;
 repeat(3) @(negedge clk);rst_n=1;
end endtask
task burst;
input integer offset;
input integer count;
input integer response;
integer k;
begin
 @(negedge clk);addr=offset*16;len=count-1;av=1;
 @(negedge clk);av=0;wv=1;
 for(k=0;k<count;k=k+1) begin wl=(k==count-1);@(negedge clk);end
 wv=0;wl=0;
 if(response) begin bv=1;@(negedge clk);bv=0;end
end endtask
integer offset,n,expected_bursts;
initial begin
 reset;
 expected_bursts=(FRAME_BEATS+127)/128;
 for(offset=0;offset<FRAME_BEATS;offset=offset+128) begin
  n=(FRAME_BEATS-offset<128)?FRAME_BEATS-offset:128;
  burst(offset,n,offset+128<FRAME_BEATS);
 end
 source_done=1;fifo_empty=1;writer_idle=1;
 repeat(30) @(negedge clk);
 if(done || error_code || beats!=FRAME_BEATS || aws!=expected_bursts || lasts!=aws || bs!=aws-1)
  $fatal(1,"barrier failed before final B: error=%h beat=%d AW=%d WLAST=%d B=%d",error_code,beats,aws,lasts,bs);
 bv=1;@(negedge clk);bv=0;
 // Keep idle false even with all successful responses: no early ownership.
 writer_idle=0;repeat(8) @(negedge clk);if(done) $fatal(1,"ignored writer pipeline");
 writer_idle=1;repeat(4) @(negedge clk);
 if(!done || error_code || reserved!=FRAME_BEATS || bs!=expected_bursts) $fatal(1,"missing INIT_DONE");
 av=1;wv=1;bv=1;overflow=1;repeat(4) @(negedge clk);
 if(!done || error_code || beats!=FRAME_BEATS) $fatal(1,"ownership not permanent/counters not frozen");
 reset;burst(0,128,0);resp=2;bv=1;@(negedge clk);bv=0;
 repeat(4) @(negedge clk);if(done || error_code!=32'h1002) $fatal(1,"BRESP fault not blocked");
 reset;overflow=1;repeat(3) @(negedge clk);if(done || error_code!=32'h1001) $fatal(1,"overflow not blocked");
 reset;av=1;@(negedge clk);av=0;wv=1;wl=1;@(negedge clk);wv=0;wl=0;
 repeat(3) @(negedge clk);if(done || error_code!=32'h1003) $fatal(1,"early WLAST not blocked");
 reset;source_done=1;repeat(4100) @(negedge clk);
 if(done || error_code!=32'h1004) $fatal(1,"missing initialization timeout");
 $display("PASS init barrier: %0d data beats, %0d AW/WLAST/B bursts; delayed B, idle, errors, timeout, permanent ownership",FRAME_BEATS,expected_bursts);
 $finish;
end
endmodule
