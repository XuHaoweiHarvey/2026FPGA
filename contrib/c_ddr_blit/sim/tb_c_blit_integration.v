`timescale 1ns/1ps
// Simulation adapter ONLY: the prototype lacks src_range_valid. A one-cycle
// queue feeds the accepted snapshot and converts invalid range to width=0.
// Production B must check src_range_valid in its common execution CHECK state.
module tb_c_blit_integration;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,start=0,queued=0,swap_request=0,boundary_tick=0;
reg [31:0] src_addr=0,src_stride=7680;
wire accept,owned,range_ok,busy,done,read_fault;
wire [31:0] error,count,front_base,command_base,absolute_awaddr;
wire [31:0] qsrc,qstride,qwidth,qheight,qx,qy;
wire [31:0] awaddr;wire [7:0] awlen;
wire awvalid,wvalid,wlast,bready;
wire [127:0] wdata;wire [15:0] wstrb;
reg bvalid=0;reg [31:0] cycle=0;
wire awready=(cycle%4)!=0,wready=(cycle%3)!=0;
wire [31:0] b_araddr;wire [7:0] b_arlen;
wire b_arvalid,b_arready,b_rvalid,b_rready,b_rlast;
wire [127:0] b_rdata;wire [3:0] b_rid;wire [1:0] b_rresp;
wire [31:0] m_araddr;wire [7:0] m_arlen;
wire m_arvalid,m_rready;
wire m_arready=(cycle%5)!=0;
reg [127:0] m_rdata=0;reg m_rvalid=0,m_rlast=0;
wire d_arready,d_rvalid,d_rlast;
wire [127:0] d_rdata;
reg d_pending=0;
wire d_arvalid=rst_n && !d_pending;
wire [31:0] display_bursts,blit_bursts;
reg [31:0] expected_source=0,expected_back=32'h800000;
integer read_left=0,write_left=0,writes=0,display_reads=0;
reg [31:0] read_cursor=0,write_cursor=0;
function [127:0] pattern;
input [31:0] address;
begin pattern={(address+32'd12)^32'h12345678,(address+32'd8)^32'h12345678,
               (address+32'd4)^32'h12345678,address^32'h12345678};end
endfunction
always @(posedge clk) begin
 if(!rst_n) queued<=0;else queued<=accept;
end
c_command_service command_service(
 .clk(clk),.rst_n(rst_n),.init_done(rst_n),.op(32'd1),.x(32'd64),.y(32'd64),
 .width(32'd32),.height(32'd32),.color(32'd0),.src_addr(src_addr),.src_stride(src_stride),
 .start(start),.accept(accept),.src_range_valid(range_ok),
 .writer_busy(busy || queued),.writer_done(done),.writer_error(error),.read_fault(read_fault),
 .swap_request(swap_request),.clear_done(1'b0),.boundary_tick(boundary_tick),.blank_active(1'b1),
 .reader_safe(!d_pending),.reader_fifo_empty(1'b1),.writer_owned(owned),
 .front_base(front_base),.command_base(command_base),.relative_awaddr(awaddr),.absolute_awaddr(absolute_awaddr),
 .accepted_src_addr(qsrc),.accepted_src_stride(qstride),.accepted_width(qwidth),.accepted_height(qheight),
 .accepted_x(qx),.accepted_y(qy));
blit_engine engine(
 .clk(clk),.rst_n(rst_n),.enabled(rst_n),.start(queued),.src_addr(qsrc),.src_stride(qstride),
 .dst_x(qx),.dst_y(qy),.width(range_ok?qwidth:32'd0),.height(qheight),
 .busy(busy),.done(done),.error_code(error),.command_count(count),
 .araddr(b_araddr),.arlen(b_arlen),.arvalid(b_arvalid),.arready(b_arready),
 .rdata(b_rdata),.rid(b_rid),.rresp(b_rresp),.rlast(b_rlast),.rvalid(b_rvalid),.rready(b_rready),
 .awaddr(awaddr),.awlen(awlen),.awvalid(awvalid),.awready(awready),.wdata(wdata),.wstrb(wstrb),
 .wlast(wlast),.wvalid(wvalid),.wready(wready),.bid(4'd0),.bresp(2'd0),.bvalid(bvalid),.bready(bready));
c_axi_read_arbiter arbiter(
 .clk(clk),.rst_n(rst_n),.display_urgent(1'b0),.external_fault(error==32'h25),
 .d_araddr(32'h10000),.d_arlen(8'd7),.d_arvalid(d_arvalid),.d_arready(d_arready),
 .d_rdata(d_rdata),.d_rvalid(d_rvalid),.d_rready(1'b1),.d_rlast(d_rlast),
 .b_araddr(b_araddr),.b_arlen(b_arlen),.b_arvalid(b_arvalid),.b_arready(b_arready),
 .b_rdata(b_rdata),.b_rid(b_rid),.b_rresp(b_rresp),.b_rlast(b_rlast),.b_rvalid(b_rvalid),.b_rready(b_rready),
 .m_araddr(m_araddr),.m_arlen(m_arlen),.m_arvalid(m_arvalid),.m_arready(m_arready),
 .m_rdata(m_rdata),.m_rid(4'd0),.m_rresp(2'd0),.m_rlast(m_rlast),.m_rvalid(m_rvalid),.m_rready(m_rready),
 .fault(read_fault),.display_bursts(display_bursts),.blit_bursts(blit_bursts));
always @(posedge clk) if(rst_n) begin
 cycle<=cycle+1;
 if(d_arvalid && d_arready) begin d_pending<=1;display_reads<=0;end
 if(d_rvalid) begin
   if(d_rdata!==pattern(32'h10000+display_reads*16)) $fatal(1,"BLIT data leaked to display");
   display_reads<=display_reads+1;
   if(d_rlast) d_pending<=0;
 end
 if(m_arvalid && m_arready) begin
   if(read_left!=0) $fatal(1,"multiple outstanding");
   read_left<=m_arlen+1;read_cursor<=m_araddr;
 end
 if(!m_rvalid && read_left>0 && cycle%3!=0) begin
   m_rvalid<=1;m_rdata<=pattern(read_cursor);m_rlast<=read_left==1;
 end
 if(m_rvalid && m_rready) begin
   m_rvalid<=0;read_left<=read_left-1;read_cursor<=read_cursor+16;
 end
 if(awvalid && awready) begin
   if(!owned || write_left!=0 || bvalid) $fatal(1,"write ownership/outstanding");
   if(absolute_awaddr!==expected_back+(64+writes/8)*7680+256+(writes%8)*16)
     $fatal(1,"wrong Back write address");
   write_left<=awlen+1;write_cursor<=absolute_awaddr;
 end
 if(wvalid && wready) begin
   if(write_left<1 || !owned || wstrb!=16'hffff || wlast!=(write_left==1)) $fatal(1,"write framing");
   if(wdata!==pattern(expected_source+(writes/8)*7680+(writes%8)*16)) $fatal(1,"pixel scoreboard mismatch");
   write_left<=write_left-1;write_cursor<=write_cursor+16;writes<=writes+1;
   if(wlast) bvalid<=1;
 end
 if(bvalid && bready) bvalid<=0;
 if(read_fault) $fatal(1,"unexpected shared read fault");
end
task submit;
input [31:0] next_count;
begin
 @(negedge clk);start=1;#1;if(!accept) $fatal(1,"integration accept");
 @(negedge clk);start=0;
 wait(count==next_count);wait(done && !busy && !queued && !owned);#1;
end endtask
integer saved_blit;
initial begin
 repeat(3) @(negedge clk);rst_n=1;repeat(3) @(negedge clk);
 submit(1);
 if(error!=0 || writes!=256 || display_bursts==0 || blit_bursts<32) $fatal(1,"copy result");
 saved_blit=blit_bursts;
 @(negedge clk);src_addr=7680-16; // would cross a source row
 submit(2);
 if(error!=32'h21 || writes!=256 || blit_bursts!=saved_blit) $fatal(1,"invalid range accessed DDR");
 $display("PASS C+B integration: 1024 pixels checked, concurrent display, AXI stalls, invalid range emits no BLIT AR/AW");
 $finish;
end
initial begin #2000000;$fatal(1,"integration timeout");end
endmodule
