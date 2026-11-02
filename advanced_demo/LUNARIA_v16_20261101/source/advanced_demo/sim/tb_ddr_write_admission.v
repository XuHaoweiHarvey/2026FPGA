`timescale 1ns/1ps
module tb_ddr_write_admission;
reg clk=0,vclk=0,rst=0,enabled=1,aw=0,awready=0,bv=0;
reg active=1,safe=0,launch=0,flush=0,arv=0,arr=1,rv=0,rr=1,underflow=0;
reg [31:0] level=0,err=0,outstanding=0;
wire admit;
wire [31:0] status,throttle,bursts,ars,arm,rs,rm,frames,maxw,underflows;
always #5 clk=~clk;
initial begin #2.123;forever #6.734 vclk=~vclk;end
ddr_write_admission dut(.clk(clk),.rst_n(rst),.enabled(enabled),.raw_awvalid(aw),
 .ddr_awready(awready),.bvalid(bv),.bready(1'b1),.reader_active(active),.reader_safe(safe),
 .reader_launch(launch),.fifo_flush(flush),.fifo_level(level),.reader_error(err),
 .arvalid(arv),.arready(arr),.rvalid(rv),.rready(rr),.reader_outstanding(outstanding),
 .admit_aw(admit),.service_status(status),.throttle_cycles(throttle),.writer_bursts(bursts),
 .ar_stall_cycles(ars),.ar_max_stall(arm),.r_stall_cycles(rs),.r_max_stall(rm),
 .frame_completions(frames),.max_write_cycles(maxw));
display_underflow_counter counter(.video_clk(vclk),.video_rst_n(rst),.underflow(underflow),
 .core_clk(clk),.core_rst_n(rst),.count(underflows));
task reads;
input integer n;
begin rv=1;repeat(n) @(negedge clk);rv=0;end endtask
task response;
begin bv=1;@(negedge clk);bv=0;@(negedge clk);end endtask
initial begin
 repeat(5)@(negedge clk);rst=1;aw=1;
 level=512;reads(127);if(admit)$fatal(1,"Writer escaped before read quota");
 // No RREADY means no service credit, even with RVALID high.
 rr=0;reads(5);if(admit)$fatal(1,"Unaccepted R earned credit");rr=1;
 reads(1);repeat(2)@(negedge clk);if(!admit)$fatal(1,"Writer starved despite quota and water");
 // AW is exposed but not READY. Changing urgency must never withdraw VALID.
 level=0;launch=1;repeat(10)@(negedge clk);launch=0;
 if(!admit)$fatal(1,"AW authorization revoked under backpressure");
 awready=1;@(negedge clk);aw=0;awready=0;
 reads(128);response();aw=1;level=512;
 repeat(5)@(negedge clk);if(admit)$fatal(1,"R before B paid for next write");
 reads(128);repeat(2)@(negedge clk);if(!admit)$fatal(1,"No progress after B and reader service");
 awready=1;@(negedge clk);aw=0;awready=0;response();
 level=0;reads(128);aw=1;repeat(5)@(negedge clk);if(admit)$fatal(1,"Low water ignored");
 level=450;repeat(5)@(negedge clk);if(admit)$fatal(1,"Hysteresis did not wait for high water");
 level=512;repeat(3)@(negedge clk);if(!admit)$fatal(1,"High water did not release writer");
 awready=1;@(negedge clk);aw=0;awready=0;response();
 // End of frame: no future reads are owed. Slack must allow writer progress.
 active=0;safe=1;aw=1;level=0;repeat(3)@(negedge clk);
 if(!admit || frames!=1)$fatal(1,"Frame-end slack deadlock/count");
 awready=1;@(negedge clk);aw=0;awready=0;response();
 launch=1;aw=1;repeat(5)@(negedge clk);if(admit)$fatal(1,"New grant during reader launch");
 launch=0;active=1;safe=0;err='h2003;level=512;reads(128);
 repeat(3)@(negedge clk);if(admit)$fatal(1,"Faulted reader bypassed");aw=0;
 arv=1;arr=0;outstanding=1;repeat(17)@(negedge clk);arv=0;outstanding=0;
 if(ars!=17 || arm!=17 || rs!=17 || rm!=17 || bursts!=4 || throttle==0)
  $fatal(1,"Service diagnostics incorrect");
 @(negedge vclk);underflow=1;repeat(37)@(negedge vclk);underflow=0;
 repeat(10)@(negedge clk);if(underflows!=37)$fatal(1,"Underflow Gray CDC lost samples");
 $display("PASS admission: read quota/handshake, post-B credit, hysteresis, held AW, slack progress, faults, counters, async underflow CDC");
 $finish;
end
initial begin #100000;$fatal(1,"Admission test timeout");end
endmodule
