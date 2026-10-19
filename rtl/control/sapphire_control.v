// CPU/APB control island. Commands/status connect to the platform-owned DMA.
// Sapphire itself has no DDR-facing port.
module sapphire_control #(
    parameter COLOR_KEY_ENABLE = 0
)(
    input wire core_clk,
    input wire platform_rst_n,
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
    output wire start_test_pulse
);
// Only the control island uses this asynchronous assertion/synchronous release.
// Neither this reset nor Sapphire debug reset feeds the video or DDR resets.
(* async_reg = "true" *) reg [2:0] reset_release = 0;
always @(posedge core_clk or negedge platform_rst_n)
    if (!platform_rst_n) reset_release <= 0;
    else reset_release <= {reset_release[1:0],1'b1};
wire soc_rst_n = reset_release[2];
wire system_reset;
wire [15:0] apb_addr;
wire [31:0] apb_wdata, apb_rdata;
wire apb_sel, apb_enable, apb_write, apb_ready, apb_error;

// Ports are taken from the user's generated ip/soc_control/soc_control_tmpl.v.
soc_control u_soc_control (
    .io_systemClk(core_clk), .io_asyncReset(!soc_rst_n),
    .io_systemReset(system_reset),
    .jtagCtrl_tck(jtag_tck), .jtagCtrl_tdi(jtag_tdi), .jtagCtrl_tdo(jtag_tdo),
    .jtagCtrl_enable(jtag_sel), .jtagCtrl_capture(jtag_capture),
    .jtagCtrl_shift(jtag_shift), .jtagCtrl_update(jtag_update), .jtagCtrl_reset(jtag_reset),
    .io_apbSlave_0_PADDR(apb_addr), .io_apbSlave_0_PSEL(apb_sel),
    .io_apbSlave_0_PENABLE(apb_enable), .io_apbSlave_0_PWRITE(apb_write),
    .io_apbSlave_0_PWDATA(apb_wdata), .io_apbSlave_0_PRDATA(apb_rdata),
    .io_apbSlave_0_PREADY(apb_ready), .io_apbSlave_0_PSLVERROR(apb_error)
);
accel_regs #(.ENGINE_ENABLE(1),.DOUBLE_BUFFER(1),.BLIT_ENABLE(1),.COLOR_KEY_ENABLE(COLOR_KEY_ENABLE)) u_accel_regs (
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
    .start_pulse(start_test_pulse)
);
endmodule
