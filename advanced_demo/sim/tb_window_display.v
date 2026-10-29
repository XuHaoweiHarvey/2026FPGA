`timescale 1ns/1ps
// Full resolution, asynchronous clocks, shared reads, random stalls and swap.
module tb_window_display #(parameter REAL_CVO=0);
reg clk=0,video_clk=0,pixel_clk=0,rst_n=0,manual_period=1,manual_boundary=0,request=0;
wire period,boundary,blank;
always #5 clk=~clk;
always #3.367 pixel_clk=~pixel_clk;
always @(posedge pixel_clk) video_clk<=~video_clk;
reg [31:0] rng=32'h56ad1329;
always @(posedge clk) rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
wire [31:0] base,front,back;
wire flush,launch,safe,active,idle,empty,write_empty;
wire [31:0] level,outstanding,data_beats,reserved,error_code,swaps,missed;
wire [31:0] da,ma;wire [7:0] dl,ml;wire dv,dr,rv,rr,rl;
wire [127:0] rd,fifo_data;
wire fifo_read;
wire [63:0] axis_data;wire axis_valid,axis_user,axis_last;
wire axis_ready,cvo_ready,cvo_period;
assign axis_ready=REAL_CVO ? cvo_ready : rng[2] || rng[3];
assign period=REAL_CVO ? cvo_period : manual_period;
generate if(REAL_CVO) begin : real_timing
    video_frame_cdc cdc (
        .video_clk(video_clk),.video_rst_n(rst_n),.video_period(period),
        .core_clk(clk),.core_rst_n(rst_n),.boundary_tick(boundary),.blank_active(blank));
end else begin : manual_timing
    assign boundary=manual_boundary;
    assign blank=manual_period;
end endgenerate
reg ba_valid=0;wire ba_ready,br_valid;
reg [8:0] blit_left=0;
wire arb_fault;
buffer_manager manager (
    .clk(clk),.rst_n(rst_n),.init_done(1'b1),.cmd_request(1'b0),
    .writer_busy(1'b0),.writer_done(1'b0),.writer_error(32'b0),
    .swap_request(request),.clear_done(1'b0),.boundary_tick(boundary),
    .blank_active(blank),.reader_safe(safe),.reader_fifo_empty(write_empty),
    .front_base(front),.back_base(back),.reader_base(base),.reader_flush(flush),
    .reader_launch(launch),.swap_count(swaps),.missed_boundary_count(missed));
window_display_reader reader (
    .clk(clk),.rst_n(rst_n),.start(launch),.flush(flush),.frame_base(base),
    .video_clk(video_clk),.fifo_read(fifo_read),.fifo_data(fifo_data),.fifo_empty(empty),
    .idle(idle),.fifo_write_empty(write_empty),.fifo_level(level),
    .araddr(da),.arlen(dl),.arvalid(dv),.arready(dr),
    .rdata(rd),.rvalid(rv),.rlast(rl),.rready(rr));
read_frame_guard #(.FRAME_BEATS(76800),.STRIDED(1)) guard (
    .clk(clk),.rst_n(rst_n),.launch(launch),.frame_base(base),.reader_idle(idle),
    .araddr(da),.arlen(dl),.arsize(3'd4),.arburst(2'd1),.arvalid(dv),.arready(dr),
    .rvalid(rv),.rready(rr),.rlast(rl),.rid(4'b0),.rresp(2'b0),
    .safe(safe),.active(active),.outstanding(outstanding),.data_beats(data_beats),
    .reserved_beats(reserved),.error_code(error_code));
window_axis_composer composer (
    .clk(video_clk),.rst_n(rst_n),.frame_period(period),.fifo_data(fifo_data),
    .fifo_empty(empty),.fifo_read(fifo_read),.m_axis_tdata(axis_data),
    .m_axis_tvalid(axis_valid),.m_axis_tready(axis_ready),
    .m_axis_tuser(axis_user),.m_axis_tlast(axis_last));
wire mv,mr;
reg [31:0] mem_address=0;
reg [8:0] mem_left=0;
// Saturated back writer competes for this bounded DDR service model.
// Each admitted transaction owns up to 32 data cycles plus its response.
wire admit;
wire [31:0] writer_bursts,throttle_cycles;
reg [6:0] write_left=0;
wire write_response=write_left==1;
wire write_ready=write_left==0 && mem_left==0 && rng[5];
ddr_write_admission #(.WINDOW_MODE(1)) admission (
    .clk(clk),.rst_n(rst_n),.enabled(1'b1),.raw_awvalid(1'b1),
    .ddr_awready(write_ready),.bvalid(write_response),.bready(1'b1),
    .reader_active(active),.reader_safe(safe),.reader_launch(launch),.fifo_flush(flush),
    .fifo_level(level),.reader_error(error_code),.arvalid(dv),.arready(dr),
    .rvalid(rv),.rready(rr),.reader_outstanding(outstanding),.admit_aw(admit),
    .writer_bursts(writer_bursts),.throttle_cycles(throttle_cycles));
wire writing=write_left!=0;
wire mem_valid=mem_left!=0 && rng[0] && !writing;
wire mem_last=mem_left==1;
wire mem_accept=mem_valid && mr;
wire mem_arready=mem_left==0 && rng[1] && !writing && !(admit && write_ready);
function [31:0] pixel;
    input [31:0] address;
    begin pixel=(address>=32'h00800000 ? 32'h40000000 : 32'h10000000) |
                ((address & 32'h007fffff)>>2);end
endfunction
wire [127:0] mem_data={pixel(mem_address+12),pixel(mem_address+8),
                       pixel(mem_address+4),pixel(mem_address)};
ddr_read_arbiter arbiter (
    .clk(clk),.rst_n(rst_n),.enabled(1'b1),.display_active(active),
    .display_launch(launch),.display_flush(flush),.display_fifo_level(level),
    .display_araddr(da),.display_arlen(dl),.display_arvalid(dv),.display_arready(dr),
    .display_rdata(rd),.display_rlast(rl),.display_rvalid(rv),.display_rready(rr),
    .blit_araddr(32'h01384000),.blit_arlen(8'd7),
    .blit_arvalid(ba_valid),.blit_arready(ba_ready),
    .blit_rvalid(br_valid),.blit_rready(1'b1),
    .araddr(ma),.arlen(ml),.arvalid(mv),.arready(mem_arready),
    .rdata(mem_data),.rid(4'b0),.rresp(2'b0),.rlast(mem_last),
    .rvalid(mem_valid),.rready(mr),.fault(arb_fault));
integer display_reads=0,blit_reads=0;
always @(posedge clk) if(rst_n) begin
    if(admit && write_ready) write_left<=33;
    else if(write_left!=0 && (rng[4] || write_response)) write_left<=write_left-1'b1;
    if(mv && mem_arready) begin mem_address<=ma;mem_left<={1'b0,ml}+1'b1;end
    if(mem_accept) begin mem_address<=mem_address+16;mem_left<=mem_left-1'b1;end
    if(!ba_valid && blit_left==0 && rng[6]) ba_valid<=1;
    if(ba_valid && ba_ready) begin ba_valid<=0;blit_left<=8;blit_reads<=blit_reads+1;end
    if(br_valid) blit_left<=blit_left-1'b1;
    if(dv && dr) begin
        display_reads<=display_reads+1;
        if(((da & 32'h007fffff)/7680)<300 || ((da & 32'h007fffff)/7680)>=780 ||
           ((da & 32'h007fffff)%7680)<2560 ||
           ((da & 32'h007fffff)%7680)+(dl+1)*16>5120)
            $fatal(1,"Read outside the viewport");
    end
    if(error_code!=0 || arb_fault) $fatal(1,"Read guard/arbiter error %h",error_code);
end
integer display_frames=0,display_pixels=0,line_pixels=0,display_lines=0;
reg old_vs=0,old_de=0;
reg [23:0] rgb_expected;
generate if(REAL_CVO) begin : real_display
    wire [63:0] cvo_data;
    wire cvo_vs,cvo_hs,cvo_de,underflow;
    wire [7:0] red,green,blue;
    wire vs,hs,de;
    cvo_axi #(.SYMBOL_WIDTH(8),.SYMBOL_NUM(4),.PIXEL_NUM(2),
        .HSYNC_POL(1),.VSYNC_POL(1),.FIFO_DEPTH(1024),.FIFO_ALMOST_FULL(1000),
        .MAX_H_VALID(1920),.MAX_V_VALID(1080)) cvo (
        .o_clk(video_clk),.rst_n(rst_n),.fifo_rd_period(cvo_period),.fifo_rd_underflow(underflow),
        .s_axi_clk(video_clk),.s_axis_tdata(axis_data),.s_axis_tvalid(axis_valid),
        .s_axis_tready(cvo_ready),.s_axis_tuser(axis_user),.s_axis_tlast(axis_last),
        .H_FRONT_PORCH(13'd88),.H_SYNC(13'd44),.H_VALID(13'd1920),.H_BACK_PORCH(13'd148),
        .V_FRONT_PORCH(13'd4),.V_SYNC(13'd5),.V_VALID(13'd1080),.V_BACK_PORCH(13'd36),
        .vout(cvo_data),.o_vs(cvo_vs),.o_hs(cvo_hs),.o_de(cvo_de));
    rgb_to_hdmi serializer (
        .pair_clk(video_clk),.pixel_clk(pixel_clk),.rst_n(rst_n),
        .pair_data(cvo_data),.pair_vs(cvo_vs),.pair_hs(cvo_hs),.pair_de(cvo_de),
        .red(red),.green(green),.blue(blue),.vs(vs),.hs(hs),.de(de));
    always @(posedge pixel_clk) begin
        #0.1;
        if(rst_n) begin
            if(underflow) $fatal(1,"Window CVO underflow during write/read pressure");
            if(vs && !old_vs) begin
                if(display_pixels!=0) begin
                    if(display_pixels!=1920*1080 || display_lines!=1080)
                        $fatal(1,"Incorrect full HDMI dimensions %0d/%0d",display_pixels,display_lines);
                    display_frames=display_frames+1;
                end
                display_pixels=0;display_lines=0;
            end
            if(de) begin
                rgb_expected=0;
                if(line_pixels>=640 && line_pixels<1280 && display_lines>=300 && display_lines<780)
                    rgb_expected=pixel((display_frames==0 ? 0 : 32'h00800000)+
                                       display_lines*7680+line_pixels*4);
                if({red,green,blue}!==rgb_expected)
                    $fatal(1,"HDMI mismatch frame%0d (%0d,%0d) got %h expected %h",
                        display_frames,line_pixels,display_lines,{red,green,blue},rgb_expected);
                display_pixels=display_pixels+1;line_pixels=line_pixels+1;
            end else if(old_de) begin
                if(line_pixels!=1920) $fatal(1,"HDMI active line width %0d",line_pixels);
                line_pixels=0;display_lines=display_lines+1;
            end
            old_vs=vs;old_de=de;
        end
    end
end endgenerate
integer pairs=0,frames=0,x,y;
reg [31:0] expected0,expected1;
reg held=0;reg [65:0] saved;
always @(posedge video_clk) if(rst_n && !period) begin
    if(held && {axis_user,axis_last,axis_data}!==saved)
        $fatal(1,"AXIS payload changed during backpressure");
    held<=axis_valid && !axis_ready;
    saved<={axis_user,axis_last,axis_data};
    if(axis_valid && axis_ready) begin
        x=(pairs%960)*2;y=pairs/960;
        expected0=0;expected1=0;
        if(x>=640 && x<1280 && y>=300 && y<780) begin
            expected0=pixel((frames==0 ? 0 : 32'h00800000)+y*7680+x*4);
            expected1=pixel((frames==0 ? 0 : 32'h00800000)+y*7680+(x+1)*4);
        end
        if(axis_data!=={expected1,expected0} || axis_user!==(pairs==0) ||
           axis_last!==(x==1918))
            $fatal(1,"Pixel/framing mismatch frame%0d (%0d,%0d): %h expected %h",
                   frames,x,y,axis_data,{expected1,expected0});
        if(pairs==1036799) begin pairs<=0;frames<=frames+1;end
        else pairs<=pairs+1;
    end
end
task frame_boundary;
    begin
        @(negedge video_clk);manual_period=1;
        repeat(6) @(negedge clk);
        manual_boundary=1;@(negedge clk);manual_boundary=0;
        wait(launch);repeat(20) @(negedge clk);
        @(negedge video_clk);manual_period=0;
    end
endtask
initial begin
    repeat(15) @(negedge clk);rst_n=1;
    repeat(15) @(negedge clk);
    if(!REAL_CVO) frame_boundary;
    wait(frames==1);wait(safe);
    if(data_beats!=76800 || reserved!=76800 || level!=0)
        $fatal(1,"Wrong viewport beat count/FIFO not drained");
    @(negedge clk);request=1;@(negedge clk);request=0;
    if(!REAL_CVO) frame_boundary;
    wait(frames==2);wait(safe);
    if(REAL_CVO) wait(display_frames==2);
    if(swaps!=1 || missed!=0 || data_beats!=76800 || blit_reads==0 ||
       writer_bursts<100 || throttle_cycles==0)
        $fatal(1,"Swap/count/competing client check failed");
    $display("PASS two 1080p frames: viewport pixels, black border, 76800 beats/frame, strided/4KiB reads, AXIS stalls, shared reads and safe swap (%0d bursts)",display_reads);
    $display("PASS write pressure: %0d bounded writes, %0d throttle cycles, REAL_CVO=%0d",writer_bursts,throttle_cycles,REAL_CVO);
    $finish;
end
initial begin #100000000;$fatal(1,"Window display timeout");end
endmodule
