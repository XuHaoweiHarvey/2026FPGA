`timescale 1ns/1ps
// Real continuous TPG -> legacy DDR engines -> shared byte-addressed mock
// DDR -> unpack -> CVO -> serializer. Geometry/FIFO sizes are scaled together;
// the test checks color changes across beats and subsequent frame resets.
module tb_rgb_pipeline;
parameter WIDTH=512, HEIGHT=64;
localparam BEATS=WIDTH*HEIGHT/4;
localparam SLOT_BEATS=BEATS+32;
reg axi_clk=0, i_clk=0, o_clk=0, rst_n=0;
always #5 axi_clk=~axi_clk;
always #10 i_clk=~i_clk;
reg pixel_clk=0;
always #3.367 pixel_clk=~pixel_clk;
always @(posedge pixel_clk) o_clk<=~o_clk;
wire frame_start,source_de,period;
wire [127:0] vin;
wire [31:0] tpg_frames;
rgb_tpg #(.H_ACTIVE(WIDTH),.V_ACTIVE(HEIGHT),.H_BLANK_CYCLES(95),.V_BLANK_LINES(10)) tpg (
 .clk(i_clk),.rst_n(rst_n),.data(vin),.de(source_de),.frame_start(frame_start),.frame_count(tpg_frames));
wire [31:0] awaddr,araddr;
wire [7:0] awlen,arlen;
wire [2:0] awsize,arsize;
wire [1:0] awburst,arburst;
wire awvalid,wvalid,wlast,bready,arvalid,rready;
wire [127:0] wdata;
wire [15:0] wstrb;
reg bvalid=0,rvalid=0,rlast=0;
reg [127:0] rdata=0;
reg write_active=0,read_active=0;
integer w_index=0,w_left=0,r_index=0,r_left=0;
integer ticks=0,w_beats=0,r_beats=0,aw_count=0,ar_count=0,b_count=0;
wire awready=!write_active && ticks%5!=0;
wire wready=write_active && (!read_active || ticks%2==0);
wire arready=!read_active && !rvalid && ticks%3!=0;
wire [63:0] axis_data;
wire axis_valid,axis_last,axis_user,full;
wire axis_ready;
wire [1:0] wr_bank,rd_bank;
rgb_framebuffer #(.FRAME_WIDTH(WIDTH),.FRAME_HEIGHT(HEIGHT),.WR_FIFO_DEPTH(256),.RD_FIFO_DEPTH(256)) dut (
    .axi_clk(axi_clk),.rst_n(rst_n),.i_clk(i_clk),.i_frame_start(frame_start),
    .i_de(source_de),.vin(vin),.o_clk(o_clk),.fifo_rd_period(period),
    .m_axis_tdata(axis_data),.m_axis_tvalid(axis_valid),.m_axis_tready(axis_ready),
    .m_axis_tlast(axis_last),.m_axis_tuser(axis_user),
    .awaddr(awaddr),.awlen(awlen),.awsize(awsize),.awburst(awburst),
    .awvalid(awvalid),.awready(awready),.wdata(wdata),.wstrb(wstrb),
    .wlast(wlast),.wvalid(wvalid),.wready(wready),
    .bid(4'b0),.bvalid(bvalid),.bready(bready),
    .araddr(araddr),.arlen(arlen),.arsize(arsize),.arburst(arburst),
    .arvalid(arvalid),.arready(arready),.rid(4'b0),.rdata(rdata),
    .rlast(rlast),.rvalid(rvalid),.rready(rready),.rresp(2'b0),
    .diag_wr_fifo_full(full),.diag_wr_bank(wr_bank),.diag_rd_bank(rd_bank));
reg [127:0] memory [0:3*SLOT_BEATS-1];
integer j,lane;
reg [31:0] write_color;
always_comb begin
 case(((w_index%SLOT_BEATS)%(WIDTH/4))/(WIDTH/16))
  0: write_color=32'h00ff0000; 1: write_color=32'h0000ff00;
  2: write_color=32'h000000ff; default: write_color=32'h00ffffff;
 endcase
end
always @(posedge axi_clk) begin
    if(rst_n) begin
        ticks<=ticks+1;
        if(bvalid && bready) begin bvalid<=0; b_count<=b_count+1; end
        if(awvalid && awready) begin
            if(awsize!=4 || awburst!=1 || awaddr[3:0]!=0 ||
                awaddr[11:0]+(awlen+1)*16>4096) $fatal(1,"Bad AW burst/alignment");
            if(awaddr/16>=3*SLOT_BEATS) $fatal(1,"AW outside mock DDR");
            write_active<=1; w_index<=awaddr/16; w_left<=awlen+1;
            aw_count<=aw_count+1;
        end
        if(wvalid && wready) begin
            if(wstrb!==16'hffff || wdata!=={4{write_color}} || wlast!==(w_left==1))
                $fatal(1,"AXI at beat %0d data=%h expected=%h strb=%h last=%b left=%0d index=%0d",w_beats,wdata,{4{write_color}},wstrb,wlast,w_left,w_index);
            for(lane=0;lane<16;lane=lane+1)
                if(wstrb[lane]) memory[w_index][lane*8+:8]<=wdata[lane*8+:8];
            w_index<=w_index+1; w_left<=w_left-1; w_beats<=w_beats+1;
            if(w_left==1) begin write_active<=0; bvalid<=1; end
        end
        if(arvalid && arready) begin
            if(arsize!=4 || arburst!=1 || araddr[3:0]!=0 ||
                araddr[11:0]+(arlen+1)*16>4096 || araddr/16>=3*SLOT_BEATS)
                $fatal(1,"Bad AR burst");
            read_active<=1; r_index<=araddr/16; r_left<=arlen+1;
            ar_count<=ar_count+1;
        end
        if(rvalid && rready) begin rvalid<=0; r_beats<=r_beats+1; end
        if(read_active && (!rvalid || rready) && !(wvalid && wready)) begin
            rvalid<=1; rdata<=memory[r_index]; rlast<=(r_left==1);
            r_index<=r_index+1; r_left<=r_left-1;
            if(r_left==1) read_active<=0;
        end
    end
end

wire [63:0] cvo_data;
wire cvo_de,cvo_hs,cvo_vs,underflow;
cvo_axi #(.SYMBOL_WIDTH(8),.SYMBOL_NUM(4),.PIXEL_NUM(2),.FIFO_DEPTH(256),.FIFO_ALMOST_FULL(220),
 .MAX_H_VALID(WIDTH),.MAX_V_VALID(HEIGHT)) cvo (
 .o_clk(o_clk),.s_axi_clk(o_clk),.rst_n(rst_n),.fifo_rd_period(period),.fifo_rd_underflow(underflow),
 .s_axis_tdata(axis_data),.s_axis_tvalid(axis_valid),.s_axis_tready(axis_ready),
 .s_axis_tuser(axis_user),.s_axis_tlast(axis_last),
 .H_FRONT_PORCH(13'd24),.H_SYNC(13'd12),.H_VALID(13'd512),.H_BACK_PORCH(13'd40),
 .V_FRONT_PORCH(13'd1),.V_SYNC(13'd1),.V_VALID(13'd64),.V_BACK_PORCH(13'd3),
 .vout(cvo_data),.o_de(cvo_de),.o_hs(cvo_hs),.o_vs(cvo_vs));
wire [7:0] red,green,blue;
wire de,hs,vs;
rgb_to_hdmi serialize (.pair_clk(o_clk),.pixel_clk(pixel_clk),.rst_n(rst_n),
 .pair_data(cvo_data),.pair_de(cvo_de),.pair_hs(cvo_hs),.pair_vs(cvo_vs),
 .red(red),.green(green),.blue(blue),.de(de),.hs(hs),.vs(vs));
integer x=0,y=0,frames=0,checked_pixels=0;
reg old_de=0,old_vs=0,checking=0;
reg [23:0] color;
always @(posedge pixel_clk) begin
 #0.1;
 if(rst_n) begin
  if(vs && !old_vs) begin
   if(checking) begin
    if(y!=HEIGHT) $fatal(1,"pipeline frame rows=%0d",y);
    frames=frames+1;
    if(frames==3) begin
     $display("PASS continuous RGB pipeline: concurrent shared DDR, triple banks, three color-bar frames (%0d pixels)",checked_pixels);
     $finish;
    end
   end
   checking=tpg_frames>=3; x=0;y=0;
  end
  if(checking && underflow) $fatal(1,"pipeline steady underflow");
  if(de) begin
   case(x/(WIDTH/4))
    0:color=24'hff0000;1:color=24'h00ff00;2:color=24'h0000ff;default:color=24'hffffff;
   endcase
   if(checking && {red,green,blue}!==color)
    $fatal(1,"pipeline pixel x=%0d y=%0d got=%h expected=%h wr_bank=%d rd_bank=%d",x,y,{red,green,blue},color,wr_bank,rd_bank);
   if(checking) checked_pixels=checked_pixels+1;
   x=x+1;
  end else if(old_de) begin
   if(checking && x!=WIDTH) $fatal(1,"pipeline line pixels=%0d",x);
   x=0;y=y+1;
  end
  old_de=de;old_vs=vs;
 end
end
always @(posedge i_clk) if(source_de && full) $fatal(1,"pipeline writer overflow");
initial begin
 for(j=0;j<3*SLOT_BEATS;j=j+1) memory[j]=0;
 repeat(20) @(negedge i_clk);rst_n=1;
end
initial begin #3000000; $fatal(1,"pipeline timeout tpg=%0d checked=%0d",tpg_frames,frames);end
endmodule
