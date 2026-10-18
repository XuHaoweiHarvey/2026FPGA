`timescale 1ns/1ps
// One-shot TPG, real legacy engines and shared mock DDR, APB registers,
// accelerator, CVO and serializer. No CPU or encrypted-controller simulation.
module tb_checkpoint_d;
parameter WIDTH=512, HEIGHT=64, APB_WAITS=1, GRAPHICS=0;
localparam INIT_ONLY=0;
localparam BEATS=WIDTH*HEIGHT/4;
reg axi_clk=0, i_clk=0, o_clk=0, rst_n=0;
always #5 axi_clk=~axi_clk;
always #10 i_clk=~i_clk;
reg pixel_clk=0;
always #3.367 pixel_clk=~pixel_clk;
always @(posedge pixel_clk) o_clk<=~o_clk;
wire frame_start,source_de,period,source_done,underflow;
reg apb_reset=0;
reg [31:0] paddr=0,pwdata=0;
reg psel=0,penable=0,pwrite=0;
wire [31:0] prdata;wire pready,pslverror;
wire init_done,busy,done,start,draw_ready,swap_request,clear_swap_done;
wire [31:0] service_status,writer_throttle_cycles,writer_bursts,reader_ar_stall_cycles,reader_ar_max_stall,reader_r_stall_cycles,reader_r_max_stall,display_underflow_count,reader_frame_completions,reader_fifo_level,writer_max_cycles,service_read_quota,service_watermarks;
wire [31:0] buffer_status,reader_frame_base,reader_outstanding,reader_data_beats,reader_reserved_beats,reader_error;
wire [31:0] boundary_count,swap_count,missed_boundary_count,front_base,back_base;
reg inject_late=0,late_held=0,skip_pixels=0;
integer image_tag[0:1];
wire [31:0] init_error,engine_error,commands,beats,aws,lasts,bs,reserved;
wire [31:0] cx,cy,cw,ch,cc;
wire [31:0] cop,csrc,cstride;
accel_regs #(.ENGINE_ENABLE(1),.DOUBLE_BUFFER(1),.BLIT_ENABLE(GRAPHICS),.WAIT_CYCLES(APB_WAITS),
 .FRAME_WIDTH(WIDTH),.FRAME_HEIGHT(HEIGHT),.FRAME_STRIDE(WIDTH*4)) regs (
 .PCLK(axi_clk),.PRESETn(apb_reset),.PADDR(paddr),.PWDATA(pwdata),.PSEL(psel),.PENABLE(penable),.PWRITE(pwrite),
 .PRDATA(prdata),.PREADY(pready),.PSLVERROR(pslverror),.display_buffer_base(front_base),.tpg_write_buffer_base(back_base),
 .init_done(init_done),.init_error(init_error),.engine_busy(busy),.engine_done(done),.engine_error(engine_error),
 .draw_ready(draw_ready),.buffer_status(buffer_status),.swap_request(swap_request),.clear_swap_done(clear_swap_done),
 .service_status(service_status),
 .writer_throttle_cycles(writer_throttle_cycles),
 .writer_bursts(writer_bursts),
 .reader_ar_stall_cycles(reader_ar_stall_cycles),
 .reader_ar_max_stall(reader_ar_max_stall),
 .reader_r_stall_cycles(reader_r_stall_cycles),
 .reader_r_max_stall(reader_r_max_stall),
 .display_underflow_count(display_underflow_count),
 .reader_frame_completions(reader_frame_completions),
 .reader_fifo_level(reader_fifo_level),
 .writer_max_cycles(writer_max_cycles),
 .service_read_quota(service_read_quota),
 .service_watermarks(service_watermarks),
 .reader_frame_base(reader_frame_base),.reader_outstanding(reader_outstanding),.reader_data_beats(reader_data_beats),
 .reader_reserved_beats(reader_reserved_beats),.reader_error(reader_error),.boundary_count(boundary_count),
 .swap_count(swap_count),.missed_boundary_count(missed_boundary_count),
 .command_count(commands),.init_data_beats(beats),.init_aw_bursts(aws),.init_wlast_bursts(lasts),.init_b_responses(bs),
 .init_aw_beats(reserved),.cmd_x(cx),.cmd_y(cy),.cmd_width(cw),.cmd_height(ch),.cmd_color(cc),
 .cmd_op(cop),.cmd_src_addr(csrc),.cmd_src_stride(cstride),.start_pulse(start));
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
reg hold_b=0,force_stray=0;
reg stall_read=0;
reg expect_engine_error=0,expect_read_error=0;
wire routed_bvalid=bvalid && !hold_b;
wire awready=!write_active && !bvalid && !stall_aw && ticks%5!=0;
wire wready=write_active && (!read_active || ticks%2==0);
wire arready=!read_active && !rvalid && !stall_read && ticks%3!=0;
wire [63:0] axis_data;
wire axis_valid,axis_last,axis_user,full;
wire axis_ready;
wire [1:0] wr_bank,rd_bank;
rgb_framebuffer #(.FRAME_WIDTH(WIDTH),.FRAME_HEIGHT(HEIGHT),.WR_FIFO_DEPTH(INIT_ONLY?1024:256),.RD_FIFO_DEPTH(INIT_ONLY?1024:256),.C_MODE(1),.D_MODE(1),.BLIT_ENABLE(GRAPHICS)) dut (
    .axi_clk(axi_clk),.rst_n(rst_n),.i_clk(i_clk),.i_frame_start(frame_start),
    .i_de(source_de),.vin(vin),.o_clk(o_clk),.fifo_rd_period(period),
    .display_underflow(underflow),
    .m_axis_tdata(axis_data),.m_axis_tvalid(axis_valid),.m_axis_tready(axis_ready),
    .m_axis_tlast(axis_last),.m_axis_tuser(axis_user),
    .awaddr(awaddr),.awlen(awlen),.awsize(awsize),.awburst(awburst),
    .awvalid(awvalid),.awready(awready),.wdata(wdata),.wstrb(wstrb),
    .wlast(wlast),.wvalid(wvalid),.wready(wready),
    .bid(4'b0),.bvalid(routed_bvalid),.bready(bready),
    .araddr(araddr),.arlen(arlen),.arsize(arsize),.arburst(arburst),
    .arvalid(arvalid),.arready(arready),.rid(4'b0),.rdata(rdata),
    .rlast(rlast),.rvalid(rvalid || force_stray),.rready(rready),.rresp(2'b0),
    .source_done(source_done),.bresp(2'b0),.cmd_start(start),.cmd_x(cx),.cmd_y(cy),.cmd_width(cw),.cmd_height(ch),.cmd_color(cc),
    .cmd_op(cop),.cmd_src_addr(csrc),.cmd_src_stride(cstride),
    .init_done(init_done),.init_error(init_error),.engine_busy(busy),.engine_done(done),.engine_error(engine_error),.command_count(commands),
    .init_data_beats(beats),.init_aw_bursts(aws),.init_wlast_bursts(lasts),.init_b_responses(bs),.init_aw_beats(reserved),
.draw_ready(draw_ready),.buffer_status(buffer_status),.swap_request(swap_request),.clear_swap_done(clear_swap_done),
 .service_status(service_status),
 .writer_throttle_cycles(writer_throttle_cycles),
 .writer_bursts(writer_bursts),
 .reader_ar_stall_cycles(reader_ar_stall_cycles),
 .reader_ar_max_stall(reader_ar_max_stall),
 .reader_r_stall_cycles(reader_r_stall_cycles),
 .reader_r_max_stall(reader_r_max_stall),
 .display_underflow_count(display_underflow_count),
 .reader_frame_completions(reader_frame_completions),
 .reader_fifo_level(reader_fifo_level),
 .writer_max_cycles(writer_max_cycles),
 .service_read_quota(service_read_quota),
 .service_watermarks(service_watermarks),
 .reader_frame_base(reader_frame_base),.reader_outstanding(reader_outstanding),.reader_data_beats(reader_data_beats),
 .reader_reserved_beats(reader_reserved_beats),.reader_error(reader_error),.boundary_count(boundary_count),
 .swap_count(swap_count),.missed_boundary_count(missed_boundary_count),
    .diag_wr_base(back_base),.diag_rd_base(front_base),
    .diag_wr_fifo_full(full),.diag_wr_bank(wr_bank),.diag_rd_bank(rd_bank));
reg [127:0] memory [0:2*BEATS-1];
function integer mem_index;
input [31:0] a;
begin mem_index=(a>=32'h00800000)?BEATS+(a-32'h00800000)/16:a/16;end
endfunction
function in_frame;
input [31:0] a;
input [7:0] len;
begin in_frame=((a<BEATS*16 && a+(len+1)*16<=BEATS*16) ||
 (a>=32'h00800000 && a+(len+1)*16<=32'h00800000+BEATS*16));end
endfunction
reg final_b_pending=0,release_final_b=0;
integer j,lane;
reg [31:0] write_color;
always_comb begin
 case(((w_index%BEATS)%(WIDTH/4))/(WIDTH/16))
  0: write_color=32'h00ff0000; 1: write_color=32'h0000ff00;
  2: write_color=32'h000000ff; default: write_color=32'h00ffffff;
 endcase
end
always @(posedge axi_clk) begin
    if(rst_n) begin
        ticks<=ticks+1;
        if(final_b_pending && release_final_b) begin bvalid<=1;final_b_pending<=0;end
        if(init_error || (engine_error && !expect_engine_error) || (reader_error && !expect_read_error))
            $fatal(1,"D error init=%h engine=%h reader=%h",init_error,engine_error,reader_error);
        if(arvalid && !init_done) $fatal(1,"display read before INIT_DONE");
        if(routed_bvalid && bready) begin bvalid<=0; b_count<=b_count+1; end
        if(awvalid && awready) begin
            if(awsize!=4 || awburst!=1 || awaddr[3:0]!=0 ||
                awaddr[11:0]+(awlen+1)*16>4096) $fatal(1,"Bad AW burst/alignment");
            if(!in_frame(awaddr,awlen)) $fatal(1,"AW outside buffers");
            if(init_done && ((awaddr>=32'h00800000)!=buffer_status[1] || (awaddr>=32'h00800000)==buffer_status[0]))
                $fatal(1,"Accelerator wrote Front");
            write_active<=1; w_index<=mem_index(awaddr); w_left<=awlen+1;
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
                araddr[11:0]+(arlen+1)*16>4096 || !in_frame(araddr,arlen))
                $fatal(1,"Bad AR burst");
            if((araddr>=32'h00800000)!=buffer_status[0] || reader_frame_base!=front_base)
                $fatal(1,"Reader accessed Back");
            read_active<=1; r_index<=mem_index(araddr); r_left<=arlen+1;
            ar_count<=ar_count+1;
        end
        if(rvalid && rready) begin rvalid<=0; r_beats<=r_beats+1; end
        if(read_active && r_left==1 && r_index%BEATS==BEATS-1 && inject_late) begin
            late_held<=1;skip_pixels<=1;
        end else if(read_active && (!rvalid || rready) && !(wvalid && wready)) begin
            rvalid<=1; rdata<=memory[r_index]; rlast<=(r_left==1);
            r_index<=r_index+1; r_left<=r_left-1;
            if(r_left==1) read_active<=0;
        end
    end
end

wire [63:0] cvo_data;
wire cvo_de,cvo_hs,cvo_vs;
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
integer x=0,y=0,frames=0,checked_pixels=0,frame_tag=0;
reg old_de=0,old_vs=0,checking=0,frame_index=0;
reg [23:0] color;
always @(posedge pixel_clk) begin
 #0.1;
 if(rst_n) begin
  if(skip_pixels) checking=0;
  if(vs && !old_vs) begin
   if(checking) begin
    if(y!=HEIGHT) $fatal(1,"D frame rows=%0d",y);
    frames=frames+1;
   end
   checking=init_done && ar_count>0 && !skip_pixels;x=0;y=0;
  end
  if(checking && underflow) $fatal(1,"D steady underflow");
  if(de) begin
   if(x==0 && y==0) begin frame_index=buffer_status[0];frame_tag=image_tag[frame_index];end
   case(frame_tag)
    0: case(x/(WIDTH/4))
        0:color=24'hff0000;1:color=24'h00ff00;2:color=24'h0000ff;default:color=24'hffffff;
       endcase
    1: begin color=24'h0000ff;if(x>=3 && x<76 && y>=11 && y<30) color=24'hff0000;end
    2: begin color=0;if(x>=137 && x<192 && y>=27 && y<44) color=24'h00ff00;end
    3: begin
        color=0;
        if(x<32 && y<32) color=y<16 ? (x<16?24'hff0000:24'h00ff00) : (x<16?24'h0000ff:24'hffffff);
       end
    4: begin
        color=0;
        if(x>=64 && x<96 && y>=16 && y<48)
            color=y<32 ? (x<80?24'hff0000:24'h00ff00) : (x<80?24'h0000ff:24'hffffff);
       end
    default: $fatal(1,"Displayed unbuilt Back");
   endcase
   if(checking && (frame_index!=buffer_status[0] || {red,green,blue}!==color))
    $fatal(1,"D torn/mixed frame x=%0d y=%0d tag=%0d got=%h expected=%h front=%b",x,y,frame_tag,{red,green,blue},color,buffer_status[0]);
   if(checking) checked_pixels=checked_pixels+1;
   x=x+1;
  end else if(old_de) begin
   if(checking && x!=WIDTH) $fatal(1,"D line pixels=%0d",x);
   x=0;y=y+1;
  end
  old_de=de;old_vs=vs;
 end
end
reg old_front=0;
reg [31:0] old_reader_base=0;
always @(posedge axi_clk) begin
 #1;
 if(rst_n && init_done) begin
  if(buffer_status[0]==buffer_status[1]) $fatal(1,"Front=Back");
  if((old_front!=buffer_status[0] || old_reader_base!=reader_frame_base) && !dut.d_launch)
   $fatal(1,"Base changed outside frame launch");
  if(dut.d_flush && reader_outstanding!=0) $fatal(1,"Flushed before final R");
  if(dut.d_launch && (!dut.d_blank || reader_outstanding!=0)) $fatal(1,"Unsafe launch");
  old_front=buffer_status[0];old_reader_base=reader_frame_base;
 end
end
// This APB master deliberately never simulates the Sapphire CPU.
task access;
input integer address,write_access,value,expected_error;
begin
 @(negedge axi_clk);paddr=address;pwrite=write_access;pwdata=value;psel=1;penable=0;
 @(negedge axi_clk);penable=1;#1;
 while(!pready) begin @(negedge axi_clk);#1;end
 if(pslverror!==expected_error[0]) $fatal(1,"D APB error addr=%h actual=%b",address,pslverror);
 @(negedge axi_clk);psel=0;penable=0;
end endtask
task start_rect;
input integer xx,yy,ww,hh,cc;
begin
 if(GRAPHICS) access('hBC,1,0,0);
 access('h10,1,xx,0);access('h14,1,yy,0);access('h18,1,ww,0);access('h1c,1,hh,0);access('h20,1,cc,0);
 access(8,1,1,0);wait(busy || done);@(negedge axi_clk);
end endtask
task start_blit;
input integer source,stride,xx,yy,ww,hh;
integer previous_count;
begin
 previous_count=commands;
 access('hBC,1,1,0);access('hC0,1,source,0);access('hC4,1,stride,0);
 access('h10,1,xx,0);access('h14,1,yy,0);access('h18,1,ww,0);access('h1C,1,hh,0);
 access(8,1,1,0);wait(commands==previous_count+1);@(negedge axi_clk);
end endtask
task wait_fill;
begin wait(done && !busy);repeat(4) @(negedge axi_clk);end endtask
task request_swap;
begin access('h60,1,3,0);wait(buffer_status[2]);end endtask
task wait_swap;
input integer old_count;
begin wait(swap_count==old_count+1);repeat(8)@(negedge axi_clk);
 if(buffer_status[2] || !buffer_status[3] || reader_frame_base!=front_base) $fatal(1,"Swap completion status");
end endtask
integer round_no,old_sw,old_boundary,old_frames,back_slot;
reg old_index;
initial begin
 image_tag[0]=0;image_tag[1]=99;
 wait(apb_reset);access(8,1,1,1);
 access('h60,1,1,1);if(buffer_status[2]) $fatal(1,"Early swap queued before INIT");
 wait(final_b_pending);repeat(80) @(negedge axi_clk);
 if(init_done || beats!=BEATS || aws!=lasts || bs!=aws-1 || tpg_frames!=1) $fatal(1,"early handoff");
 release_final_b=1;wait(init_done);wait(draw_ready);
 access(8,1,2,0);access(4,0,0,0);if(prdata!=(GRAPHICS?'h40000:'h30000))$fatal(1,"D VERSION");
 access('h64,1,0,1);access('h24,0,0,0);if(prdata!=3)$fatal(1,"BUFFER_STATUS RO");
 access('hBC,0,0,GRAPHICS?0:1);access(8,1,2,0);
 wait(frames>=1);
 for(round_no=0;round_no<(GRAPHICS?1:4);round_no=round_no+1) begin
  back_slot=buffer_status[1];old_index=buffer_status[0];old_sw=swap_count;
  start_rect(0,0,WIDTH,HEIGHT,round_no%2==0?'h000000ff:0);wait_fill;
  if(buffer_status[0]!=old_index || swap_count!=old_sw) $fatal(1,"Implicit swap after clear");
  if(round_no==0) stall_aw=1;
  if(round_no%2==0) start_rect(3,11,73,19,'h00ff0000);
  else start_rect(137,27,55,17,'h0000ff00);
  image_tag[back_slot]=round_no%2+1;
  if(round_no==0) begin
   request_swap;access('h60,1,1,1);access('h24,0,0,0);if(prdata!=6)$fatal(1,"Duplicate swap request");
   access(8,1,1,1);access('h24,0,0,0);if(prdata!=5 && prdata!=6)$fatal(1,"START pending");
   // CPU island reset must preserve both the command and queued swap.
   @(negedge axi_clk);apb_reset=0;repeat(10)@(negedge axi_clk);apb_reset=1;
   old_boundary=boundary_count;wait(boundary_count>=old_boundary+2);
   if(swap_count!=old_sw || !buffer_status[2] || !busy) $fatal(1,"Swap while writer busy");
   stall_aw=0;wait_fill;
  end else begin wait_fill;request_swap;end
  wait_swap(old_sw);
  old_frames=frames;wait(frames>=old_frames+2);
  if(!buffer_status[3]) $fatal(1,"SWAP_DONE not sticky");
  access('h60,1,2,0);repeat(3) @(negedge axi_clk);if(buffer_status[3])$fatal(1,"CLEAR_DONE failed");
 end
 if(GRAPHICS) graphics_round;
 // Hold the last R of a frame across two boundaries. Last AR is NOT completion.
 // Build Back first: the read-service policy correctly refuses unlimited
 // writes while this test deliberately withholds all further read service.
 back_slot=buffer_status[1];old_index=buffer_status[0];old_sw=swap_count;
 start_rect(0,0,WIDTH,HEIGHT,'hff);wait_fill;
 start_rect(3,11,73,19,'hff0000);wait_fill;image_tag[back_slot]=1;
 inject_late=1;wait(late_held);
 request_swap;
 access(8,1,1,1);access('h24,0,0,0);if(prdata!=6)$fatal(1,"Idle START accepted during pending");
 access(8,1,2,0); // Clear only the APB test error, preserving pending.
 old_boundary=boundary_count;wait(boundary_count>=old_boundary+2);
 if(swap_count!=old_sw || reader_outstanding!=1 || !buffer_status[2]) $fatal(1,"Swap ignored last R");
 inject_late=0;wait_swap(old_sw);skip_pixels=0;
 old_frames=frames;wait(frames>=old_frames+3);
 if(missed_boundary_count<2 || tpg_frames!=1 || reader_error || engine_error) $fatal(1,"Late R recovery");
 if(GRAPHICS) graphics_fault;
 $display("PASS D pipeline: %0d swaps, %0d full frames/%0d pixels; Back-only AW, Front-only AR, busy/pending, APB reset, delayed last R recovery",swap_count,frames,checked_pixels);
 $finish;
end
integer display_during_blit=0,blit_during_display=0,contention=0;
reg copy_in_progress=0;
wire shared_busy;
generate if(GRAPHICS) begin: graphics_checks
 assign shared_busy=dut.shared_read.arbiter.busy;
 always @(posedge axi_clk) if(rst_n) begin
  if(dut.display_rvalid && dut.b_rvalid) $fatal(1,"Read owners broadcast");
  if(dut.u_ddr_rd_buffer.rvalid !== dut.display_rvalid)
   $fatal(1,"Display reader received another client's response");
  if(dut.d_buffers.write_service.rf !== (dut.display_rvalid && dut.display_rready))
   $fatal(1,"BLIT read counted as display write-admission quota");
  if(dut.b_rvalid && (dut.display_rvalid || dut.display_rdata!==0)) $fatal(1,"BLIT leaked into display FIFO");
  if(dut.b_arvalid && dut.display_arvalid) contention=contention+1;
  if(copy_in_progress && busy && dut.display_arvalid && dut.display_arready) display_during_blit=display_during_blit+1;
  if(dut.d_active && dut.b_arvalid && dut.b_arready) blit_during_display=blit_during_display+1;
 end
end else begin: no_graphics_checks
 assign shared_busy=0;
end endgenerate
task graphics_round;
integer before_ar,before_aw,before_commands,underflow_before,missed_before,saved_front,k;
begin
 access('h40,0,0,0);if(prdata!='h7b) $fatal(1,"Graphics capabilities");
 // Reject a source in Back without any memory traffic from the accelerator.
 expect_engine_error=1;
 before_aw=aw_count;before_commands=commands;
 start_blit(back_base,WIDTH*4,64,16,32,32);wait_fill;
 if(engine_error!='h21 || commands!=before_commands+1 || aw_count!=before_aw || dut.b_arvalid || buffer_status[5])
  $fatal(1,"Invalid source did not retire safely");
 access('hBC,1,99,0);access(8,1,1,0);wait_fill;
 if(engine_error!='h26 || aw_count!=before_aw) $fatal(1,"Invalid opcode touched DDR");
 // Build a reference sprite with real FILL commands, then publish it.
 back_slot=buffer_status[1];old_sw=swap_count;
 start_rect(0,0,WIDTH,HEIGHT,0);wait_fill;
 expect_engine_error=0;
 start_rect(0,0,16,16,'hff0000);wait_fill;start_rect(16,0,16,16,'h00ff00);wait_fill;
 start_rect(0,16,16,16,'h0000ff);wait_fill;start_rect(16,16,16,16,'hffffff);wait_fill;
 image_tag[back_slot]=3;request_swap;wait_swap(old_sw);
 old_frames=frames;wait(frames>=old_frames+2);
 back_slot=buffer_status[1];old_sw=swap_count;saved_front=front_base;
 start_rect(0,0,WIDTH,HEIGHT,0);wait_fill;
 underflow_before=display_underflow_count;missed_before=missed_boundary_count;
 // Make the copy start during active scanout, then hold the last write B.
 wait(dut.d_active && reader_fifo_level>=128);
 stall_read=1;
 copy_in_progress=1;
 start_blit(front_base,WIDTH*4,64,16,32,32);
 wait(dut.b_arvalid && dut.display_arvalid);
 repeat(3)@(negedge axi_clk);stall_read=0;
 // Editing APB registers after START must not change the active command.
 access('hBC,1,0,0);access('hC0,1,back_base,0);access('hC4,1,16,0);
 wait(wvalid && wlast && wready && w_index%BEATS==(47*WIDTH/4+23));
 @(negedge axi_clk);hold_b=1;wait(bvalid);repeat(4)@(negedge axi_clk);
 if(done || !busy || !buffer_status[5]) $fatal(1,"BLIT finished before final B");
 request_swap;
 @(negedge axi_clk);apb_reset=0;repeat(10)@(negedge axi_clk);apb_reset=1;
 access('hBC,0,0,0);if(prdata!=0) $fatal(1,"Opcode reset");
 access('hC0,0,0,0);if(prdata!=0) $fatal(1,"Source reset");
 access('hC4,0,0,0);if(prdata!=0) $fatal(1,"Stride reset");
 old_boundary=boundary_count;wait(boundary_count>=old_boundary+2);
 if(front_base!=saved_front || swap_count!=old_sw || !busy || !buffer_status[5]) $fatal(1,"CPU reset cancelled BLIT");
 image_tag[back_slot]=4;hold_b=0;wait_fill;wait_swap(old_sw);
 copy_in_progress=0;
 old_frames=frames;wait(frames>=old_frames+3);
 if(engine_error || reader_error || display_underflow_count!=underflow_before || missed_boundary_count!=missed_before)
  $fatal(1,"Shared display/BLIT errors underflow=%0d missed=%0d",display_underflow_count-underflow_before,missed_boundary_count-missed_before);
 if(!display_during_blit || !blit_during_display || !contention)
  $fatal(1,"Missing concurrent read coverage display=%0d blit=%0d contention=%0d",display_during_blit,blit_during_display,contention);
 $display("PASS shared BLIT: APB snapshot/reset, four-color copy, final B/pending swap, concurrent display=%0d blit=%0d contention=%0d, underflow/missed delta=0",display_during_blit,blit_during_display,contention);
end endtask
task graphics_fault;
integer saved_sw,saved_commands;
begin
 skip_pixels=1;
 expect_read_error=1;
 wait(!shared_busy && !rvalid);
 @(negedge axi_clk);force_stray=1;
 @(negedge axi_clk);force_stray=0;
 repeat(3)@(negedge axi_clk);
 if(reader_error!='h2004 || draw_ready || buffer_status[7]) $fatal(1,"Shared fault not contained");
 saved_sw=swap_count;saved_commands=commands;
 access('h78,0,0,0);if(prdata!='h2004) $fatal(1,"Shared fault CSR");
 access(8,1,1,1);access('h60,1,1,1);
 apb_reset=0;repeat(10)@(negedge axi_clk);apb_reset=1;
 repeat(1000)@(negedge axi_clk);
 if(reader_error!='h2004 || swap_count!=saved_sw || commands!=saved_commands) $fatal(1,"CPU reset cleared shared fault");
 $display("PASS shared fault: 0x2004, START/swap rejected, CPU reset preserves platform fault");
end endtask
always @(posedge i_clk) if(source_de && full) $fatal(1,"pipeline writer overflow");
initial begin
 for(j=0;j<2*BEATS;j=j+1) memory[j]=0;
 repeat(20) @(negedge i_clk);rst_n=1;apb_reset=1;
end
initial begin #60000000; $fatal(1,"pipeline timeout tpg=%0d checked=%0d",tpg_frames,frames);end
endmodule
