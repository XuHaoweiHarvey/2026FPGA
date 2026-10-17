`timescale 1ns/1ps
module tb_c_manager_regression;
reg clk=0,vclk=0,rst_n=0,period=0,init_done=0;
always #5 clk=~clk;
initial begin #2.123;forever #6.733 vclk=~vclk;end
wire tick,blank;
video_frame_cdc cdc(.video_clk(vclk),.video_rst_n(rst_n),.video_period(period),
 .core_clk(clk),.core_rst_n(rst_n),.boundary_tick(tick),.blank_active(blank));
reg cmd=0,busy=0,done=0,request=0,clear=0,safe=1,empty=1;
reg [31:0] error=0;
wire accept,ready,owned,front,back,valid,pending,swap_done,flush,launch;
wire [31:0] fb,bb,cb,rb,boundaries,swaps,missed;
c_buffer_manager dut(.platform_fault(1'b0),.clk(clk),.rst_n(rst_n),.init_done(init_done),.cmd_request(cmd),
 .writer_busy(busy),.writer_done(done),.writer_error(error),.swap_request(request),.clear_done(clear),
 .boundary_tick(tick),.blank_active(blank),.reader_safe(safe),.reader_fifo_empty(empty),
 .command_accept(accept),.draw_ready(ready),.writer_owned(owned),.front_index(front),.back_index(back),
 .front_valid(valid),.swap_pending(pending),.swap_done(swap_done),.front_base(fb),.back_base(bb),
 .command_base(cb),.reader_base(rb),.reader_flush(flush),.reader_launch(launch),
 .boundary_count(boundaries),.swap_count(swaps),.missed_boundary_count(missed));
integer sent=0,received=0,launches=0;
reg [31:0] held_base=0;
always @(posedge clk) begin
 if(rst_n && tick) received=received+1;
 #1;
 if(rst_n) begin
  if(front==back || fb==bb) $fatal(1,"Front/Back alias");
  if(rb!=held_base && !launch) $fatal(1,"Reader base changed within a frame");
  if(launch) begin
   if(!blank || !safe || flush) $fatal(1,"Unsafe reader launch");
   launches=launches+1;
  end
  held_base=rb;
 end
end
task boundary;
input integer cycles;
begin
 @(negedge vclk);period=1;sent=sent+1;
 repeat(cycles) @(negedge vclk);period=0;
 repeat(8) @(negedge vclk);
end endtask
task swap_req;
begin @(negedge clk);request=1;@(negedge clk);request=0;end endtask
integer i,n;
reg old_front;
initial begin
 repeat(5) @(negedge clk);rst_n=1;
 if(front!==0 || back!==1 || valid) $fatal(1,"Initial ownership");
 // Narrow video pulses with unrelated clocks must each survive the CDC.
 for(i=0;i<50;i=i+1) boundary(1);
 if(sent!=received || boundaries!=sent) $fatal(1,"Lost/duplicated toggle event %0d/%0d",sent,received);
 @(negedge clk);init_done=1;repeat(3)@(negedge clk);
 cmd=1;@(negedge clk);cmd=0;busy=1;
 if(!owned || cb!=32'h00800000) $fatal(1,"Command base not captured");
 swap_req();if(!pending || ready) $fatal(1,"Pending not blocking START");
 cmd=1;#1;if(accept) $fatal(1,"START during pending");cmd=0;
 boundary(40);if(front!=0 || swaps!=0 || !pending) $fatal(1,"Swapped while busy");
 @(negedge clk);busy=0;done=1;repeat(10) @(negedge clk);
 if(front!=0 || !pending) $fatal(1,"Swapped without boundary");
 boundary(40);if(front!=1 || back!=0 || pending || !swap_done || swaps!=1 || rb!=fb) $fatal(1,"First swap");
 repeat(20) @(negedge clk);if(!swap_done) $fatal(1,"DONE not sticky");
 clear=1;@(negedge clk);clear=0;@(negedge clk);if(swap_done) $fatal(1,"CLEAR_DONE");
 // Completed AR with delayed R is represented by reader_safe=0.
 safe=0;swap_req();boundary(40);
 if(front!=1 || !pending || flush) $fatal(1,"Swapped/flushed with outstanding R");
 safe=1;repeat(20) @(negedge clk);if(front!=1) $fatal(1,"Swapped on late R instead of boundary");
 boundary(40);if(front!=0 || pending || swaps!=2) $fatal(1,"Drain then swap");
 // FIFO clear acknowledgement is also required after the flush hold.
 swap_req();empty=0;
 fork
  boundary(40);
  begin wait(flush);wait(!flush);repeat(8) @(negedge clk);
    if(front!=0 || !pending) $fatal(1,"Ignored FIFO empty acknowledgement");empty=1;
  end
 join
 if(front!=1 || swaps!=3) $fatal(1,"FIFO release swap");
 for(i=0;i<8;i=i+1) begin
  old_front=front;swap_req();boundary(40);
  if(front==old_front || pending || !swap_done) $fatal(1,"Repeated swap");
 end
 // Error completion must not publish a potentially partial image.
 error='h12;swap_req();boundary(40);if(!pending || swaps!=11) $fatal(1,"Error frame published");
 if(sent!=received || boundaries!=sent) $fatal(1,"CDC event count mismatch");
 $display("PASS buffer manager: %0d async events, busy/pending/reader drain/FIFO ack/sticky clear/base snapshot/%0d swaps",received,swaps);
 $finish;
end
initial begin #1000000;$fatal(1,"Manager timeout");end
endmodule
