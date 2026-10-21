`timescale 1ns/1ps
// Real normal-mode FIFO -> unpack -> original CVO -> related-clock serializer.
// Distinct X bytes are discarded, while R/G/B must retain their channels.
module tb_rgb_display;
localparam WIDTH=64,HEIGHT=8;
localparam [31:0] P0=32'haaff0000,P1=32'hbb00ff00;
localparam [31:0] P2=32'hcc0000ff,P3=32'hdd123456;
reg pixel_clk=0,pair_clk=0,wr_clk=0,rst_n=0;
always #3.367 pixel_clk=~pixel_clk;
always @(posedge pixel_clk) pair_clk<=~pair_clk;
always #10 wr_clk=~wr_clk;
wire period;
reg period_d=0;
always @(posedge pair_clk) period_d<=period;
wire fifo_reset=!rst_n || (period && !period_d);
integer written=0;
wire fifo_full,fifo_empty,fifo_read;
wire [127:0] fifo_data;
wire source_valid=rst_n && !period && written<WIDTH*HEIGHT/4;
always @(posedge wr_clk or posedge fifo_reset)
    if(fifo_reset) written<=0;
    else if(source_valid && !fifo_full) written<=written+1;
DC_FIFO #(.DATA_WIDTH(128),.FIFO_DEPTH(1024)) source_fifo (
    .Reset(fifo_reset),.WrClk(wr_clk),.WrEn(source_valid),
    .WrData({P3,P2,P1,P0}),.WrFull(fifo_full),
    .RdClk(pair_clk),.RdEn(fifo_read),.RdData(fifo_data),.RdEmpty(fifo_empty));
wire [63:0] axis_data,cvo_data;
wire axis_valid,axis_ready,axis_user,axis_last;
wire cvo_vs,cvo_hs,cvo_de,underflow;
rgb_unpack128_to64 #(.FRAME_WIDTH(WIDTH),.FRAME_HEIGHT(HEIGHT)) unpack (
    .clk(pair_clk),.rst_n(rst_n),.frame_period(period),
    .fifo_data(fifo_data),.fifo_empty(fifo_empty),.fifo_read(fifo_read),
    .m_axis_tdata(axis_data),.m_axis_tvalid(axis_valid),.m_axis_tready(axis_ready),
    .m_axis_tuser(axis_user),.m_axis_tlast(axis_last));
cvo_axi #(.SYMBOL_WIDTH(8),.SYMBOL_NUM(4),.PIXEL_NUM(2),
    .HSYNC_POL(1),.VSYNC_POL(1),.FIFO_DEPTH(1024),.FIFO_ALMOST_FULL(1000),
    .MAX_H_VALID(WIDTH),.MAX_V_VALID(HEIGHT)) cvo (
    .o_clk(pair_clk),.rst_n(rst_n),.fifo_rd_period(period),.fifo_rd_underflow(underflow),
    .s_axi_clk(pair_clk),.s_axis_tdata(axis_data),.s_axis_tvalid(axis_valid),
    .s_axis_tready(axis_ready),.s_axis_tuser(axis_user),.s_axis_tlast(axis_last),
    .H_FRONT_PORCH(13'd8),.H_SYNC(13'd8),.H_VALID(13'd64),.H_BACK_PORCH(13'd8),
    .V_FRONT_PORCH(13'd2),.V_SYNC(13'd2),.V_VALID(13'd8),.V_BACK_PORCH(13'd12),
    .vout(cvo_data),.o_vs(cvo_vs),.o_hs(cvo_hs),.o_de(cvo_de));
wire [7:0] red,green,blue;
wire vs,hs,de;
rgb_to_hdmi serialize (
    .pair_clk(pair_clk),.pixel_clk(pixel_clk),.rst_n(rst_n),
    .pair_data(cvo_data),.pair_vs(cvo_vs),.pair_hs(cvo_hs),.pair_de(cvo_de),
    .red(red),.green(green),.blue(blue),.vs(vs),.hs(hs),.de(de));
integer pixels=0,line_pixels=0,lines=0,complete_frames=0;
reg old_vs=0,old_de=0;
reg [23:0] expected;
always @(posedge pixel_clk) begin
    #0.1;
    if(rst_n) begin
        if(underflow) $fatal(1,"RGB CVO underflow");
        if(vs && !old_vs) begin
            if(pixels!=0) begin
                if(pixels!=WIDTH*HEIGHT || lines!=HEIGHT) $fatal(1,"Display frame dimensions: %0d/%0d",pixels,lines);
                complete_frames=complete_frames+1;
                if(complete_frames==3) begin
                    $display("PASS RGB display: P0/P1/P2/P3, 128->64, CVO, 74.25->148.5 MHz, X discarded, RGB channels, three frames");
                    $finish;
                end
            end
            pixels=0;lines=0;
        end
        if(de) begin
            case(pixels%4)
                0:expected=P0[23:0]; 1:expected=P1[23:0];
                2:expected=P2[23:0]; 3:expected=P3[23:0];
            endcase
            if({red,green,blue}!==expected) $fatal(1,"HDMI pixel %0d got %h expected %h",pixels,{red,green,blue},expected);
            pixels=pixels+1;line_pixels=line_pixels+1;
        end else if(old_de) begin
            if(line_pixels!=WIDTH) $fatal(1,"Display DE width %0d",line_pixels);
            line_pixels=0;lines=lines+1;
        end
        old_vs=vs;old_de=de;
    end
end
initial begin repeat(20) @(negedge wr_clk);rst_n=1;end
initial begin #500000; $fatal(1,"Display timeout pixels=%0d frames=%0d",pixels,complete_frames);end
endmodule
