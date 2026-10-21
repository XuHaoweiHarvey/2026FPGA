`timescale 1ns/1ps
// One-shot TPG, real legacy engines and shared mock DDR, APB registers,
// accelerator, CVO and serializer. No CPU or encrypted-controller simulation.
module tb_checkpoint_c;
parameter WIDTH=512, HEIGHT=64, INIT_ONLY=0, APB_WAITS=1;
localparam BEATS=WIDTH*HEIGHT/4;
localparam SLOT_BEATS=BEATS+32;
reg axi_clk=0, i_clk=0, o_clk=0, rst_n=0;
always #5 axi_clk=~axi_clk;
always #10 i_clk=~i_clk;
reg pixel_clk=0;
always #3.367 pixel_clk=~pixel_clk;
always @(posedge pixel_clk) o_clk<=~o_clk;
wire frame_start,source_de,period,source_done;
reg apb_reset=0;
reg [31:0] paddr=0,pwdata=0;
reg psel=0,penable=0,pwrite=0;
wire [31:0] prdata;wire pready,pslverror;
wire init_done,busy,done,start;
wire [31:0] init_error,engine_error,commands,beats,aws,lasts,bs,reserved;
wire [31:0] cx,cy,cw,ch,cc;
accel_regs #(.ENGINE_ENABLE(1),.WAIT_CYCLES(APB_WAITS)) regs (
 .PCLK(axi_clk),.PRESETn(apb_reset),.PADDR(paddr),.PWDATA(pwdata),.PSEL(psel),.PENABLE(penable),.PWRITE(pwrite),
 .PRDATA(prdata),.PREADY(pready),.PSLVERROR(pslverror),.display_buffer_base(32'b0),.tpg_write_buffer_base(32'b0),
 .init_done(init_done),.init_error(init_error),.engine_busy(busy),.engine_done(done),.engine_error(engine_error),
 .command_count(commands),.init_data_beats(beats),.init_aw_bursts(aws),.init_wlast_bursts(lasts),.init_b_responses(bs),
 .init_aw_beats(reserved),.cmd_x(cx),.cmd_y(cy),.cmd_width(cw),.cmd_height(ch),.cmd_color(cc),.start_pulse(start));
wire [127:0] vin;
wire [31:0] tpg_frames;
rgb_tpg #(.H_ACTIVE(WIDTH),.V_ACTIVE(HEIGHT),.H_BLANK_CYCLES(INIT_ONLY?320:95),.V_BLANK_LINES(INIT_ONLY?170:10),.ONE_FRAME(1)) tpg (
 .clk(i_clk),.rst_n(rst_n),.data(vin),.de(source_de),.frame_start(frame_start),.frame_count(tpg_frames),.source_done(source_done));
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
reg stall_aw=0;
wire awready=!write_active && !bvalid && !stall_aw && ticks%5!=0;
wire wready=write_active && (!read_active || ticks%2==0);
wire arready=!read_active && !rvalid && ticks%3!=0;
wire [63:0] axis_data;
wire axis_valid,axis_last,axis_user,full;
wire axis_ready;
wire [1:0] wr_bank,rd_bank;
rgb_framebuffer #(.FRAME_WIDTH(WIDTH),.FRAME_HEIGHT(HEIGHT),.WR_FIFO_DEPTH(INIT_ONLY?1024:256),.RD_FIFO_DEPTH(INIT_ONLY?1024:256),.C_MODE(1)) dut (
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
    .source_done(source_done),.bresp(2'b0),.cmd_start(start),.cmd_x(cx),.cmd_y(cy),.cmd_width(cw),.cmd_height(ch),.cmd_color(cc),
    .init_done(init_done),.init_error(init_error),.engine_busy(busy),.engine_done(done),.engine_error(engine_error),.command_count(commands),
    .init_data_beats(beats),.init_aw_bursts(aws),.init_wlast_bursts(lasts),.init_b_responses(bs),.init_aw_beats(reserved),
    .diag_wr_fifo_full(full),.diag_wr_bank(wr_bank),.diag_rd_bank(rd_bank));
reg [127:0] memory [0:BEATS-1];
reg final_b_pending=0,release_final_b=0;
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
        if(final_b_pending && release_final_b) begin bvalid<=1;final_b_pending<=0;end
        if(init_error || engine_error) $fatal(1,"C error init=%h engine=%h",init_error,engine_error);
        if(arvalid && !init_done) $fatal(1,"display read before INIT_DONE");
        if(bvalid && bready) begin bvalid<=0; b_count<=b_count+1; end
        if(awvalid && awready) begin
            if(awsize!=4 || awburst!=1 || awaddr[3:0]!=0 ||
                awaddr[11:0]+(awlen+1)*16>4096) $fatal(1,"Bad AW burst/alignment");
            if(awaddr/16>=BEATS) $fatal(1,"AW outside mock DDR");
            write_active<=1; w_index<=awaddr/16; w_left<=awlen+1;
            aw_count<=aw_count+1;
        end
        if(wvalid && wready) begin
            if((!init_done && (wstrb!==16'hffff || wdata!=={4{write_color}})) || wlast!==(w_left==1))
                $fatal(1,"AXI at beat %0d data=%h expected=%h strb=%h last=%b left=%0d index=%0d",w_beats,wdata,{4{write_color}},wstrb,wlast,w_left,w_index);
            for(lane=0;lane<16;lane=lane+1)
                if(wstrb[lane]) memory[w_index][lane*8+:8]<=wdata[lane*8+:8];
            w_index<=w_index+1; w_left<=w_left-1; w_beats<=w_beats+1;
            if(w_left==1) begin
                write_active<=0;
                if(!init_done && w_beats==BEATS-1) final_b_pending<=1;
                else bvalid<=1;
            end
        end
        if(arvalid && arready) begin
            if(arsize!=4 || arburst!=1 || araddr[3:0]!=0 ||
                araddr[11:0]+(arlen+1)*16>4096 || araddr/16>=BEATS)
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
reg old_de=0,old_vs=0,checking=0,draw_finished=0;
reg [23:0] color;
always @(posedge pixel_clk) begin
 #0.1;
 if(rst_n) begin
  if(vs && !old_vs) begin
   if(checking) begin
    if(y!=HEIGHT) $fatal(1,"C frame rows=%0d",y);
    frames=frames+1;
    if(frames==3) begin
     $display("PASS C end-to-end: one-frame TPG, delayed last B, fixed slot0, APB snapshot, debug reset during AW stall, rectangle DDR and HDMI (%0d pixels)",checked_pixels);
     $finish;
    end
   end
   checking=draw_finished;x=0;y=0;
  end
  if(checking && underflow) $fatal(1,"C steady display underflow");
  if(de) begin
   case(x/(WIDTH/4))
    0:color=24'hff0000;1:color=24'h00ff00;2:color=24'h0000ff;default:color=24'hffffff;
   endcase
   if(x>=3 && x<76 && y>=11 && y<30) color=24'h17a4e9;
   if(checking && {red,green,blue}!==color)
    $fatal(1,"C HDMI pixel x=%0d y=%0d got=%h expected=%h",x,y,{red,green,blue},color);
   if(checking) checked_pixels=checked_pixels+1;
   x=x+1;
  end else if(old_de) begin
   if(checking && x!=WIDTH) $fatal(1,"C line pixels=%0d",x);
   x=0;y=y+1;
  end
  old_de=de;old_vs=vs;
 end
end
// This APB master deliberately never simulates the Sapphire CPU.
task access;
input integer address,write_access,value,expected_error;
begin
 @(negedge axi_clk);paddr=address;pwrite=write_access;pwdata=value;psel=1;penable=0;
 @(negedge axi_clk);penable=1;#1;
 while(!pready) begin @(negedge axi_clk);#1;end
 if(pslverror!==expected_error[0]) $fatal(1,"C APB error addr=%h actual=%b",address,pslverror);
 @(negedge axi_clk);psel=0;penable=0;
end endtask
integer k,pixel_index;
reg [31:0] expected;
initial begin
 wait(apb_reset);access(8,1,1,1);
 if(start || init_done || commands) $fatal(1,"START before INIT_DONE accepted");
 wait(final_b_pending);repeat(80) @(negedge axi_clk);
 if(init_done || beats!=BEATS || aws!=lasts || bs!=aws-1 || tpg_frames!=1)
  $fatal(1,"incorrect early handoff beat=%d AW=%d last=%d B=%d",beats,aws,lasts,bs);
 release_final_b=1;wait(init_done);repeat(10) @(negedge axi_clk);
 if(beats!=BEATS || reserved!=BEATS || aws!=lasts || aws!=bs || aws==BEATS || dut.diag_rd_base!=0 || dut.diag_wr_base!=0)
  $fatal(1,"initialization counters/slot mismatch");
 if(INIT_ONLY) begin
  $display("PASS C full geometry initialization: %0d beats, %0d bursts, one frame, all B complete before permanent handoff",beats,aws);
  $finish;
 end
 access(4,0,0,0);if(prdata!==32'h00020000) $fatal(1,"C VERSION");
 access('h44,0,0,0);if(prdata!=BEATS) $fatal(1,"C data beat CSR");
 access('h48,0,0,0);if(prdata!=aws) $fatal(1,"C burst CSR");
 access('h24,0,0,0);if(prdata!=4) $fatal(1,"early START error missing");
 access('h44,1,99,1);access('h24,0,0,0);if(prdata!=3) $fatal(1,"C RO not protected");
 access('h60,0,0,1);if(prdata!=0) $fatal(1,"unmapped C read data");
 access('h24,0,0,0);if(prdata!=2) $fatal(1,"C invalid address error");
 access('h45,1,1,1);access('h24,0,0,0);if(prdata!=1) $fatal(1,"C misalignment priority");
 access(8,1,2,0);access('h0c,0,0,0);if(prdata!=32'h18) $fatal(1,"C clear error/status");
 access('h10,1,3,0);access('h14,1,11,0);access('h18,1,73,0);access('h1c,1,19,0);access('h20,1,'h0017a4e9,0);
 stall_aw=1;access(8,1,1,0);wait(busy);
 access(8,1,1,1); // Busy command must not retrigger.
 // Snapshot survives register writes and an actual APB/CPU island reset.
 access('h20,1,'h00ff0000,0);
 wait(awvalid);@(negedge axi_clk);apb_reset=0;
 repeat(12) @(negedge axi_clk);
 if(!busy || !awvalid || !init_done || commands!=1 || tpg_frames!=1) $fatal(1,"debug reset corrupted active DMA/ownership");
 apb_reset=1;stall_aw=0;
 wait(done);@(negedge axi_clk);
 if(busy || engine_error || commands!=1 || aw_count!=b_count || aws!=bs || tpg_frames!=1) $fatal(1,"C completion not drained");
 for(k=0;k<WIDTH*HEIGHT;k=k+1) begin
  case((k%WIDTH)/(WIDTH/4))
   0:expected=32'h00ff0000;1:expected=32'h0000ff00;2:expected=32'h000000ff;default:expected=32'h00ffffff;
  endcase
  if(k%WIDTH>=3 && k%WIDTH<76 && k/WIDTH>=11 && k/WIDTH<30) expected=32'h0017a4e9;
  if(memory[k/4][(k%4)*32+:32]!==expected) $fatal(1,"C DDR pixel %0d",k);
 end
 draw_finished=1;
end
always @(posedge i_clk) if(source_de && full) $fatal(1,"pipeline writer overflow");
initial begin
 for(j=0;j<BEATS;j=j+1) memory[j]=0;
 repeat(20) @(negedge i_clk);rst_n=1;apb_reset=1;
end
initial begin #(INIT_ONLY ? 40000000 : 3000000); $fatal(1,"pipeline timeout tpg=%0d checked=%0d",tpg_frames,frames);end
endmodule
