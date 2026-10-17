`timescale 1ns/1ps
module tb_c_arbiter;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,display_urgent=0,external_fault=0;
reg [31:0] d_araddr=32'h1000,b_araddr=32'h2000;
reg [7:0] d_arlen=1,b_arlen=0;
reg d_arvalid=0,b_arvalid=0,d_rready=1,b_rready=1,m_arready=0;
reg [127:0] m_rdata=0;reg [3:0] m_rid=0;reg [1:0] m_rresp=0;
reg m_rlast=0,m_rvalid=0;
wire d_arready,b_arready,d_rlast,b_rlast,d_rvalid,b_rvalid,m_arvalid,m_rready;
wire [127:0] d_rdata,b_rdata;wire [3:0] d_rid,b_rid;wire [1:0] d_rresp,b_rresp;
wire [31:0] m_araddr,display_bursts,blit_bursts,blit_wait_cycles;
wire [7:0] m_arlen;wire fault,outstanding,owner_valid,owner_blit;
integer i;
c_axi_read_arbiter dut(.*);
task reset;
begin
 @(negedge clk);rst_n=0;external_fault=0;d_arvalid=0;b_arvalid=0;
 m_arready=0;m_rvalid=0;m_rlast=0;d_rready=1;b_rready=1;
 repeat(2) @(negedge clk);rst_n=1;
end endtask
task address;
input which;input [7:0] len;
begin
 @(negedge clk);
 if(which) begin b_arvalid=1;b_arlen=len;end
 else begin d_arvalid=1;d_arlen=len;end
 wait(m_arvalid);#1;
 if(owner_blit!==which || m_arlen!==len) $fatal(1,"address selection");
 @(negedge clk);m_arready=1;@(posedge clk);#1;
 if(!outstanding) $fatal(1,"missing outstanding");
 @(negedge clk);m_arready=0;b_arvalid=0;d_arvalid=0;
end endtask
task beat;
input which,last;
begin
 @(negedge clk);m_rvalid=1;m_rlast=last;m_rdata=m_rdata+1;
 #1;
 if(which ? (!b_rvalid || d_rvalid || b_rdata!==m_rdata) : (!d_rvalid || b_rvalid || d_rdata!==m_rdata))
   $fatal(1,"response routing");
 if(which ? (b_rresp!==m_rresp || b_rid!==m_rid) : (d_rresp!==m_rresp || d_rid!==m_rid))
   $fatal(1,"response sideband routing");
 @(posedge clk);#1;@(negedge clk);m_rvalid=0;m_rlast=0;
end endtask
initial begin
 reset;
 // Urgent display wins, later priority changes cannot retract/stomp AR.
 @(negedge clk);d_arvalid=1;b_arvalid=1;display_urgent=1;
 wait(m_arvalid);#1;if(owner_blit || m_araddr!=32'h1000) $fatal(1,"urgent selection");
 @(negedge clk);display_urgent=0;
 repeat(3) begin @(posedge clk);#1;if(!m_arvalid || m_araddr!=32'h1000 || b_arready) $fatal(1,"AR stability");end
 @(negedge clk);m_arready=1;@(posedge clk);#1;
 @(negedge clk);m_arready=0;d_arvalid=0;
 beat(0,0);
 // Last beat under backpressure must not release ownership.
 @(negedge clk);d_rready=0;m_rvalid=1;m_rlast=1;
 repeat(3) begin @(posedge clk);#1;if(!owner_valid || m_rready || !d_rvalid || b_rvalid) $fatal(1,"last backpressure");end
 @(negedge clk);d_rready=1;@(posedge clk);#1;
 if(owner_valid) $fatal(1,"normal release");
 @(negedge clk);m_rvalid=0;m_rlast=0;
 wait(m_arvalid);#1;if(!owner_blit) $fatal(1,"BLIT progress");
 @(negedge clk);m_arready=1;@(posedge clk);#1;
 @(negedge clk);m_arready=0;b_arvalid=0;
 m_rresp=2;m_rid=3;beat(1,1);
 if(fault || owner_valid) $fatal(1,"response error must be routed/drained, not protocol lock");
 m_rresp=0;m_rid=0;
 address(0,127);for(i=0;i<128;i=i+1) beat(0,i==127);
 if(fault || owner_valid) $fatal(1,"128-beat display");
 address(1,31);for(i=0;i<32;i=i+1) beat(1,i==31);
 address(1,1);beat(1,1);
 if(!fault || !owner_valid || !owner_blit || !outstanding) $fatal(1,"early last lock");
 @(negedge clk);d_arvalid=1;repeat(4) @(posedge clk);#1;
 if(m_arvalid || d_arready) $fatal(1,"fault accepted new AR");
 reset;address(1,0);beat(1,0);
 if(!fault || !owner_valid) $fatal(1,"missing last lock");
 reset;
 @(negedge clk);b_arvalid=1;wait(m_arvalid);
 @(negedge clk);external_fault=1;repeat(2) @(posedge clk);#1;
 if(!m_arvalid || !fault) $fatal(1,"FAULT cancelled exposed AR");
 @(negedge clk);m_arready=1;@(posedge clk);#1;
 if(!outstanding || !owner_valid) $fatal(1,"FAULT lost accepted AR");
 reset;
 @(negedge clk);m_rvalid=1;@(posedge clk);#1;
 if(!fault || owner_valid) $fatal(1,"unsolicited R");
 $display("PASS C arbiter: priority, AR/R stalls, routing, 128/32 beats, response errors, protocol/external faults");$finish;
end
initial begin #100000;$fatal(1,"arbiter timeout");end
endmodule
