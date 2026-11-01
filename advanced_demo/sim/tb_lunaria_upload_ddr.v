`timescale 1ns/1ps
module tb_lunaria_upload_ddr;
parameter DEPTH=1;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,cpu_reset=0,session_active=1,clear_error=0;
reg asset_loading=0,asset_ready=0,sprite_loading=0,sprite_ready=0;
parameter SPRITE_ENABLE=1;
reg [31:0] front_base=0,back_base=32'h00800000;
wire busy;wire [31:0] error_code;
reg [31:0] s_awaddr=0,s_araddr=0;
reg [7:0] s_awid=0,s_arid=0,s_awlen=0,s_arlen=0;
reg [2:0] s_awsize=4,s_arsize=4;
reg [1:0] s_awburst=1,s_arburst=1;
reg s_awlock=0,s_arlock=0,s_awvalid=0,s_wlast=1,s_wvalid=0,s_arvalid=0;
wire s_awready,s_wready,s_bvalid,s_arready,s_rvalid,s_rlast;
reg s_bready=0,s_rready=0;
reg [127:0] s_wdata=0;reg [15:0] s_wstrb=0;
wire [7:0] s_bid,s_rid;wire [1:0] s_bresp,s_rresp;wire [127:0] s_rdata;
wire [31:0] m_awaddr,m_araddr;wire m_awvalid,m_wvalid,m_wlast,m_bready,m_arvalid,m_rready;
reg m_awready=0,m_wready=0,m_bvalid=0;
wire m_arready,m_rvalid,m_rlast;
reg [3:0] m_bid=0;wire [3:0] m_rid;reg [1:0] m_bresp=0;wire [1:0] m_rresp;
wire [127:0] m_rdata;
wire [127:0] m_wdata;wire [15:0] m_wstrb;
integer i;
cpu_ddr_bridge #(.SPRITE_ENABLE(SPRITE_ENABLE)) dut(.*);

wire [31:0] araddr;wire [7:0] arlen;wire arvalid,rready;
wire display_arready,display_rvalid,display_rlast,arbiter_fault;
wire [127:0] display_rdata;
reg display_pending=0;integer display_left=0,display_checked=0;
wire display_request=!display_pending;
reg arready=0,rvalid=0,rlast=0;reg [127:0] rdata=0;
integer cycle=0,head=0,tail=0,ri=0,delay_count=0;
reg [31:0] rq_addr[0:7];reg [7:0] rq_len[0:7];
reg [31:0] memory[0:24575];
reg [31:0] saved_write;integer idx,lane,window,block,n;
reg [31:0] region,pattern;
function integer mem_index;
input [31:0] address;
begin mem_index=address>=32'h02000000 ? (address-32'h02000000)/4 : 12288+(address-32'h01384000)/4;end
endfunction
function [31:0] pixel;
input integer which,word_index;
begin pixel=32'ha73c9815^(word_index*32'h719a357b)^(which*32'h36fd4129);end
endfunction
ddr_read_arbiter #(.OUTSTANDING(DEPTH)) arbiter(
 .clk(clk),.rst_n(rst_n),.enabled(1'b1),.display_active(1'b1),.display_launch(1'b0),.display_flush(1'b0),.display_fifo_level(32'd700),
 .display_araddr(32'h00010000),.display_arlen(8'd7),.display_arvalid(display_request),.display_arready(display_arready),
 .display_rdata(display_rdata),.display_rvalid(display_rvalid),.display_rlast(display_rlast),.display_rready(cycle%7!=0),
 .blit_araddr(m_araddr),.blit_arlen(8'd0),.blit_arvalid(m_arvalid),.blit_arready(m_arready),
 .blit_rdata(m_rdata),.blit_rid(m_rid),.blit_rresp(m_rresp),.blit_rlast(m_rlast),.blit_rvalid(m_rvalid),.blit_rready(m_rready),
 .araddr(araddr),.arlen(arlen),.arvalid(arvalid),.arready(arready),
 .rdata(rdata),.rid(4'd0),.rresp(2'd0),.rlast(rlast),.rvalid(rvalid),.rready(rready),.fault(arbiter_fault));
always @(negedge clk) begin
 arready=tail-head<4 && cycle%5!=0;
 m_awready=cycle%3!=0;m_wready=cycle%4!=0;
end
always @(posedge clk) begin
 cycle<=cycle+1;
 if(rst_n)begin
  if(arbiter_fault || error_code)$fatal(1,"unexpected bus fault");
  if(display_request && display_arready)begin display_pending<=1;display_left<=8;end
  if(display_rvalid && cycle%7!=0)begin
   if(display_rdata!=={4{32'hdeadbeef}} || display_rlast!==(display_left==1))$fatal(1,"display data/owner");
   display_left<=display_left-1;display_checked<=display_checked+1;
   if(display_rlast)display_pending<=0;
  end
  if(m_awvalid && m_awready)saved_write<=m_awaddr;
  if(m_wvalid && m_wready)begin
   idx=mem_index(saved_write);
   if(idx<0 || idx+3>=24576)$fatal(1,"bad write region");
   for(lane=0;lane<16;lane=lane+1)if(m_wstrb[lane])memory[idx+lane/4][(lane%4)*8+:8]<=m_wdata[lane*8+:8];
   m_bvalid<=1;
  end
  if(m_bvalid && m_bready)m_bvalid<=0;
  if(arvalid && arready)begin rq_addr[tail%8]<=araddr;rq_len[tail%8]<=arlen;tail<=tail+1;end
  if(rvalid && rready)begin
   rvalid<=0;
   if(rlast)begin head<=head+1;ri<=0;delay_count<=cycle%9;end
   else ri<=ri+1;
  end
  if(!rvalid && head<tail)begin
   if(delay_count!=0)delay_count<=delay_count-1;
   else begin
    rvalid<=1;rlast<=ri==rq_len[head%8];
    if(rq_addr[head%8]==32'h00010000)rdata<={4{32'hdeadbeef}};
    else begin
     idx=mem_index(rq_addr[head%8]);
     if(idx<0 || idx+3>=24576)$fatal(1,"bad read region");
     for(lane=0;lane<4;lane=lane+1)rdata[lane*32+:32]<=memory[idx+lane];
    end
   end
  end
 end
end
initial begin
 repeat(3)@(negedge clk);rst_n=1;
 for(window=0;window<2;window=window+1)begin
  region=window ? 32'h01384000 : 32'h02000000;
  asset_loading=window==0;asset_ready=window==1;sprite_loading=window==1;
  for(block=0;block<12;block=block+1)begin
   // Firmware writes each complete 4 KiB block, then reads every word back.
   for(n=0;n<1024;n=n+1)begin
    @(negedge clk);s_awaddr=region+32'h1000+(block*1024+n)*4;
    s_wdata={4{pixel(window,block*1024+n)}};s_wstrb=16'hf<<((n%4)*4);
    s_awvalid=1;s_wvalid=1;
    wait(s_awready&&s_wready);@(posedge clk);@(negedge clk);s_awvalid=0;s_wvalid=0;
    wait(s_bvalid);if(s_bresp!=0)$fatal(1,"write error");
    s_bready=1;@(posedge clk);@(negedge clk);s_bready=0;
   end
   for(n=0;n<1024;n=n+1)begin
    @(negedge clk);s_araddr=region+32'h1000+(block*1024+n)*4;s_arvalid=1;
    wait(s_arready);@(posedge clk);@(negedge clk);s_arvalid=0;
    wait(s_rvalid);
    if(s_rresp!=0 || !s_rlast || s_rdata[(n%4)*32+:32]!==pixel(window,block*1024+n))
     $fatal(1,"upload mismatch window=%0d block=%0d word=%0d",window,block,n);
    s_rready=1;@(posedge clk);@(negedge clk);s_rready=0;
   end
  end
 end
 if(display_checked<10000)$fatal(1,"no display contention");
 $display("PASS UPLOAD DDR depth=%0d: 24 blocks/98304 bytes, all four CPU lanes, background+atlas, display_beats=%0d, stalled DDR and ordered readback",DEPTH,display_checked);
 $finish;
end
initial begin #100000000;$fatal(1,"upload timeout");end
endmodule
