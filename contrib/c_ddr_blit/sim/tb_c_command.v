`timescale 1ns/1ps
module tb_c_command;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,init_done=0,start=0,writer_busy=0,writer_done=0,read_fault=0;
reg swap_request=0,clear_done=0,boundary_tick=0,blank_active=1,reader_safe=1,reader_fifo_empty=1;
reg [31:0] op=1,x=64,y=64,width=32,height=32,color=0,src_addr=0,src_stride=7680;
reg [31:0] writer_error=0,relative_awaddr=32'h78100;
wire accept,draw_ready,src_range_valid,writer_owned,front_index,back_index,front_valid;
wire swap_pending,swap_done,reader_flush,reader_launch,platform_fault;
wire [31:0] front_base,back_base,command_base,reader_base,source_front_base;
wire [31:0] boundary_count,swap_count,missed_boundary_count,absolute_awaddr;
wire [31:0] accepted_op,accepted_x,accepted_y,accepted_width,accepted_height;
wire [31:0] accepted_color,accepted_src_addr,accepted_src_stride;
c_command_service dut(.*);
task reset;
begin
 @(negedge clk);rst_n=0;init_done=0;start=0;writer_busy=0;writer_done=0;
 writer_error=0;read_fault=0;swap_request=0;boundary_tick=0;
 repeat(2) @(negedge clk);rst_n=1;init_done=1;repeat(2) @(negedge clk);
end endtask
task submit;
begin
 @(negedge clk);start=1;#1;if(!accept) $fatal(1,"command not accepted");
 @(posedge clk);#1;if(!writer_owned) $fatal(1,"ownership missing");
 @(negedge clk);start=0;writer_busy=1;writer_done=0;
end endtask
task finish_command;
begin
 @(negedge clk);writer_busy=0;writer_done=1;@(posedge clk);#1;
end endtask
task boundary;
begin @(negedge clk);boundary_tick=1;@(negedge clk);boundary_tick=0;end
endtask
task request_swap;
begin @(negedge clk);swap_request=1;@(negedge clk);swap_request=0;end
endtask
initial begin
 reset;submit;
 if(!src_range_valid || command_base!=32'h800000 || absolute_awaddr!=32'h878100 || accepted_x!=64)
     $fatal(1,"snapshot or base addition");
 src_addr=32'hdeadbeef;x=0;
 repeat(3) @(posedge clk);#1;
 if(accepted_src_addr!=0 || accepted_x!=64 || !src_range_valid) $fatal(1,"mutable command");
 request_swap;boundary;repeat(12) @(negedge clk);
 if(front_base!=0 || !swap_pending || !writer_owned) $fatal(1,"swap while busy");
 finish_command;if(writer_owned) $fatal(1,"normal completion ownership");
 boundary;wait(reader_launch);#1;
 if(front_base!=32'h800000 || back_base!=0 || swap_count!=1) $fatal(1,"safe swap");
 @(negedge clk);src_addr=32'h800000;src_stride=128;
 submit;if(src_range_valid) $fatal(1,"invalid range accepted as valid");
 writer_error=32'h21;finish_command;
 if(writer_owned) $fatal(1,"parameter failure failed to release");
 // Unknown op is accepted and retired by B with 0x26, not a platform FAULT.
 writer_error=0;op=32'hffffffff;submit;
 if(!src_range_valid || accepted_op!=32'hffffffff) $fatal(1,"unknown op snapshot");
 writer_error=32'h26;finish_command;
 if(writer_owned || platform_fault) $fatal(1,"0x26 incorrectly held ownership");
 op=1;
 // No-swap frame refresh may accept a command: never drop a one-cycle START
 // merely because display is flushing. A real swap is blocked by pending.
 writer_error=0;boundary;wait(reader_flush);
 submit;
 wait(reader_launch);#1;
 if(!writer_owned || front_base!=32'h800000 || command_base!=0)
     $fatal(1,"no-swap refresh changed command ownership/base");
 finish_command;
 repeat(3) @(negedge clk);
 src_stride=7680;submit;writer_error=32'h25;writer_done=1;writer_busy=0;
 repeat(3) @(negedge clk);
 if(!writer_owned || !platform_fault || draw_ready) $fatal(1,"0x25 failed to hold");
 writer_error=0;request_swap;boundary;repeat(12) @(negedge clk);
 if(swap_count!=1 || !writer_owned || !platform_fault) $fatal(1,"FAULT cleared without platform reset");
 // Fault arriving AFTER swap decision must cancel commit.
 reset;request_swap;boundary;wait(reader_flush);
 @(negedge clk);read_fault=1;
 repeat(12) @(negedge clk);
 if(swap_count || front_base!=0 || !swap_pending) $fatal(1,"late fault published frame");
 reset;if(platform_fault || writer_owned) $fatal(1,"reset did not recover");
 $display("PASS C command: snapshots, Back address, 0x21/0x26 release, busy/swap, START during no-swap flush, sticky FAULT");$finish;
end
initial begin #20000;$fatal(1,"command timeout");end
endmodule
