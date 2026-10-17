`timescale 1ns/1ps
module tb_c_range;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,accept=0;
reg [31:0] op=1,src_addr=0,src_stride=7680,width=32,height=32,front_base=0;
wire src_range_valid;wire [31:0] source_front_base;
integer cases=0;
c_front_range_guard dut(.*);
task check;
input expected;
begin
 @(negedge clk);accept=1;@(posedge clk);#1;
 if(src_range_valid!==expected) $fatal(1,"range case %0d addr=%h w=%d h=%d",cases,src_addr,width,height);
 if(source_front_base!==front_base) $fatal(1,"front snapshot");
 cases=cases+1;@(negedge clk);accept=0;
end endtask
initial begin
 repeat(2) @(negedge clk);rst_n=1;
 check(1);
 src_stride=128;check(0);src_stride=7680;
 src_addr=7680-16;width=8;height=1;check(0);
 width=4;check(1);
 src_addr=32'h7e8ff0;check(1);height=2;check(0);
 src_addr=32'h7e9000;height=1;check(0);
 src_addr=0;width=0;check(0);width=4;height=0;check(0);
 height=1;src_addr=4;check(0);
 front_base=32'h800000;src_addr=0;check(0);
 src_addr=32'h800000;check(1);
 width=32'hffffffff;check(0);width=4;height=32'hffffffff;check(0);
 height=1;front_base=32'hfffff000;src_addr=32'hfffff000;check(0);
 op=0;check(1);op=2;check(1);
 // Parameter changes without accept must not change the result/snapshot.
 front_base=0;op=1;src_addr=0;width=4;height=1;check(1);
 src_addr=3;front_base=32'h800000;repeat(3) @(posedge clk);#1;
 if(!src_range_valid || source_front_base!=0) $fatal(1,"snapshot changed");
 $display("PASS C range: %0d cases plus stable snapshot",cases);$finish;
end
initial begin #10000;$fatal(1,"range timeout");end
endmodule
