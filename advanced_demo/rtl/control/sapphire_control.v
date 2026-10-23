// CPU/APB control island and the platform-reset CPU DDR safety bridge.
module sapphire_control #(
    parameter COLOR_KEY_ENABLE = 0,
    parameter CPU_DDR_ENABLE = 0,
    parameter ALPHA_ENABLE = 0
)(
    input wire core_clk,
    input wire platform_rst_n,
    input wire platform_ddr_rst_n,
    input wire uart_rx, output wire uart_tx,
    output wire flash_cs_n, output wire flash_sck, output wire flash_mosi,
    input wire flash_miso,
    input wire jtag_tck, input wire jtag_tdi, output wire jtag_tdo,
    input wire jtag_sel, input wire jtag_capture, input wire jtag_shift,
    input wire jtag_update, input wire jtag_reset,
    input wire [31:0] display_buffer_base,
    input wire [31:0] tpg_write_buffer_base,
    input wire init_done,input wire [31:0] init_error,
    input wire engine_busy,engine_done,input wire [31:0] engine_error,command_count,
    input wire [31:0] init_data_beats,init_aw_bursts,init_wlast_bursts,init_b_responses,init_aw_beats,
    output wire [31:0] cmd_x,cmd_y,cmd_width,cmd_height,cmd_color,
    output wire [31:0] cmd_op,cmd_src_addr,cmd_src_stride,
    input wire draw_ready,input wire [31:0] buffer_status,
    input wire [31:0] reader_frame_base,reader_outstanding,reader_data_beats,reader_reserved_beats,reader_error,
    input wire [31:0] boundary_count,swap_count,missed_boundary_count,
    input wire [31:0] service_status,writer_throttle_cycles,writer_bursts,
    input wire [31:0] reader_ar_stall_cycles,reader_ar_max_stall,reader_r_stall_cycles,
    input wire [31:0] reader_r_max_stall,display_underflow_count,reader_frame_completions,
    input wire [31:0] reader_fifo_level,writer_max_cycles,service_read_quota,
    input wire [31:0] service_watermarks,
    output wire swap_request,clear_swap_done,
    output wire start_test_pulse,
    input wire cpu_ddr_session_active,
    input wire [31:0] cpu_ddr_session_status,
    output wire cpu_ddr_acquire, cpu_ddr_release, cpu_ddr_clear_error,
    input wire [31:0] asset_status,
    output wire asset_begin,asset_seal,
    input wire [31:0] sprite_status,
    output wire sprite_begin,sprite_seal,
    output wire cpu_ddr_busy, output wire [31:0] cpu_ddr_error,
    output wire [31:0] cpu_awaddr, output wire cpu_awvalid, input wire cpu_awready,
    output wire [127:0] cpu_wdata, output wire [15:0] cpu_wstrb,
    output wire cpu_wlast,cpu_wvalid,input wire cpu_wready,
    input wire [3:0] cpu_bid,input wire [1:0] cpu_bresp,input wire cpu_bvalid,output wire cpu_bready,
    output wire [31:0] cpu_araddr,output wire cpu_arvalid,input wire cpu_arready,
    input wire [127:0] cpu_rdata,input wire [3:0] cpu_rid,input wire [1:0] cpu_rresp,
    input wire cpu_rlast,input wire cpu_rvalid,output wire cpu_rready
);
// Only the control island uses this asynchronous assertion/synchronous release.
// Neither this reset nor Sapphire debug reset feeds the video or DDR resets.
(* async_reg = "true" *) reg [2:0] reset_release = 0;
always @(posedge core_clk or negedge platform_rst_n)
    if (!platform_rst_n) reset_release <= 0;
    else reset_release <= {reset_release[1:0],1'b1};
wire soc_rst_n = reset_release[2];
(* async_reg = "true" *) reg [2:0] ddr_reset_release = 0;
always @(posedge core_clk or negedge platform_ddr_rst_n)
    if(!platform_ddr_rst_n) ddr_reset_release<=0;
    else ddr_reset_release<={ddr_reset_release[1:0],1'b1};
wire cpu_bridge_rst_n=ddr_reset_release[2];
wire system_reset;
wire [15:0] apb_addr;
wire [31:0] apb_wdata, apb_rdata;
wire apb_sel, apb_enable, apb_write, apb_ready, apb_error;
wire memory_reset;
wire [31:0] s_awaddr,s_araddr;
wire [7:0] s_awid,s_arid,s_bid,s_rid,s_awlen,s_arlen;
wire [2:0] s_awsize,s_arsize;
wire [1:0] s_awburst,s_arburst,s_bresp,s_rresp;
wire s_awlock,s_arlock,s_awvalid,s_awready,s_wlast,s_wvalid,s_wready;
wire s_bvalid,s_bready,s_arvalid,s_arready,s_rlast,s_rvalid,s_rready;
wire [127:0] s_wdata,s_rdata;
wire [15:0] s_wstrb;

// UART0 ports are taken from the regenerated ip/soc_control/soc_control_tmpl.v.
// The board's RX pad drives the SoC receiver; the SoC transmitter drives TX.
soc_control u_soc_control (
    .io_systemClk(core_clk), .io_asyncReset(!soc_rst_n),
    .io_systemReset(system_reset),.io_memoryClk(core_clk),.io_memoryReset(memory_reset),
    .jtagCtrl_tck(jtag_tck), .jtagCtrl_tdi(jtag_tdi), .jtagCtrl_tdo(jtag_tdo),
    .jtagCtrl_enable(jtag_sel), .jtagCtrl_capture(jtag_capture),
    .jtagCtrl_shift(jtag_shift), .jtagCtrl_update(jtag_update), .jtagCtrl_reset(jtag_reset),
    .io_apbSlave_0_PADDR(apb_addr), .io_apbSlave_0_PSEL(apb_sel),
    .io_apbSlave_0_PENABLE(apb_enable), .io_apbSlave_0_PWRITE(apb_write),
    .io_apbSlave_0_PWDATA(apb_wdata), .io_apbSlave_0_PRDATA(apb_rdata),
    .io_apbSlave_0_PREADY(apb_ready), .io_apbSlave_0_PSLVERROR(apb_error),
    .system_uart_0_io_rxd(uart_rx), .system_uart_0_io_txd(uart_tx),
    // Single SPI: IO0=MOSI, IO1=MISO; board pullups retain WP#/HOLD#.
    .system_spi_0_io_data_0_read(1'b1),
    .system_spi_0_io_data_0_write(flash_mosi), .system_spi_0_io_data_0_writeEnable(),
    .system_spi_0_io_data_1_read(flash_miso),
    .system_spi_0_io_data_1_write(), .system_spi_0_io_data_1_writeEnable(),
    .system_spi_0_io_data_2_read(1'b1),
    .system_spi_0_io_data_2_write(), .system_spi_0_io_data_2_writeEnable(),
    .system_spi_0_io_data_3_read(1'b1),
    .system_spi_0_io_data_3_write(), .system_spi_0_io_data_3_writeEnable(),
    .system_spi_0_io_sclk_write(flash_sck), .system_spi_0_io_ss(flash_cs_n),
    .io_ddrA_aw_payload_addr(s_awaddr),.io_ddrA_aw_payload_id(s_awid),
    .io_ddrA_aw_payload_len(s_awlen),.io_ddrA_aw_payload_size(s_awsize),
    .io_ddrA_aw_payload_burst(s_awburst),.io_ddrA_aw_payload_lock(s_awlock),
    .io_ddrA_aw_valid(s_awvalid),.io_ddrA_aw_ready(s_awready),
    .io_ddrA_w_payload_data(s_wdata),.io_ddrA_w_payload_strb(s_wstrb),
    .io_ddrA_w_payload_last(s_wlast),.io_ddrA_w_valid(s_wvalid),.io_ddrA_w_ready(s_wready),
    .io_ddrA_b_payload_id(s_bid),.io_ddrA_b_payload_resp(s_bresp),
    .io_ddrA_b_valid(s_bvalid),.io_ddrA_b_ready(s_bready),
    .io_ddrA_ar_payload_addr(s_araddr),.io_ddrA_ar_payload_id(s_arid),
    .io_ddrA_ar_payload_len(s_arlen),.io_ddrA_ar_payload_size(s_arsize),
    .io_ddrA_ar_payload_burst(s_arburst),.io_ddrA_ar_payload_lock(s_arlock),
    .io_ddrA_ar_valid(s_arvalid),.io_ddrA_ar_ready(s_arready),
    .io_ddrA_r_payload_data(s_rdata),.io_ddrA_r_payload_id(s_rid),
    .io_ddrA_r_payload_resp(s_rresp),.io_ddrA_r_payload_last(s_rlast),
    .io_ddrA_r_valid(s_rvalid),.io_ddrA_r_ready(s_rready),
    // AXI Slave 0 remains enabled in the generated IP but has no external
    // master in this design. Tie every request input low in its own domain.
    .io_ddrMasters_0_clk(core_clk),.io_ddrMasters_0_aw_valid(1'b0),
    .io_ddrMasters_0_aw_payload_addr(32'b0),.io_ddrMasters_0_aw_payload_id(4'b0),
    .io_ddrMasters_0_aw_payload_region(4'b0),.io_ddrMasters_0_aw_payload_len(8'b0),
    .io_ddrMasters_0_aw_payload_size(3'b0),.io_ddrMasters_0_aw_payload_burst(2'b0),
    .io_ddrMasters_0_aw_payload_lock(1'b0),.io_ddrMasters_0_aw_payload_cache(4'b0),
    .io_ddrMasters_0_aw_payload_qos(4'b0),.io_ddrMasters_0_aw_payload_prot(3'b0),
    .io_ddrMasters_0_w_valid(1'b0),.io_ddrMasters_0_w_payload_data(32'b0),
    .io_ddrMasters_0_w_payload_strb(4'b0),.io_ddrMasters_0_w_payload_last(1'b0),
    .io_ddrMasters_0_b_ready(1'b1),.io_ddrMasters_0_ar_valid(1'b0),
    .io_ddrMasters_0_ar_payload_addr(32'b0),.io_ddrMasters_0_ar_payload_id(4'b0),
    .io_ddrMasters_0_ar_payload_region(4'b0),.io_ddrMasters_0_ar_payload_len(8'b0),
    .io_ddrMasters_0_ar_payload_size(3'b0),.io_ddrMasters_0_ar_payload_burst(2'b0),
    .io_ddrMasters_0_ar_payload_lock(1'b0),.io_ddrMasters_0_ar_payload_cache(4'b0),
    .io_ddrMasters_0_ar_payload_qos(4'b0),.io_ddrMasters_0_ar_payload_prot(3'b0),
    .io_ddrMasters_0_r_ready(1'b1)
);
generate if(CPU_DDR_ENABLE) begin: cpu_ddr
    cpu_ddr_bridge #(.SPRITE_ENABLE(ALPHA_ENABLE)) bridge (
        .clk(core_clk),.rst_n(cpu_bridge_rst_n),.cpu_reset(system_reset || memory_reset),
        .session_active(cpu_ddr_session_active),
        .asset_loading(asset_status[0]),.asset_ready(asset_status[1]),
        .sprite_loading(sprite_status[0]),.sprite_ready(sprite_status[1]),
        .front_base(display_buffer_base),.back_base(tpg_write_buffer_base),
        .busy(cpu_ddr_busy),.error_code(cpu_ddr_error),.clear_error(cpu_ddr_clear_error),
        .s_awaddr(s_awaddr),.s_awid(s_awid),.s_awlen(s_awlen),.s_awsize(s_awsize),
        .s_awburst(s_awburst),.s_awlock(s_awlock),.s_awvalid(s_awvalid),.s_awready(s_awready),
        .s_wdata(s_wdata),.s_wstrb(s_wstrb),.s_wlast(s_wlast),.s_wvalid(s_wvalid),.s_wready(s_wready),
        .s_bid(s_bid),.s_bresp(s_bresp),.s_bvalid(s_bvalid),.s_bready(s_bready),
        .s_araddr(s_araddr),.s_arid(s_arid),.s_arlen(s_arlen),.s_arsize(s_arsize),
        .s_arburst(s_arburst),.s_arlock(s_arlock),.s_arvalid(s_arvalid),.s_arready(s_arready),
        .s_rdata(s_rdata),.s_rid(s_rid),.s_rresp(s_rresp),.s_rlast(s_rlast),
        .s_rvalid(s_rvalid),.s_rready(s_rready),
        .m_awaddr(cpu_awaddr),.m_awvalid(cpu_awvalid),.m_awready(cpu_awready),
        .m_wdata(cpu_wdata),.m_wstrb(cpu_wstrb),.m_wlast(cpu_wlast),
        .m_wvalid(cpu_wvalid),.m_wready(cpu_wready),
        .m_bid(cpu_bid),.m_bresp(cpu_bresp),.m_bvalid(cpu_bvalid),.m_bready(cpu_bready),
        .m_araddr(cpu_araddr),.m_arvalid(cpu_arvalid),.m_arready(cpu_arready),
        .m_rdata(cpu_rdata),.m_rid(cpu_rid),.m_rresp(cpu_rresp),.m_rlast(cpu_rlast),
        .m_rvalid(cpu_rvalid),.m_rready(cpu_rready)
    );
end else begin: no_cpu_ddr
    assign s_awready=0;assign s_wready=0;assign s_bid=0;assign s_bresp=2'b11;
    assign s_bvalid=0;assign s_arready=0;assign s_rdata=0;assign s_rid=0;
    assign s_rresp=2'b11;assign s_rlast=0;assign s_rvalid=0;
    assign cpu_ddr_busy=0;assign cpu_ddr_error=0;
    assign cpu_awaddr=0;assign cpu_awvalid=0;assign cpu_wdata=0;assign cpu_wstrb=0;
    assign cpu_wlast=0;assign cpu_wvalid=0;assign cpu_bready=0;
    assign cpu_araddr=0;assign cpu_arvalid=0;assign cpu_rready=0;
end endgenerate
accel_regs #(.ENGINE_ENABLE(1),.DOUBLE_BUFFER(1),.BLIT_ENABLE(1),
    .COLOR_KEY_ENABLE(COLOR_KEY_ENABLE),.CPU_DDR_ENABLE(CPU_DDR_ENABLE),
    .ALPHA_ENABLE(ALPHA_ENABLE)) u_accel_regs (
    .PCLK(core_clk), .PRESETn(soc_rst_n && !system_reset),
    .PADDR({16'b0,apb_addr}), .PSEL(apb_sel), .PENABLE(apb_enable), .PWRITE(apb_write),
    .PWDATA(apb_wdata), .PRDATA(apb_rdata), .PREADY(apb_ready), .PSLVERROR(apb_error),
    .display_buffer_base(display_buffer_base), .tpg_write_buffer_base(tpg_write_buffer_base),
    .init_done(init_done),.init_error(init_error),.engine_busy(engine_busy),.engine_done(engine_done),
    .engine_error(engine_error),.command_count(command_count),
    .init_data_beats(init_data_beats),.init_aw_bursts(init_aw_bursts),.init_wlast_bursts(init_wlast_bursts),
    .init_b_responses(init_b_responses),.init_aw_beats(init_aw_beats),
    .cmd_x(cmd_x),.cmd_y(cmd_y),.cmd_width(cmd_width),.cmd_height(cmd_height),.cmd_color(cmd_color),
    .cmd_op(cmd_op),.cmd_src_addr(cmd_src_addr),.cmd_src_stride(cmd_src_stride),
    .draw_ready(draw_ready),.buffer_status(buffer_status),
    .reader_frame_base(reader_frame_base),.reader_outstanding(reader_outstanding),
    .reader_data_beats(reader_data_beats),.reader_reserved_beats(reader_reserved_beats),.reader_error(reader_error),
    .boundary_count(boundary_count),.swap_count(swap_count),.missed_boundary_count(missed_boundary_count),
    .service_status(service_status),.writer_throttle_cycles(writer_throttle_cycles),.writer_bursts(writer_bursts),
    .reader_ar_stall_cycles(reader_ar_stall_cycles),.reader_ar_max_stall(reader_ar_max_stall),.reader_r_stall_cycles(reader_r_stall_cycles),
    .reader_r_max_stall(reader_r_max_stall),.display_underflow_count(display_underflow_count),.reader_frame_completions(reader_frame_completions),
    .reader_fifo_level(reader_fifo_level),.writer_max_cycles(writer_max_cycles),.service_read_quota(service_read_quota),
    .service_watermarks(service_watermarks),
    .swap_request(swap_request),.clear_swap_done(clear_swap_done),
    .start_pulse(start_test_pulse),
    .cpu_ddr_status(cpu_ddr_session_status),.cpu_ddr_busy(cpu_ddr_busy),
    .cpu_ddr_error(cpu_ddr_error),.cpu_ddr_acquire(cpu_ddr_acquire),
    .cpu_ddr_release(cpu_ddr_release),.cpu_ddr_clear_error(cpu_ddr_clear_error),
    .asset_status(asset_status),.asset_begin(asset_begin),.asset_seal(asset_seal),
    .sprite_status(sprite_status),.sprite_begin(sprite_begin),.sprite_seal(sprite_seal)
);
endmodule
