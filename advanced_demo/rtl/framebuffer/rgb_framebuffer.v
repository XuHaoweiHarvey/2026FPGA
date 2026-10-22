// RGB framebuffer: C_MODE selects one-shot initialization and permanent engine
// ownership. D_MODE adds Front/Back management; D_MODE=0 retains the C single
// slot, and C_MODE=0/D_MODE=0 retains the A/B triple-slot regression path.
module rgb_framebuffer #(
    parameter FRAME_WIDTH = 1920,
    parameter FRAME_HEIGHT = 1080,
    parameter AXI_ADDR_WIDTH = 32,
    parameter AXI_ID_WIDTH = 4,
    parameter WR_FIFO_DEPTH = 1024,
    parameter RD_FIFO_DEPTH = 1024,
    parameter BURST_LEN = 127,
    parameter C_MODE = 0, SETTLE_FRAMES = 2, D_MODE = 0, BLIT_ENABLE = 0,
    parameter WRITE_SERVICE_ENABLE=1, WRITE_READ_QUOTA=128,
    parameter WRITE_FIFO_LOW=RD_FIFO_DEPTH*3/8, WRITE_FIFO_HIGH=RD_FIFO_DEPTH/2,
    parameter [31:0] BUFFER0_BASE=0, BUFFER1_BASE=32'h00800000,
    parameter COLOR_KEY_ENABLE=0, CPU_DDR_ENABLE=0, ALPHA_ENABLE=0
)(
    input wire axi_clk, input wire rst_n,
    input wire i_clk, input wire i_frame_start, input wire i_de,
    input wire [127:0] vin,
    input wire o_clk, input wire fifo_rd_period,
    output wire [63:0] m_axis_tdata,
    output wire m_axis_tvalid, input wire m_axis_tready,
    output wire m_axis_tuser, output wire m_axis_tlast,
    output wire [AXI_ID_WIDTH-1:0] awid,
    output wire [AXI_ADDR_WIDTH-1:0] awaddr,
    output wire [7:0] awlen, output wire [2:0] awsize,
    output wire [1:0] awburst, output wire [3:0] awcache,
    output wire [2:0] awprot, output wire awlock,
    output wire awvalid, input wire awready,
    output wire [127:0] wdata, output wire [15:0] wstrb,
    output wire wlast, output wire wvalid, input wire wready,
    input wire [AXI_ID_WIDTH-1:0] bid, input wire bvalid, output wire bready,
    output wire [AXI_ID_WIDTH-1:0] arid,
    output wire [AXI_ADDR_WIDTH-1:0] araddr,
    output wire [7:0] arlen, output wire [2:0] arsize,
    output wire [1:0] arburst, output wire [3:0] arcache,
    output wire [2:0] arprot, output wire arlock,
    output wire arvalid, input wire arready,
    input wire [AXI_ID_WIDTH-1:0] rid, input wire [127:0] rdata,
    input wire rlast, input wire rvalid, output wire rready,
    input wire [1:0] rresp,
    output wire diag_wr_fifo_full,
    output wire [1:0] diag_wr_bank, output wire [1:0] diag_rd_bank,
    output wire [31:0] diag_wr_base, output wire [31:0] diag_rd_base,
    input wire source_done, input wire [1:0] bresp,
    input wire cmd_start, input wire [31:0] cmd_x,cmd_y,cmd_width,cmd_height,cmd_color,
    input wire [31:0] cmd_op,cmd_src_addr,cmd_src_stride,
    output wire init_done, output wire [31:0] init_error,
    output wire engine_busy,engine_done,output wire [31:0] engine_error,command_count,
    output wire [31:0] init_data_beats,init_aw_bursts,init_wlast_bursts,init_b_responses,init_aw_beats,
    input wire swap_request,clear_swap_done,
    output wire draw_ready,output wire [31:0] buffer_status,
    output wire [31:0] reader_frame_base,reader_outstanding,reader_data_beats,reader_reserved_beats,reader_error,
    output wire [31:0] boundary_count,swap_count,missed_boundary_count,
    input wire display_underflow,
    output wire [31:0] service_status,writer_throttle_cycles,writer_bursts,
    output wire [31:0] reader_ar_stall_cycles,reader_ar_max_stall,reader_r_stall_cycles,reader_r_max_stall,
    output wire [31:0] display_underflow_count,reader_frame_completions,reader_fifo_level,writer_max_cycles,
    output wire [31:0] service_read_quota,service_watermarks,
    input wire cpu_ddr_acquire,cpu_ddr_release,cpu_ddr_busy,cpu_ddr_clear_error,
    input wire [31:0] cpu_ddr_error,
    input wire asset_begin,asset_seal,
    output wire [31:0] asset_status,
    input wire sprite_begin,sprite_seal,output wire [31:0] sprite_status,
    output wire cpu_ddr_session_active,output wire [31:0] cpu_ddr_session_status,
    input wire [31:0] cpu_awaddr,input wire cpu_awvalid,output wire cpu_awready,
    input wire [127:0] cpu_wdata,input wire [15:0] cpu_wstrb,
    input wire cpu_wlast,cpu_wvalid,output wire cpu_wready,
    output wire [3:0] cpu_bid,output wire [1:0] cpu_bresp,
    output wire cpu_bvalid,input wire cpu_bready,
    input wire [31:0] cpu_araddr,input wire cpu_arvalid,output wire cpu_arready,
    output wire [127:0] cpu_rdata,output wire [3:0] cpu_rid,output wire [1:0] cpu_rresp,
    output wire cpu_rlast,output wire cpu_rvalid,input wire cpu_rready
);
localparam [24:0] FRAME_BEATS = FRAME_WIDTH * FRAME_HEIGHT / 4;
wire wr_rst_n, axi_rst_n, rd_rst_n;
rst_n_piple #(.DLY(3)) u_wr_reset (.clk(i_clk), .rst_n_i(rst_n), .rst_n_o(wr_rst_n));
rst_n_piple #(.DLY(3)) u_axi_reset (.clk(axi_clk), .rst_n_i(rst_n), .rst_n_o(axi_rst_n));
rst_n_piple #(.DLY(3)) u_rd_reset (.clk(o_clk), .rst_n_i(rst_n), .rst_n_o(rd_rst_n));
// Source frame_start is one 50 MHz cycle, wider than the 100 MHz destination
// period. The original writer performs its two-flop synchronization/edge detect.
wire wr_fifo_reset = !wr_rst_n || i_frame_start;
(* async_reg = "true" *) reg [2:0] rd_period_sync;
always @(posedge axi_clk or negedge axi_rst_n)
    if (!axi_rst_n) rd_period_sync <= 0;
    else rd_period_sync <= {rd_period_sync[1:0],fifo_rd_period};
wire d_flush,d_launch,d_boundary,d_blank,d_safe,d_active,d_reader_idle,d_fifo_empty;
wire d_command_accept,d_front_index,d_back_index,d_front_valid,d_owned,d_pending,d_done;
wire [31:0] d_front_base,d_back_base,d_command_base;
wire manager_draw_ready;
wire [31:0] display_error;
wire read_fault;
reg cpu_session=0,cpu_session_fault=0;
reg asset_loading=0,asset_ready=0,sprite_loading=0,sprite_ready=0;
wire cpu_owner=CPU_DDR_ENABLE && D_MODE && cpu_session;
assign asset_status={1'b1,28'b0,(cpu_session_fault || cpu_ddr_error!=0),
                     asset_ready,asset_loading};
assign sprite_status={1'b1,28'b0,(cpu_session_fault || cpu_ddr_error!=0),
                      sprite_ready,sprite_loading};
assign cpu_ddr_session_active=cpu_owner;
assign cpu_ddr_session_status={27'b0,(CPU_DDR_ENABLE!=0),1'b0,cpu_session_fault,
                               cpu_ddr_busy,cpu_owner};
always @(posedge axi_clk or negedge axi_rst_n) begin
    if(!axi_rst_n) begin cpu_session<=0;cpu_session_fault<=0;end
    else if(CPU_DDR_ENABLE && D_MODE) begin
        if(cpu_ddr_clear_error) cpu_session_fault<=0;
        if(cpu_ddr_acquire) begin
            if(!cpu_session && manager_draw_ready && read_healthy &&
               !cpu_ddr_busy && !engine_busy && !d_owned && !d_pending &&
               !swap_request && !cmd_start && !a_awvalid && !b_arvalid)
                cpu_session<=1;
            else cpu_session_fault<=1;
        end
        if(cpu_ddr_release) begin
            if(cpu_session && !cpu_ddr_busy && !cpu_awvalid && !cpu_wvalid && !cpu_arvalid)
                cpu_session<=0;
            else cpu_session_fault<=1;
        end
    end
end
always @(posedge axi_clk or negedge axi_rst_n) begin
    if(!axi_rst_n) begin asset_loading<=0;asset_ready<=0;sprite_loading<=0;sprite_ready<=0;end
    else if(CPU_DDR_ENABLE && D_MODE) begin
        if(asset_begin && !sprite_loading && !asset_loading && !asset_ready && !cpu_session &&
           !cpu_ddr_busy && !engine_busy && !d_pending && init_done &&
           cpu_ddr_error==0 && !cpu_session_fault && read_healthy)
            asset_loading<=1;
        if(asset_seal && asset_loading && !asset_ready && !cpu_session &&
           !cpu_ddr_busy && !engine_busy && !d_pending &&
           cpu_ddr_error==0 && !cpu_session_fault && read_healthy) begin
            asset_loading<=0;asset_ready<=1;
        end
        if(sprite_begin && ALPHA_ENABLE && asset_ready && !sprite_loading && !sprite_ready &&
           !asset_loading && !cpu_session && !cpu_ddr_busy && !engine_busy && !d_pending &&
           init_done && cpu_ddr_error==0 && !cpu_session_fault && read_healthy)
            sprite_loading<=1;
        if(sprite_seal && ALPHA_ENABLE && sprite_loading && !sprite_ready &&
           !cpu_session && !cpu_ddr_busy && !engine_busy && !d_pending &&
           cpu_ddr_error==0 && !cpu_session_fault && read_healthy) begin
            sprite_loading<=0;sprite_ready<=1;
        end
    end
end
// Block new commands and publication on a read fault; never cancel DMA.
wire read_healthy = !BLIT_ENABLE || reader_error==0;
wire rd_fifo_reset = !axi_rst_n || (D_MODE ? d_flush : rd_period_sync[2:1] == 2'b01);
wire [31:0] wr_base, rd_base;
// APB read-only ownership addresses (D uses the manager, legacy uses banks).
assign diag_wr_base = D_MODE ? d_back_base : wr_base;
assign diag_rd_base = D_MODE ? d_front_base : rd_base;
wire wr_sw, rd_sw, wr_ack, rd_ack;
// Legacy mode keeps the three slots. C selects the existing single-slot branch.
// VID_DATA_WIDTH is bits per pixel, not the 128-bit source bus width.
generate if(!D_MODE) begin: old_banks
bank_switch #(.FB_NUM(C_MODE ? 1 : 3), .MAX_VID_WIDTH(FRAME_WIDTH),
    .MAX_VID_HIGHT(FRAME_HEIGHT), .START_ADDR(0),
    .VID_DATA_WIDTH(32), .AXI_DATA_WIDTH(128)) u_bank_sw (
    .ddr_clk(axi_clk), .rst_n(axi_rst_n), .wr_sw(wr_sw), .rd_sw(rd_sw),
    .wr_bank(diag_wr_bank), .rd_bank(diag_rd_bank),
    .wr_sw_ack(wr_ack), .rd_sw_ack(rd_ack),
    .wr_start_addr(wr_base), .rd_start_addr(rd_base)
);
end else begin: fixed_init_bank
    assign wr_base=BUFFER0_BASE;assign rd_base=reader_frame_base;
    assign wr_ack=wr_sw;assign rd_ack=rd_sw;
    assign diag_wr_bank={1'b0,d_back_index};assign diag_rd_bank={1'b0,d_front_index};
end endgenerate
wire [5:0] wr_id, rd_id;
assign awid = wr_id[AXI_ID_WIDTH-1:0];
wire [31:0] display_araddr,b_araddr;
wire [7:0] display_arlen,b_arlen;
wire [2:0] display_arsize,display_arprot;
wire [1:0] display_arburst;
wire [3:0] display_arcache;
wire display_arlock,display_arvalid,display_arready;
wire [127:0] display_rdata,b_rdata;
wire [AXI_ID_WIDTH-1:0] display_rid;
wire [3:0] b_rid;
wire [1:0] display_rresp,b_rresp;
wire display_rlast,display_rvalid,display_rready;
wire b_arvalid,b_arready,b_rlast,b_rvalid,b_rready;
wire [31:0] nondisplay_araddr;
wire [7:0] nondisplay_arlen;
wire nondisplay_arvalid,nondisplay_arready,nondisplay_rvalid,nondisplay_rlast,nondisplay_rready;
wire [127:0] nondisplay_rdata;
wire [3:0] nondisplay_rid;
wire [1:0] nondisplay_rresp;
assign nondisplay_araddr=cpu_owner ? cpu_araddr : b_araddr;
assign nondisplay_arlen=cpu_owner ? 8'b0 : b_arlen;
assign nondisplay_arvalid=cpu_owner ? cpu_arvalid : b_arvalid;
assign nondisplay_rready=cpu_owner ? cpu_rready : b_rready;
assign cpu_arready=cpu_owner && nondisplay_arready;
assign cpu_rdata=cpu_owner ? nondisplay_rdata : 128'b0;
assign cpu_rid=cpu_owner ? nondisplay_rid : 4'b0;
assign cpu_rresp=cpu_owner ? nondisplay_rresp : 2'b0;
assign cpu_rlast=cpu_owner && nondisplay_rlast;
assign cpu_rvalid=cpu_owner && nondisplay_rvalid;
assign b_arready=!cpu_owner && nondisplay_arready;
assign b_rdata=cpu_owner ? 128'b0 : nondisplay_rdata;
assign b_rid=cpu_owner ? 4'b0 : nondisplay_rid;
assign b_rresp=cpu_owner ? 2'b0 : nondisplay_rresp;
assign b_rlast=!cpu_owner && nondisplay_rlast;
assign b_rvalid=!cpu_owner && nondisplay_rvalid;
wire [31:0] t_awaddr,a_awaddr;
wire [7:0] t_awlen,a_awlen;
wire [127:0] t_wdata,a_wdata;
wire [15:0] t_wstrb,a_wstrb;
wire t_awvalid,t_awready,t_wvalid,t_wready,t_wlast,t_bvalid,t_bready,t_fifo_empty,t_idle;
wire a_awvalid,a_awready,a_wvalid,a_wready,a_wlast,a_bvalid,a_bready;
wire [31:0] active_awaddr;
wire [127:0] active_wdata;
wire [15:0] active_wstrb;
wire active_awvalid,active_wvalid,active_wlast,active_bready,active_bvalid;
assign active_awaddr=cpu_owner ? cpu_awaddr : a_awaddr+(D_MODE ? d_command_base : 32'b0);
assign active_wdata=cpu_owner ? cpu_wdata : a_wdata;
assign active_wstrb=cpu_owner ? cpu_wstrb : a_wstrb;
assign active_awvalid=cpu_owner ? cpu_awvalid : a_awvalid;
assign active_wvalid=cpu_owner ? cpu_wvalid : a_wvalid;
assign active_wlast=cpu_owner ? cpu_wlast : a_wlast;
assign active_bready=cpu_owner ? cpu_bready : a_bready;
assign active_bvalid=owner_accel && bvalid;
assign cpu_awready=cpu_owner && owner_accel && writer_admit && awready;
assign cpu_wready=cpu_owner && owner_accel && wready;
assign cpu_bid=bid;
assign cpu_bresp=bresp;
assign cpu_bvalid=cpu_owner && active_bvalid;
wire owner_accel=C_MODE && init_done;
wire writer_admit;
assign awaddr=owner_accel?active_awaddr:t_awaddr;
assign awlen=owner_accel?(cpu_owner ? 8'b0 : a_awlen):t_awlen;
assign awvalid=owner_accel?(active_awvalid && writer_admit):t_awvalid;
assign wdata=owner_accel?active_wdata:t_wdata;
assign wstrb=owner_accel?active_wstrb:t_wstrb;
assign wlast=owner_accel?active_wlast:t_wlast;
assign wvalid=owner_accel?active_wvalid:t_wvalid;
assign bready=owner_accel?active_bready:t_bready;
assign t_awready=!owner_accel && awready;
assign t_wready=!owner_accel && wready;
assign t_bvalid=!owner_accel && bvalid;
assign a_awready=owner_accel && !cpu_owner && writer_admit && awready;
assign a_wready=owner_accel && !cpu_owner && wready;
assign a_bvalid=owner_accel && !cpu_owner && bvalid;
// Both writers use ID0, size4, INCR, cache3/prot2/lock0: retain the
// original constant sideband outputs. Payload/VALID/READY/B are owner muxed.
ddr_wr_buffer1 #(.AXI_DATA_WIDTH(128), .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
    .WR_FIFO_DEPTH(WR_FIFO_DEPTH), .BURST_LEN(BURST_LEN)) u_ddr_wr_buffer (
    .axi_clk(axi_clk), .rst_n(axi_rst_n), .start(i_frame_start),
    .start_addr(wr_base), .total_burst_len(FRAME_BEATS),
    .bank_sw_ack(wr_ack), .bank_sw(wr_sw),
    .wr_fifo_rst_p(wr_fifo_reset), .wr_fifo_wrclk(i_clk),
    .wr_fifo_wren(i_de && wr_rst_n), .wr_fifo_wrdata(vin),
    .wr_fifo_wrfull(diag_wr_fifo_full),
    .diag_fifo_empty(t_fifo_empty), .diag_idle(t_idle),
    .awid(wr_id), .awaddr(t_awaddr), .awlen(t_awlen), .awsize(awsize),
    .awburst(awburst), .awcache(awcache), .awprot(awprot), .awlock(awlock),
    .awvalid(t_awvalid), .awready(t_awready),
    .wdata(t_wdata), .wstrb(t_wstrb), .wlast(t_wlast), .wvalid(t_wvalid), .wready(t_wready),
    .bid({{(6-AXI_ID_WIDTH){1'b0}},bid}), .bvalid(t_bvalid), .bready(t_bready)
);
generate if(C_MODE) begin: c_control
    reg overflow=0;
    always @(posedge i_clk) begin
        if(!wr_rst_n) overflow<=0;
        else if(i_de && diag_wr_fifo_full) overflow<=1;
    end
    (* async_reg="true" *) reg [2:0] stopped_sync=0,overflow_sync=0;
    always @(posedge axi_clk or negedge axi_rst_n)
        if(!axi_rst_n) begin stopped_sync<=0;overflow_sync<=0;end
        else begin stopped_sync<={stopped_sync[1:0],source_done};overflow_sync<={overflow_sync[1:0],overflow};end
    init_write_monitor #(.FRAME_BEATS(FRAME_BEATS)) monitor (
        .clk(axi_clk),.rst_n(axi_rst_n),.source_done(stopped_sync[2]),
        .fifo_empty(t_fifo_empty),.writer_idle(t_idle),.source_overflow(overflow_sync[2]),
        .awaddr(awaddr),.awlen(awlen),.awsize(awsize),.awburst(awburst),.awvalid(awvalid),.awready(awready),
        .wstrb(wstrb),.wvalid(wvalid),.wready(wready),.wlast(wlast),
        .bid(bid),.bresp(bresp),.bvalid(bvalid),.bready(bready),
        .init_done(init_done),.init_error(init_error),.data_beats(init_data_beats),
        .aw_bursts(init_aw_bursts),.wlast_bursts(init_wlast_bursts),
        .b_responses(init_b_responses),.aw_reserved_beats(init_aw_beats));
    if(BLIT_ENABLE) begin: graphics
        wire source_valid;
        blit_source_guard #(.FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT),
            .FRAME_STRIDE(FRAME_WIDTH*4),.ALPHA_ENABLE(ALPHA_ENABLE)) source_guard (
            .clk(axi_clk),.rst_n(axi_rst_n),.command_accept(d_command_accept),
            .front_base(d_front_base),.back_base(d_back_base),
            .src_addr(cmd_src_addr),.src_stride(cmd_src_stride),
            .op(cmd_op),.asset_ready(asset_ready),.sprite_ready(sprite_ready),
            .width(cmd_width),.height(cmd_height),.src_range_valid(source_valid));
        graphics_engine #(.FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT),
            .FRAME_STRIDE(FRAME_WIDTH*4),.COLOR_KEY_ENABLE(COLOR_KEY_ENABLE),
            .ALPHA_ENABLE(ALPHA_ENABLE)) engine (
            .clk(axi_clk),.rst_n(axi_rst_n),.enabled(init_done),.start(d_command_accept),
            .op(cmd_op),.x(cmd_x),.y(cmd_y),.width(cmd_width),.height(cmd_height),.color(cmd_color),
            .src_addr(cmd_src_addr),.src_stride(cmd_src_stride),.back_base(d_back_base),
            .src_range_valid(source_valid),.accept(),
            .busy(engine_busy),.done(engine_done),.error_code(engine_error),.command_count(command_count),
            .araddr(b_araddr),.arlen(b_arlen),.arvalid(b_arvalid),.arready(b_arready),
            .rdata(b_rdata),.rid(b_rid),.rresp(b_rresp),.rlast(b_rlast),.rvalid(b_rvalid),.rready(b_rready),
            .awaddr(a_awaddr),.awlen(a_awlen),.awvalid(a_awvalid),.awready(a_awready),
            .wdata(a_wdata),.wstrb(a_wstrb),.wlast(a_wlast),.wvalid(a_wvalid),.wready(a_wready),
            .bid(bid),.bresp(bresp),.bvalid(a_bvalid),.bready(a_bready));
    end else begin: fill_only
    assign b_araddr=0;assign b_arlen=0;assign b_arvalid=0;assign b_rready=0;
    fill_rect_writer #(.FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT),
        .FRAME_STRIDE(FRAME_WIDTH*4),.SETTLE_FRAMES(D_MODE ? 0 : SETTLE_FRAMES)) engine (
        .clk(axi_clk),.rst_n(axi_rst_n),.enabled(init_done),.start(D_MODE ? d_command_accept : cmd_start),
        .rect_x(cmd_x),.rect_y(cmd_y),.rect_width(cmd_width),.rect_height(cmd_height),.rect_color(cmd_color),
        .display_frame_tick(rd_period_sync[2:1]==2'b01),
        .busy(engine_busy),.done(engine_done),.error_code(engine_error),.command_count(command_count),
        .awaddr(a_awaddr),.awlen(a_awlen),.awvalid(a_awvalid),.awready(a_awready),
        .wdata(a_wdata),.wstrb(a_wstrb),.wlast(a_wlast),.wvalid(a_wvalid),.wready(a_wready),
        .bid(bid),.bresp(bresp),.bvalid(a_bvalid),.bready(a_bready));
    end
end else begin: legacy_mode
    assign init_done=0;assign init_error=0;
    assign init_data_beats=0;assign init_aw_bursts=0;assign init_wlast_bursts=0;
    assign init_b_responses=0;assign init_aw_beats=0;
    assign engine_busy=0;assign engine_done=0;assign engine_error=0;assign command_count=0;
    assign a_awaddr=0;assign a_awlen=0;assign a_awvalid=0;
    assign a_wdata=0;assign a_wstrb=0;assign a_wlast=0;assign a_wvalid=0;assign a_bready=0;
    assign b_araddr=0;assign b_arlen=0;assign b_arvalid=0;assign b_rready=0;
end endgenerate
reg read_armed=0;
always @(posedge axi_clk or negedge axi_rst_n)
    if(!axi_rst_n) read_armed<=0;
    else if(init_done && rd_period_sync[2:1]==2'b01) read_armed<=1;
wire reader_start=D_MODE ? d_launch : C_MODE ? (read_armed && fifo_rd_period) : fifo_rd_period;
wire [127:0] rd_fifo_data;
wire rd_fifo_empty, rd_fifo_read;
ddr_rd_buffer #(.AXI_DATA_WIDTH(128), .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
    .RD_FIFO_DEPTH(RD_FIFO_DEPTH), .BURST_LEN(BURST_LEN)) u_ddr_rd_buffer (
    .axi_clk(axi_clk), .axi_clk_rst_n(axi_rst_n), .start(reader_start),
    .start_addr(rd_base), .burst_len(FRAME_BEATS),
    .bank_sw_ack(rd_ack), .bank_sw(rd_sw),
    .rd_fifo_rdclk(o_clk), .rd_fifo_rst_p(rd_fifo_reset),
    .rd_fifo_rddata(rd_fifo_data), .rd_fifo_rdempty(rd_fifo_empty),
    .rd_fifo_rden(rd_fifo_read),
    .diag_idle(d_reader_idle),.diag_fifo_empty(d_fifo_empty),.diag_fifo_level(reader_fifo_level),
    .arid(rd_id), .araddr(display_araddr), .arlen(display_arlen), .arsize(display_arsize),
    .arburst(display_arburst), .arcache(display_arcache), .arprot(display_arprot), .arlock(display_arlock),
    .arvalid(display_arvalid), .arready(display_arready),
    .rid({{(6-AXI_ID_WIDTH){1'b0}},display_rid}), .rdata(display_rdata),
    .rlast(display_rlast), .rvalid(display_rvalid), .rready(display_rready), .rresp(display_rresp)
);
generate if(BLIT_ENABLE) begin: shared_read
    ddr_read_arbiter #(.FIFO_LOW(WRITE_FIFO_LOW),.FIFO_HIGH(WRITE_FIFO_HIGH)) arbiter (
        .clk(axi_clk),.rst_n(axi_rst_n),.enabled(init_done),
        .display_active(d_active),.display_launch(d_launch),.display_flush(d_flush),.display_fifo_level(reader_fifo_level),
        .display_araddr(display_araddr),.display_arlen(display_arlen),.display_arvalid(display_arvalid),.display_arready(display_arready),
        .display_rdata(display_rdata),.display_rid(display_rid),.display_rresp(display_rresp),
        .display_rlast(display_rlast),.display_rvalid(display_rvalid),.display_rready(display_rready),
        .blit_araddr(nondisplay_araddr),.blit_arlen(nondisplay_arlen),
        .blit_arvalid(nondisplay_arvalid),.blit_arready(nondisplay_arready),
        .blit_rdata(nondisplay_rdata),.blit_rid(nondisplay_rid),.blit_rresp(nondisplay_rresp),
        .blit_rlast(nondisplay_rlast),.blit_rvalid(nondisplay_rvalid),.blit_rready(nondisplay_rready),
        .araddr(araddr),.arlen(arlen),.arid(arid),.arsize(arsize),.arburst(arburst),
        .arcache(arcache),.arprot(arprot),.arlock(arlock),.arqos(),.arvalid(arvalid),.arready(arready),
        .rdata(rdata),.rid(rid),.rresp(rresp),.rlast(rlast),.rvalid(rvalid),.rready(rready),
        .fault(read_fault),.fault_code(),.address_pending(),.read_active(),.owner_blit(),.busy(),.display_urgent(),
        .beats_left(),.display_bursts(),.blit_bursts(),.display_beats(),.blit_beats());
end else begin: display_only
    assign araddr=display_araddr;assign arlen=display_arlen;assign arid=rd_id[AXI_ID_WIDTH-1:0];
    assign arsize=display_arsize;assign arburst=display_arburst;assign arcache=display_arcache;
    assign arprot=display_arprot;assign arlock=display_arlock;assign arvalid=display_arvalid;assign display_arready=arready;
    assign display_rdata=rdata;assign display_rid=rid;assign display_rresp=rresp;
    assign display_rlast=rlast;assign display_rvalid=rvalid;assign rready=display_rready;
    assign nondisplay_arready=0;assign nondisplay_rdata=0;assign nondisplay_rid=0;
    assign nondisplay_rresp=0;assign nondisplay_rlast=0;assign nondisplay_rvalid=0;
    assign read_fault=0;
end endgenerate
generate if(D_MODE) begin: d_buffers
    assign reader_error=read_fault ? 32'h2004 : display_error;
    assign draw_ready=manager_draw_ready && read_healthy && !cpu_owner &&
                      !(CPU_DDR_ENABLE && (cpu_ddr_error!=0 || cpu_session_fault)) &&
                      !(CPU_DDR_ENABLE && cpu_ddr_acquire);
    ddr_write_admission #(.ENABLE(WRITE_SERVICE_ENABLE),.READ_QUOTA(WRITE_READ_QUOTA),
        .FIFO_LOW(WRITE_FIFO_LOW),.FIFO_HIGH(WRITE_FIFO_HIGH)) write_service (
        .clk(axi_clk),.rst_n(axi_rst_n),.enabled(init_done),
        .raw_awvalid(active_awvalid),.ddr_awready(awready),
        .bvalid(active_bvalid),.bready(active_bready),
        .reader_active(d_active),.reader_safe(d_safe),.reader_launch(d_launch),.fifo_flush(d_flush),
        .fifo_level(reader_fifo_level),.reader_error(reader_error),
        .arvalid(display_arvalid),.arready(display_arready),.rvalid(display_rvalid),.rready(display_rready),.reader_outstanding(reader_outstanding),
        .admit_aw(writer_admit),.service_status(service_status),
        .throttle_cycles(writer_throttle_cycles),.writer_bursts(writer_bursts),
        .ar_stall_cycles(reader_ar_stall_cycles),.ar_max_stall(reader_ar_max_stall),
        .r_stall_cycles(reader_r_stall_cycles),.r_max_stall(reader_r_max_stall),
        .frame_completions(reader_frame_completions),.max_write_cycles(writer_max_cycles));
    display_underflow_counter underflow_diag (
        .video_clk(o_clk),.video_rst_n(rd_rst_n),.underflow(display_underflow),
        .core_clk(axi_clk),.core_rst_n(axi_rst_n),.count(display_underflow_count));
    assign service_read_quota=WRITE_READ_QUOTA;
    assign service_watermarks=(WRITE_FIFO_HIGH<<16) | WRITE_FIFO_LOW;
    video_frame_cdc frame_cdc (
        .video_clk(o_clk),.video_rst_n(rd_rst_n),.video_period(fifo_rd_period),
        .core_clk(axi_clk),.core_rst_n(axi_rst_n),.boundary_tick(d_boundary),.blank_active(d_blank));
    read_frame_guard #(.FRAME_BEATS(FRAME_BEATS)) guard (
        .clk(axi_clk),.rst_n(axi_rst_n),.launch(d_launch),.frame_base(reader_frame_base),
        .reader_idle(d_reader_idle),.araddr(display_araddr),.arlen(display_arlen),.arsize(display_arsize),.arburst(display_arburst),
        .arvalid(display_arvalid),.arready(display_arready),.rvalid(display_rvalid),.rready(display_rready),
        .rlast(display_rlast),.rid(display_rid),.rresp(display_rresp),
        .safe(d_safe),.active(d_active),.outstanding(reader_outstanding),.data_beats(reader_data_beats),
        .reserved_beats(reader_reserved_beats),.error_code(display_error));
    buffer_manager #(.BUFFER0_BASE(BUFFER0_BASE),.BUFFER1_BASE(BUFFER1_BASE)) manager (
        .clk(axi_clk),.rst_n(axi_rst_n),.init_done(init_done),
        .cmd_request(cmd_start && read_healthy && !cpu_owner &&
                     !(CPU_DDR_ENABLE && cpu_ddr_acquire)),
        .writer_busy(engine_busy),.writer_done(engine_done),.writer_error(engine_error),
        .swap_request(swap_request && !cpu_owner &&
                      !(CPU_DDR_ENABLE && (cpu_ddr_error!=0 || cpu_session_fault)) &&
                      !(CPU_DDR_ENABLE && cpu_ddr_acquire)),.clear_done(clear_swap_done),
        .boundary_tick(d_boundary),.blank_active(d_blank),.reader_safe(d_safe && read_healthy),.reader_fifo_empty(d_fifo_empty),
        .command_accept(d_command_accept),.draw_ready(manager_draw_ready),.writer_owned(d_owned),
        .front_index(d_front_index),.back_index(d_back_index),.front_valid(d_front_valid),
        .swap_pending(d_pending),.swap_done(d_done),.front_base(d_front_base),.back_base(d_back_base),
        .command_base(d_command_base),.reader_base(reader_frame_base),.reader_flush(d_flush),.reader_launch(d_launch),
        .boundary_count(boundary_count),.swap_count(swap_count),.missed_boundary_count(missed_boundary_count));
    assign buffer_status={24'b0,(d_safe && read_healthy),d_active,d_owned,d_front_valid,d_done,d_pending,d_back_index,d_front_index};
end else begin: no_swaps
    assign writer_admit=1;assign service_status=0;assign writer_throttle_cycles=0;assign writer_bursts=0;
    assign reader_ar_stall_cycles=0;assign reader_ar_max_stall=0;assign reader_r_stall_cycles=0;assign reader_r_max_stall=0;
    assign display_underflow_count=0;assign reader_frame_completions=0;assign writer_max_cycles=0;
    assign service_read_quota=0;assign service_watermarks=0;
    assign draw_ready=init_done && !engine_busy;
    assign buffer_status=0;assign reader_frame_base=0;assign reader_outstanding=0;
    assign reader_data_beats=0;assign reader_reserved_beats=0;assign reader_error=0;
    assign boundary_count=0;assign swap_count=0;assign missed_boundary_count=0;
    assign d_flush=0;assign d_launch=0;assign d_command_accept=0;
    assign d_front_base=0;assign d_back_base=0;assign d_command_base=0;
end endgenerate
// Derive normal FIFO read latency locally; the legacy rdvalid output is not
// used across clock domains. The unpacker reserves space for its pending read.
rgb_unpack128_to64 #(.FRAME_WIDTH(FRAME_WIDTH), .FRAME_HEIGHT(FRAME_HEIGHT)) u_unpack (
    .clk(o_clk), .rst_n(rd_rst_n), .frame_period(fifo_rd_period),
    .fifo_data(rd_fifo_data), .fifo_empty(rd_fifo_empty), .fifo_read(rd_fifo_read),
    .m_axis_tdata(m_axis_tdata), .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready), .m_axis_tuser(m_axis_tuser), .m_axis_tlast(m_axis_tlast)
);
// synthesis translate_off
initial if(D_MODE && (WRITE_FIFO_HIGH>=RD_FIFO_DEPTH || WRITE_FIFO_LOW<16))
    $fatal(1,"Display service watermarks must fit the actual FIFO depth");
initial begin
    if(BLIT_ENABLE && (!C_MODE || !D_MODE)) $fatal(1,"BLIT requires the double-buffered platform");
    if(COLOR_KEY_ENABLE && !BLIT_ENABLE) $fatal(1,"Color key requires BLIT support");
    if(D_MODE && (!C_MODE || AXI_ID_WIDTH!=4 || AXI_ADDR_WIDTH!=32 || BUFFER0_BASE!=0 ||
       BUFFER1_BASE!=32'h00800000 || FRAME_WIDTH*FRAME_HEIGHT*4>32'h00800000))
        $fatal(1,"Unsupported D slot geometry");
    if (FRAME_WIDTH % 4 != 0 || FRAME_BEATS < 512 || AXI_ID_WIDTH > 6)
        $fatal(1, "Unsupported RGB framebuffer geometry/legacy burst length");
end
// synthesis translate_on
endmodule
