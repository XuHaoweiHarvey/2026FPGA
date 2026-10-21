
/////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2013-2021 Efinix Inc. All rights reserved.
//
// Description:
// Example top file for ti60f225 dev kit OOB design
//
// Language:  Verilog 2001
//Ti60f225_sc431hai2hdmi_v6：
//使用了最新版本的framebuffer_v3;
// ------------------------------------------------------------------------------

/////////////////////////////////////////////////////////////////////////////////
//`define SOFT_TAP 1
`include "ddr3_controller/ddr3_parameter.vh"
`include "test_pattern/rgb_tpg_config.vh"
// `include "define.v"

module ti60f225_oob_top #(

	parameter                       RANK_RATIO         = 1,       // # of unique CS outputs per rank
	parameter                       ASYN_AXI_CLK       = `ASYN_AXI_CLK, 
	parameter                       RANKS              = `RANKS,
	parameter                       CK_WIDTH           = `CK_WIDTH,       // # of CK/CK# outputs to memory   
	parameter                       CKE_WIDTH          = `CKE_WIDTH,       // # of cke outputs
	parameter                       CS_WIDTH           = `CS_WIDTH,       // # of unique CS outputs
	parameter                       BANK_WIDTH         = `BANK_WIDTH,       // # of bank bits
	parameter                       ROW_WIDTH          = `ROW_WIDTH,       // DRAM address bus width
	parameter                       COL_WIDTH          = `COL_WIDTH,      // column address width
	parameter                       DM_WIDTH           = `DM_WIDTH,       // # of DM (data mask)
	parameter                       DQS_WIDTH          = `DQS_WIDTH,       // # of DQS (strobe)
	parameter                       DQ_WIDTH           = `DQ_WIDTH,      // # of DQ (data)
	parameter                       ODT_WIDTH          = `ODT_WIDTH,
	parameter                       DQ_CNT_WIDTH       = `DQ_CNT_WIDTH,       // = ceil(log2(DQ_WIDTH))
	parameter                       DQS_CNT_WIDTH      = `DQS_CNT_WIDTH,       // = ceil(log2(DQS_WIDTH))  
	parameter                       DRAM_WIDTH         = `DRAM_WIDTH,       // # of DQ per DQS   
	parameter                       DATA_WIDTH         = `DATA_WIDTH,
	parameter                       ADDR_WIDTH         = `ADDR_WIDTH,    
	parameter                       AXI_ID_WIDTH       = `AXI_ID_WIDTH,
	parameter                       AXI_ADDR_WIDTH     = `AXI_ADDR_WIDTH,
	parameter                       AXI_DATA_WIDTH     = `AXI_DATA_WIDTH
)
(

  (* syn_peri_port = 0 *) input jtag_inst1_CAPTURE,
  (* syn_peri_port = 0 *) input jtag_inst1_DRCK,
  (* syn_peri_port = 0 *) input jtag_inst1_RESET,
  (* syn_peri_port = 0 *) input jtag_inst1_RUNTEST,
  (* syn_peri_port = 0 *) input jtag_inst1_SEL,
  (* syn_peri_port = 0 *) input jtag_inst1_SHIFT,
  (* syn_peri_port = 0 *) input jtag_inst1_TCK,
  (* syn_peri_port = 0 *) input jtag_inst1_TDI,
  (* syn_peri_port = 0 *) input jtag_inst1_TMS,
  (* syn_peri_port = 0 *) input jtag_inst1_UPDATE,
  (* syn_peri_port = 0 *) output jtag_inst1_TDO,

   //Clocks 
	input	wire	i_arstn,
    input	wire	i_mipi_rx_pclk,
    input wire  vid_clk_dvi2,
    input wire hdmi_tx_slow_clk,
    input wire CLK_5M,
    input  wire CLK_25M,
	output  wire    pll_inst1_RSTN,
	input	wire	i_pll_locked,
	input 	wire  	pll_locked,
	output  wire    pll_inst4_RSTN,
	input   wire    pll_inst4_LOCKED,
	output  wire  	USER_PLL_RSTN,
    output 	wire 	DDR3_PLL_RSTN,
	input 	wire  	user_pll_locked,
    //CSI Interface
    input	 wire		io_cam_sda_IN,
    output wire   io_cam_sda_OUT,
    output wire		io_cam_sda_OE,

    output io_cam_scl_OUT,
    input io_cam_scl_IN,
    output io_cam_scl_OE,

    output	wire		o_cam_rst_p,
    
    input	wire		i_cam_ck_LP_P_IN,
    input	wire		i_cam_ck_LP_N_IN,
    output	wire		o_cam_ck_HS_TERM,
    output	wire		o_cam_ck_HS_ENA,
    input	wire		i_cam_ck_CLKOUT,
    
    input	wire	[7:0]			cam_d0_HS_IN,
    input	  wire		      cam_d0_LP_P_IN,
    input	  wire		      cam_d0_LP_N_IN,
    output	wire		      cam_d0_HS_TERM,
    output	wire		      cam_d0_HS_ENA,
    output	wire		      cam_d0_RST,
    output	wire		      cam_d0_FIFO_RD,
    input	  wire		      cam_d0_FIFO_EMPTY,
    
    input 	wire	[7:0]			cam_d1_HS_IN,
    input	  wire		        cam_d1_LP_P_IN,
    input	  wire		        cam_d1_LP_N_IN,
    output	wire		        cam_d1_HS_TERM,
    output	wire		        cam_d1_HS_ENA,
    output	wire		        cam_d1_RST,
    output	wire		        cam_d1_FIFO_RD,
    input	  wire		        cam_d1_FIFO_EMPTY,
    
    input 	wire	[7:0]			cam_d2_HS_IN,
    input	  wire		        cam_d2_LP_P_IN,
    input	  wire		        cam_d2_LP_N_IN,
    output	wire		        cam_d2_HS_TERM,
    output	wire		        cam_d2_HS_ENA,
    output	wire		        cam_d2_RST,
    output	wire		        cam_d2_FIFO_RD,
    input	  wire		        cam_d2_FIFO_EMPTY,  
   
    input 	wire	[7:0]			cam_d3_HS_IN,
    input	  wire		        cam_d3_LP_P_IN,
    input	  wire		        cam_d3_LP_N_IN,
    output	wire		        cam_d3_HS_TERM,
    output	wire		        cam_d3_HS_ENA,
    output	wire		        cam_d3_RST,
    output	wire		        cam_d3_FIFO_RD,
    input	  wire		        cam_d3_FIFO_EMPTY,

	
	input 					tx_cal_clk_90edge,
  	input 					rx_cal_clk,
  	input 					tx_cal_clk,
	input                              core_clk,     // CORE CLK @ 100MHz
	input                              sdram_clk,    // SDRAM CK @ 400MHz
	// PLL status flags  
	output [2:0]                       pll_shift,  
	output [4:0]                       pll_shift_sel,
	output                             pll_shift_ena,  
	// memory interface ports
	output                             ddr_ck_hi,
	output                             ddr_ck_lo,
	output                             ddr_reset_n,
	output [CKE_WIDTH-1:0]             ddr_cke,     
	output [ROW_WIDTH-1:0]             ddr_addr,
	output [BANK_WIDTH-1:0]            ddr_ba,
	output                             ddr_cas_n,
 
	output [CS_WIDTH*RANK_RATIO-1:0]   ddr_cs_n,
	output                             ddr_ras_n,
	output                             ddr_we_n,
	
	input  [DQS_WIDTH-1:0]             ddr_dqs_in_hi,
	input  [DQS_WIDTH-1:0]             ddr_dqs_in_lo,
	input  [DQ_WIDTH-1:0]              ddr_dq_in_hi,
	input  [DQ_WIDTH-1:0]              ddr_dq_in_lo,
	
	output [DQS_WIDTH-1:0]             ddr_dqs_oe,
	output [DQS_WIDTH-1:0]             ddr_dqs_oe_n,
	output [DQ_WIDTH-1:0]              ddr_dq_oe,  
	output [DQS_WIDTH-1:0]             ddr_dqs_out_hi,
	output [DQS_WIDTH-1:0]             ddr_dqs_out_lo,
	output [DQ_WIDTH-1:0]              ddr_dq_out_hi,
	output [DQ_WIDTH-1:0]              ddr_dq_out_lo,
	output [DM_WIDTH-1:0]              ddr_dm_hi,
	output [DM_WIDTH-1:0]              ddr_dm_lo,
	output [ODT_WIDTH-1:0]             ddr_odt,

       //LED
       output [7:0] led,

       // MIPI DSI
       input	wire	                     i_mipi_tx_pclk		,
       output	wire	                     mipi_dp_clk_LP_P_OUT		,
       output	wire	                     mipi_dp_clk_LP_N_OUT		,
       output	wire	[7:0] 	              mipi_dp_clk_HS_OUT		,
       output	wire	                     mipi_dp_clk_HS_OE		,
       output	wire	                     mipi_dp_data3_LP_P_OUT	,
       output	wire	                     mipi_dp_data2_LP_P_OUT	,
       output	wire	                     mipi_dp_data1_LP_P_OUT	,
       output	wire	                     mipi_dp_data0_LP_P_OUT	,
       output	wire	                     mipi_dp_data3_LP_N_OUT	,
       output	wire	                     mipi_dp_data2_LP_N_OUT	,
       output	wire	                     mipi_dp_data1_LP_N_OUT	,
       output	wire	                     mipi_dp_data0_LP_N_OUT	,
       output	wire	[7:0] 	              mipi_dp_data0_HS_OUT	       ,
       output	wire	[7:0] 	              mipi_dp_data1_HS_OUT	       ,
       output	wire	[7:0] 	              mipi_dp_data2_HS_OUT	       ,
       output	wire	[7:0] 	              mipi_dp_data3_HS_OUT	       ,
       output	wire	                     mipi_dp_data3_HS_OE		,
       output	wire	                     mipi_dp_data2_HS_OE		,
       output	wire	                     mipi_dp_data1_HS_OE		,
       output	wire	                     mipi_dp_data0_HS_OE		,

       output	wire	                     mipi_dp_clk_RST		,
       output	wire	                     mipi_dp_data0_RST		,
       output	wire	                     mipi_dp_data1_RST		,
       output	wire	                     mipi_dp_data2_RST		,
       output	wire	                     mipi_dp_data3_RST		,
       output	wire	                     mipi_dp_clk_LP_P_OE		,
       output	wire	                     mipi_dp_clk_LP_N_OE		,
       output	wire	                     mipi_dp_data3_LP_P_OE	,
       output	wire	                     mipi_dp_data3_LP_N_OE	,
       output	wire	                     mipi_dp_data2_LP_P_OE	,
       output	wire	                     mipi_dp_data2_LP_N_OE	,
       output	wire	                     mipi_dp_data1_LP_P_OE	,
       output	wire	                     mipi_dp_data1_LP_N_OE	,
       output	wire	                     mipi_dp_data0_LP_P_OE	,
       output	wire	                     mipi_dp_data0_LP_N_OE	,

       input  wire	                     mipi_dp_data0_LP_P_IN	,
       input  wire	                     mipi_dp_data0_LP_N_IN	,
       output	wire	                     LCD_RST_P			,
       output wire                        LCD_POWER			,

       // hdmi interface

    output tmds_tx_clk_TX_OE,
    output [9:0] tmds_tx_clk_TX_DATA,
    output tmds_tx_clk_TX_RST,
    output tmds_tx_data0_TX_OE,
    output [9:0] tmds_tx_data0_TX_DATA,
    output tmds_tx_data0_TX_RST,
    output tmds_tx_data1_TX_OE,
    output [9:0] tmds_tx_data1_TX_DATA,
    output tmds_tx_data1_TX_RST,
    output tmds_tx_data2_TX_OE,
    output [9:0] tmds_tx_data2_TX_DATA,
    output tmds_tx_data2_TX_RST


);

function integer log2;
	input	integer	val;
	integer	i;
	begin
		log2 = 0;
		for (i=0; 2**i<val; i=i+1)
			log2 = i+1;
	end
endfunction


//===============================================================================
//localparam
//===============================================================================
localparam WR_FIFO_DEPTH  = 1024;
localparam RD_FIFO_DEPTH  = 1024;
// One switch keeps the APB capability and pixel execution path in agreement.
localparam COLOR_KEY_ENABLE = 1;

// localparam	MAX_HRES		= 12'd1920;
// localparam	MAX_VRES		= 12'd1080;
// localparam	HSP			= 8'd2;
// localparam	HBP			= 8'd88;
// localparam	HFP			= 8'd120;
// localparam	VSP			= 8'd2;
// localparam	VBP			= 8'd20;
// localparam	VFP			= 8'd20;

localparam HACT     = 1920;
localparam HFP      = 88;
localparam HSP      = 44;
localparam HBP      = 148;

localparam VACT     = 1080;
localparam VFP      = 4;
localparam VSP      = 5;
localparam VBP      = 36;
//===============================================================================
//signal
//===============================================================================
   
wire                              app_sr_active;
wire                              app_ref_ack;
wire                              app_zq_ack;
(* syn_keep = 1 *) wire cal_done;
(* syn_keep = 1 *) wire [7:0] wrlvl_dq_check;
(* syn_keep = 1 *) wire [7:0] rd_level_dqs_check;
(* syn_keep = 1 *) wire [6:0] init_cur_state;
(* syn_keep = 1 *) wire idelay_ld;
(* syn_keep = 1 *) wire mpr_rdlvl_dly;

// Slave Interface Write Address Ports
wire [AXI_ID_WIDTH-1:0]           s_axi_awid;
wire [AXI_ADDR_WIDTH-1:0]         s_axi_awaddr;
wire [7:0]                        s_axi_awlen;
wire [2:0]                        s_axi_awsize;
wire [1:0]                        s_axi_awburst;
wire [0:0]                        s_axi_awlock;
wire [3:0]                        s_axi_awcache;
wire [2:0]                        s_axi_awprot;
wire                              s_axi_awvalid;
wire                              s_axi_awready;
// Slave Interface Write Data Ports
wire [AXI_DATA_WIDTH-1:0]         s_axi_wdata;
wire [(AXI_DATA_WIDTH/8)-1:0]     s_axi_wstrb;
wire                              s_axi_wlast;
wire                              s_axi_wvalid;
wire                              s_axi_wready;
// Slave Interface Write Response Ports
wire                              s_axi_bready;
wire [AXI_ID_WIDTH-1:0]           s_axi_bid;
wire [1:0]                        s_axi_bresp;
wire                              s_axi_bvalid;
// Slave Interface Read Address Ports
wire [AXI_ID_WIDTH-1:0]           s_axi_arid;
wire [AXI_ADDR_WIDTH-1:0]         s_axi_araddr;
wire [7:0]                        s_axi_arlen;
wire [2:0]                        s_axi_arsize;
wire [1:0]                        s_axi_arburst;
wire [0:0]                        s_axi_arlock;
wire [3:0]                        s_axi_arcache;
wire [2:0]                        s_axi_arprot;
wire                              s_axi_arvalid;
wire                              s_axi_arready;
// Slave Interface Read Data Ports
wire                              s_axi_rready;
wire [AXI_ID_WIDTH-1:0]           s_axi_rid;
wire [AXI_DATA_WIDTH-1:0]         s_axi_rdata;
wire [1:0]                        s_axi_rresp;
wire                              s_axi_rlast;
wire                              s_axi_rvalid;




////////////////////////////////////////////////////////////////
// System & Debugger
wire    w_arstn;
// wire	w_sysclk_mcu_arstn;
// wire	w_sysclk_mcu_arst;
wire	w_mipi_rx_pclk_arstn;
wire	w_mipi_rx_pclk_arst;



wire					io_systemReset;



//===================================================================================================
//reset module
//===================================================================================================

assign w_arstn  		       = i_pll_locked & pll_locked & user_pll_locked;
assign pll_inst1_RSTN  		= i_arstn;
assign USER_PLL_RSTN      		= i_arstn;
assign mipi_dsi_tx_pll_RSTN 	= i_arstn;
assign DDR3_PLL_RSTN 		= i_arstn;
reset_ctrl
#(
	.NUM_RST		(2),
	.CYCLE			(1),
	.IN_RST_ACTIVE	(4'b00),
	.OUT_RST_ACTIVE	(4'b10)
)
inst_reset_ctrl
(
	.i_arst		({2{w_arstn}}),//({{4{i_pll_locked}},                  {2{i_arstn}}}),
	.i_clk			({2{i_mipi_rx_pclk}}),
	.o_srst		({w_mipi_rx_pclk_arst, w_mipi_rx_pclk_arstn})
);



reg [25:0] cnt = 'd0;
always @( posedge core_clk)
begin 
       cnt <= cnt + 1'b1;
end
assign led[0]  = cal_done ? cnt[24] : 1'b0;

//========================================================================================================
//MIPI RX
//========================================================================================================
wire i_mipi_clk ;
assign i_mipi_clk = core_clk;

		assign	cam_d0_RST		= 1'b0;
		assign	cam_d1_RST		= 1'b0;
		assign  cam_d2_RST = 1'b0;
    assign  cam_d3_RST = 1'b0;
	
// Physical camera blocks and all top ports remain, but CSI/I2C RTL is inactive.
assign o_cam_ck_HS_ENA = 1'b0;
assign o_cam_ck_HS_TERM = 1'b0;
assign o_cam_rst_p = ~w_arstn;
assign io_cam_scl_OUT = 1'b1;
assign io_cam_sda_OUT = 1'b1;
assign io_cam_scl_OE = 1'b0;
assign io_cam_sda_OE = 1'b0;
assign cam_d0_HS_ENA = 1'b0;
assign cam_d0_HS_TERM = 1'b0;
assign cam_d0_FIFO_RD = 1'b0;
assign cam_d1_HS_ENA = 1'b0;
assign cam_d1_HS_TERM = 1'b0;
assign cam_d1_FIFO_RD = 1'b0;
assign cam_d2_HS_ENA = 1'b0;
assign cam_d2_HS_TERM = 1'b0;
assign cam_d2_FIFO_RD = 1'b0;
assign cam_d3_HS_ENA = 1'b0;
assign cam_d3_HS_TERM = 1'b0;
assign cam_d3_FIFO_RD = 1'b0;

wire tpg_rst_n;
wire vid_rst_n;
wire tpg_vs;
wire tpg_de;
wire [127:0] tpg_data;
(* syn_keep = 1 *) wire tpg_frame_start;
(* syn_keep = 1 *) wire [31:0] tpg_frame_count;
(* syn_keep = 1 *) wire [31:0] tpg_valid_word_count;
(* syn_keep = 1 *) wire [31:0] tpg_last_frame_word_count;
(* syn_keep = 1 *) wire wr_fifo_full;
(* syn_keep = 1 *) wire [1:0] wr_buffer_index;
(* syn_keep = 1 *) wire [1:0] rd_buffer_index;
wire [31:0] wr_buffer_base, rd_buffer_base;
wire tpg_source_done,fb_init_done,fill_busy,fill_done;
wire draw_ready,swap_request,clear_swap_done;
wire [31:0] buffer_status,reader_frame_base,reader_outstanding,reader_data_beats,reader_reserved_beats,reader_error;
wire [31:0] boundary_count,swap_count,missed_boundary_count;
wire [31:0] fb_init_error,fill_error,fill_command_count;
wire [31:0] init_data_beats,init_aw_bursts,init_wlast_bursts,init_b_responses,init_aw_beats;
wire [31:0] fill_x,fill_y,fill_width,fill_height,fill_color;
wire [31:0] graphics_op,graphics_src_addr,graphics_src_stride;
(* syn_keep = 1 *) wire read_underflow;
rst_n_piple #(.DLY(3)) u_tpg_reset (
    .clk(i_mipi_rx_pclk), .rst_n_i(vid_rst_n), .rst_n_o(tpg_rst_n)
);
rgb_tpg #(
    .H_ACTIVE(HACT), .V_ACTIVE(VACT), .ONE_FRAME(1),
    .H_BLANK_CYCLES(`RGB_TPG_H_BLANK_CYCLES),
    .V_BLANK_LINES(`RGB_TPG_V_BLANK_LINES),
    .BAR_RED(`RGB_TPG_BAR_RED), .BAR_GREEN(`RGB_TPG_BAR_GREEN),
    .BAR_BLUE(`RGB_TPG_BAR_BLUE), .BAR_WHITE(`RGB_TPG_BAR_WHITE)
) u_rgb_tpg (
    .clk(i_mipi_rx_pclk), .rst_n(tpg_rst_n),
    .vs(tpg_vs), .de(tpg_de), .data(tpg_data),
    .frame_start(tpg_frame_start), .frame_count(tpg_frame_count),
    .valid_word_count(tpg_valid_word_count),
    .last_frame_word_count(tpg_last_frame_word_count), .source_done(tpg_source_done)
);

//=====================================================================================
//frame buffer
//=====================================================================================
wire [63:0] ch0_data;
wire ch0_vs;
wire ch0_hs;
wire ch0_de;

wire  [63:0] m_axis_tdata;
wire           m_axis_tvalid;
wire           m_axis_tready;
wire           m_axis_tlast;
wire           m_axis_tuser;
wire  fifo_rd_period;
// Checkpoint D: TPG initializes Front0 once; engine writes the latched Back.
wire [31:0] service_status,writer_throttle_cycles,writer_bursts;
wire [31:0] reader_ar_stall_cycles,reader_ar_max_stall,reader_r_stall_cycles;
wire [31:0] reader_r_max_stall,display_underflow_count,reader_frame_completions;
wire [31:0] reader_fifo_level,writer_max_cycles,service_read_quota;
wire [31:0] service_watermarks;
wire cpu_ddr_acquire,cpu_ddr_release,cpu_ddr_clear_error,cpu_ddr_busy,cpu_ddr_session_active;
wire asset_begin,asset_seal;
wire [31:0] asset_status;
wire [31:0] cpu_ddr_session_status,cpu_ddr_error,cpu_awaddr,cpu_araddr;
wire cpu_awvalid,cpu_awready,cpu_wlast,cpu_wvalid,cpu_wready;
wire [127:0] cpu_wdata,cpu_rdata;
wire [15:0] cpu_wstrb;
wire [3:0] cpu_bid,cpu_rid;
wire [1:0] cpu_bresp,cpu_rresp;
wire cpu_bvalid,cpu_bready,cpu_arvalid,cpu_arready,cpu_rlast,cpu_rvalid,cpu_rready;
rgb_framebuffer #(
    .FRAME_WIDTH(HACT), .FRAME_HEIGHT(VACT),
    .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH), .AXI_ID_WIDTH(AXI_ID_WIDTH),
    .WR_FIFO_DEPTH(1024), .RD_FIFO_DEPTH(1024), .BURST_LEN(127), .C_MODE(1), .D_MODE(1), .BLIT_ENABLE(1),
    .COLOR_KEY_ENABLE(COLOR_KEY_ENABLE),.CPU_DDR_ENABLE(1)
) checker0(
    .diag_wr_fifo_full(wr_fifo_full),
    .diag_wr_bank(wr_buffer_index), .diag_rd_bank(rd_buffer_index),
    .diag_wr_base(wr_buffer_base), .diag_rd_base(rd_buffer_base),
    .draw_ready(draw_ready),.buffer_status(buffer_status),
    .reader_frame_base(reader_frame_base),.reader_outstanding(reader_outstanding),
    .reader_data_beats(reader_data_beats),.reader_reserved_beats(reader_reserved_beats),.reader_error(reader_error),
    .boundary_count(boundary_count),.swap_count(swap_count),.missed_boundary_count(missed_boundary_count),
    .service_status(service_status),.writer_throttle_cycles(writer_throttle_cycles),.writer_bursts(writer_bursts),
    .cpu_ddr_acquire(cpu_ddr_acquire),.cpu_ddr_release(cpu_ddr_release),
    .cpu_ddr_clear_error(cpu_ddr_clear_error),.cpu_ddr_busy(cpu_ddr_busy),
    .cpu_ddr_error(cpu_ddr_error),
    .asset_begin(asset_begin),.asset_seal(asset_seal),.asset_status(asset_status),
    .cpu_ddr_session_active(cpu_ddr_session_active),.cpu_ddr_session_status(cpu_ddr_session_status),
    .cpu_awaddr(cpu_awaddr),.cpu_awvalid(cpu_awvalid),.cpu_awready(cpu_awready),
    .cpu_wdata(cpu_wdata),.cpu_wstrb(cpu_wstrb),.cpu_wlast(cpu_wlast),
    .cpu_wvalid(cpu_wvalid),.cpu_wready(cpu_wready),
    .cpu_bid(cpu_bid),.cpu_bresp(cpu_bresp),.cpu_bvalid(cpu_bvalid),.cpu_bready(cpu_bready),
    .cpu_araddr(cpu_araddr),.cpu_arvalid(cpu_arvalid),.cpu_arready(cpu_arready),
    .cpu_rdata(cpu_rdata),.cpu_rid(cpu_rid),.cpu_rresp(cpu_rresp),
    .cpu_rlast(cpu_rlast),.cpu_rvalid(cpu_rvalid),.cpu_rready(cpu_rready),
    .reader_ar_stall_cycles(reader_ar_stall_cycles),.reader_ar_max_stall(reader_ar_max_stall),.reader_r_stall_cycles(reader_r_stall_cycles),
    .reader_r_max_stall(reader_r_max_stall),.display_underflow_count(display_underflow_count),.reader_frame_completions(reader_frame_completions),
    .reader_fifo_level(reader_fifo_level),.writer_max_cycles(writer_max_cycles),.service_read_quota(service_read_quota),
    .service_watermarks(service_watermarks),
    .swap_request(swap_request),.clear_swap_done(clear_swap_done),
    .source_done(tpg_source_done), .bresp(s_axi_bresp),
    .cmd_start(accel_start_test_pulse),.cmd_x(fill_x),.cmd_y(fill_y),
    .cmd_width(fill_width),.cmd_height(fill_height),.cmd_color(fill_color),
    .cmd_op(graphics_op),.cmd_src_addr(graphics_src_addr),.cmd_src_stride(graphics_src_stride),
    .init_done(fb_init_done),.init_error(fb_init_error),
    .engine_busy(fill_busy),.engine_done(fill_done),.engine_error(fill_error),.command_count(fill_command_count),
    .init_data_beats(init_data_beats),.init_aw_bursts(init_aw_bursts),.init_wlast_bursts(init_wlast_bursts),
    .init_b_responses(init_b_responses),.init_aw_beats(init_aw_beats),
       .axi_clk		(core_clk 	        ),
       .rst_n			(vid_rst_n   ),

/*i*/.i_clk			(i_mipi_rx_pclk      ),
/*i*/.i_frame_start (tpg_frame_start),
/*i*/.i_de			(tpg_de),
/*i*/.vin 			(tpg_data),
                     
/*i*/.o_clk			(vid_clk_dvi2),//(i_mipi_rx_pclk	),                  
/*i*/.fifo_rd_period(fifo_rd_period),//(fifo_rd_period  ),

    .display_underflow(read_underflow),
    .m_axis_tdata  (m_axis_tdata),
    .m_axis_tvalid (m_axis_tvalid),
    .m_axis_tready (m_axis_tready),
    .m_axis_tuser  (m_axis_tuser),
    .m_axis_tlast  (m_axis_tlast),
	

       .awid			(s_axi_awid	),      
       .awaddr		(s_axi_awaddr	),
       .awlen			(s_axi_awlen	),
       .awsize		(s_axi_awsize	),
       .awburst		(s_axi_awburst),
       .awprot    (s_axi_awprot ),
       .awcache   (s_axi_awcache),
       .awlock		(s_axi_awlock	),
       .awvalid		(s_axi_awvalid),
       .awready		(s_axi_awready),

       .arid			(s_axi_arid	  ),
       .araddr		(s_axi_araddr	),
       .arlen			(s_axi_arlen	),
       .arsize		(s_axi_arsize	),
       .arburst 	(s_axi_arburst),

       .arprot    (s_axi_arprot ),
       .arcache   (s_axi_arcache),
       .arlock 		(s_axi_arlock	),
       .arvalid		(s_axi_arvalid),
       .arready		(s_axi_arready),

       .wdata			(s_axi_wdata	),
       .wstrb			(s_axi_wstrb	),
       .wlast			(s_axi_wlast	),
       .wvalid		(s_axi_wvalid	),
       .wready		(s_axi_wready	),


       .rid			  (s_axi_rid	),
       .rdata			(s_axi_rdata	),
       .rlast			(s_axi_rlast	),
       .rvalid 		(s_axi_rvalid	),
       .rready		(s_axi_rready	),
       .rresp			(s_axi_rresp	),

       .bid			  (s_axi_bid	),
       .bvalid		(s_axi_bvalid	),
       .bready	  (s_axi_bready	)
);

		    
		    
cvo_axi # (
    .SYMBOL_WIDTH(8),
    .SYMBOL_NUM(4),
    .PIXEL_NUM(2),
    .HSYNC_POL(1),
    .VSYNC_POL(1),
    .FIFO_DEPTH(1024),
    .FIFO_ALMOST_FULL(1000),
    .MAX_H_VALID(1920),
    .MAX_V_VALID(1080)
  )
  cvo_axi_inst (
    .fifo_rd_underflow(read_underflow),
    .o_clk          (vid_clk_dvi2   ),
    .rst_n          (vid_rst_n      ),
    .fifo_rd_period (fifo_rd_period ),
    .s_axi_clk      (vid_clk_dvi2   ),
    .s_axis_tdata   (m_axis_tdata   ),
    .s_axis_tvalid  (m_axis_tvalid  ),
    .s_axis_tready  (m_axis_tready  ),
    .s_axis_tlast   (m_axis_tlast   ),
    .s_axis_tuser   (m_axis_tuser   ),
    .H_FRONT_PORCH  (HFP            ),
    .H_SYNC         (HSP            ),
    .H_VALID        (HACT           ),
    .H_BACK_PORCH   (HBP            ),
    .V_FRONT_PORCH  (VFP            ),
    .V_SYNC         (VSP            ),
    .V_VALID        (VACT           ),
    .V_BACK_PORCH   (VBP            ),
     .vout          (ch0_data       ),
    .o_hs           (ch0_hs         ),
    .o_vs           (ch0_vs         ),
    .o_de           (ch0_de         )
  );		       


ddr3_top                 u_ddr3_top
(

.axi_clk                (core_clk            ),
.core_clk               (core_clk            ),
.sdram_clk              (sdram_clk           ),  
.rx_cal_clk             (rx_cal_clk          ),
.tx_cal_clk             (tx_cal_clk          ),
.tx_cal_clk_90edge      (tx_cal_clk_90edge   ),
.rstn                   (w_arstn             ),      
.pll_shift              (pll_shift           ),
.pll_shift_sel          (pll_shift_sel       ),
.pll_shift_ena          (pll_shift_ena       ),       
///////////////DDR BUS
.ddr_ck_hi              (ddr_ck_hi           ),
.ddr_ck_lo              (ddr_ck_lo           ),
.ddr_cke                (ddr_cke             ),    
.ddr_reset_n            (ddr_reset_n         ),
.ddr_cs_n               (ddr_cs_n            ),
.ddr_ras_n              (ddr_ras_n           ),
.ddr_cas_n              (ddr_cas_n           ),
.ddr_we_n               (ddr_we_n            ),     
.ddr_addr               (ddr_addr            ),
.ddr_ba                 (ddr_ba              ),

.ddr_dqs_oe             (ddr_dqs_oe          ),
.ddr_dqs_oe_n           (ddr_dqs_oe_n        ),
.ddr_dq_oe              (ddr_dq_oe           ),
.ddr_dqs_in_hi          (ddr_dqs_in_hi       ),
.ddr_dqs_in_lo          (ddr_dqs_in_lo       ),
.ddr_dq_in_hi           (ddr_dq_in_hi        ),
.ddr_dq_in_lo           (ddr_dq_in_lo        ),

.ddr_dqs_out_hi         (ddr_dqs_out_hi      ),
.ddr_dqs_out_lo         (ddr_dqs_out_lo      ),
.ddr_dq_out_hi          (ddr_dq_out_hi       ),
.ddr_dq_out_lo          (ddr_dq_out_lo       ),

.ddr_dm_hi              (ddr_dm_hi           ),
.ddr_dm_lo              (ddr_dm_lo           ),
.ddr_odt                (ddr_odt             ),

// Application interface ports
.app_sr_req                     (1'b0),
.app_ref_req                    (1'b0),
.app_zq_req                     (1'b0),
.app_sr_active                  (app_sr_active),
.app_ref_ack                    (app_ref_ack),
.app_zq_ack                     (app_zq_ack),

// Slave Interface Write Address Ports
.s_axi_awid                     (s_axi_awid        ),
.s_axi_awaddr                   (s_axi_awaddr      ),
.s_axi_awlen                    (s_axi_awlen       ),
.s_axi_awsize                   (s_axi_awsize      ),
.s_axi_awburst                  (s_axi_awburst     ),
.s_axi_awlock                   (s_axi_awlock      ),
.s_axi_awcache                  (s_axi_awcache     ),
.s_axi_awprot                   (s_axi_awprot      ),
.s_axi_awqos                    (4'h0              ),
.s_axi_awvalid                  (s_axi_awvalid     ),
.s_axi_awready                  (s_axi_awready     ),
// Slave Interface Write Data Ports
.s_axi_wdata                    (s_axi_wdata       ),
.s_axi_wstrb                    (s_axi_wstrb       ),
.s_axi_wlast                    (s_axi_wlast       ),
.s_axi_wvalid                   (s_axi_wvalid      ),
.s_axi_wready                   (s_axi_wready      ),
// Slave Interface Write Response Ports
.s_axi_bid                      (s_axi_bid         ),
.s_axi_bresp                    (s_axi_bresp       ),
.s_axi_bvalid                   (s_axi_bvalid      ),
.s_axi_bready                   (s_axi_bready      ),
// Slave Interface Read Address Ports
.s_axi_arid                     (s_axi_arid        ),
.s_axi_araddr                   (s_axi_araddr      ),
.s_axi_arlen                    (s_axi_arlen       ),
.s_axi_arsize                   (s_axi_arsize      ),
.s_axi_arburst                  (s_axi_arburst     ),
.s_axi_arlock                   (s_axi_arlock      ),
.s_axi_arcache                  (s_axi_arcache     ),
.s_axi_arprot                   (s_axi_arprot      ),
.s_axi_arqos                    (4'h0              ),
.s_axi_arvalid                  (s_axi_arvalid     ),
.s_axi_arready                  (s_axi_arready     ),
// Slave Interface Read Data Ports
.s_axi_rid                      (s_axi_rid         ),
.s_axi_rdata                    (s_axi_rdata       ),
.s_axi_rresp                    (s_axi_rresp       ),
.s_axi_rlast                    (s_axi_rlast       ),
.s_axi_rvalid                   (s_axi_rvalid      ),
.s_axi_rready                   (s_axi_rready      ),
//DEBUG       
.wrlvl_dq_check                 (wrlvl_dq_check    ) ,
.rd_level_dqs_check             (rd_level_dqs_check) ,
.init_cur_state                 (init_cur_state    ) ,
.idelay_ld                      (idelay_ld         ) ,
.mpr_rdlvl_dly                  (mpr_rdlvl_dly     ) ,
.cal_done                       (cal_done          ) 
);

//***************************************************************************
// Checkpoint A: DDR XRGB pixels feed HDMI directly through the RGB adapter.
// CVO pair_data[31:0] is P0, pair_data[63:32] is P1.
wire [7:0] hdmi_tx_rdata;
wire [7:0] hdmi_tx_gdata;
wire [7:0] hdmi_tx_bdata;
wire hdmi_tx_vs, hdmi_tx_hs, hdmi_tx_de;
rgb_to_hdmi u_rgb_to_hdmi (
    .pair_clk(vid_clk_dvi2), .pixel_clk(hdmi_tx_slow_clk), .rst_n(vid_rst_n),
    .pair_data(ch0_data), .pair_vs(ch0_vs), .pair_hs(ch0_hs), .pair_de(ch0_de),
    .red(hdmi_tx_rdata), .green(hdmi_tx_gdata), .blue(hdmi_tx_bdata),
    .vs(hdmi_tx_vs), .hs(hdmi_tx_hs), .de(hdmi_tx_de)
);
//==============================================================================
// MIPI DSI
//==============================================================================
// signal 

reg		[25:0]	r_rst_cnt;

wire	[31:0]	w_axi_rdata;
wire			w_axi_awready;
wire			w_axi_wready;
wire			w_axi_arready;
wire			w_axi_rvalid;
wire			w_axi_bvalid;

wire	[6:0]	w_axi_awaddr;
wire			w_axi_awvalid;
wire	[31:0]	w_axi_wdata;
wire			w_axi_wvalid;
wire			w_axi_bready;
wire	[6:0]	w_axi_araddr;
wire			w_axi_arvalid;
wire			w_axi_rready;

wire			w_confdone;
assign w_confdone = 1'b1;

assign  LCD_POWER 			= i_arstn;
assign	LCD_RST_P	      = ~w_arstn;//~r_rst_cnt[23]; LCD复位先释放，然后再释放MIPI 的复位
assign	mipi_dp_clk_RST		= ~i_arstn;
assign	mipi_dp_data0_RST	= ~i_arstn;
assign	mipi_dp_data1_RST	= ~i_arstn;
assign	mipi_dp_data2_RST	= ~i_arstn;
assign	mipi_dp_data3_RST	= ~i_arstn;
////////////////////////////////////////////////////////////////
always@(posedge i_mipi_clk or  negedge w_arstn )
begin
  if ( !w_arstn ) begin
    r_rst_cnt	<= 'd0;
  end else 		
    r_rst_cnt	<= r_rst_cnt[25] ? r_rst_cnt :r_rst_cnt + 1'b1;
end

wire axi_rst_n = r_rst_cnt[25];

reg [26:0] dly_cnt = 'd0;

always @( posedge vid_clk_dvi2 or negedge w_arstn )
begin
  if( !w_arstn )
    dly_cnt <= 'd0;
  else if( w_confdone )
    dly_cnt <= dly_cnt[26] ? dly_cnt :(dly_cnt + 1'b1);
  else 
    dly_cnt <= 'd0;
end 

assign vid_rst_n = dly_cnt[26];




wire hs;
wire vs;
wire de;
wire [7:0] rgb_r;
wire [7:0] rgb_g;
wire [7:0] rgb_b;
  
  // color_bar_rgb #(
  // .HS_POLORY 		(1'b1		),
  // .VS_POLORY 		(1'b1		),
  // .H_FRONT_PORCH 	(HFP		),///2
  // .H_SYNC 		(HSP		),//
  // .H_VALID 		(MAX_HRES	),//
  // .H_BACK_PORCH 	(HBP		),//
  // .V_FRONT_PORCH 	(VFP		),
  // .V_SYNC 		(VSP		),
  // .V_VALID 		(MAX_VRES	),
  // .V_BACK_PORCH 	(VBP		),
  // .TEST_MODE 		(2'd2)
  // )u_color_bar_rgb1(
  // /*i*/.clk	(vid_clk_dvi2),//(vid_clk),
  // /*i*/.rst_n	(vid_rst_n),
  // /*o*/.hs	(hs),
  // /*o*/.vs	(vs),
  // /*o*/.de	(de),
  // // /*O*/.h_cnt (h_cnt),
  // // /*O*/.v_cnt (v_cnt),
  // /*o*/.rgb_r	(rgb_r),    //像素数据、红色分量
  // /*o*/.rgb_g	(rgb_g),    //像素数据、绿色分量
  // /*o*/.rgb_b (rgb_b)    //像素数据、蓝色分量
  
  // );

//=================================================================================
//hdmi tx ctrl 
//=================================================================================
wire                            video_hs;
wire                            video_vs;
wire                            video_de;
wire[7:0]                       video_r;
wire[7:0]                       video_g;
wire[7:0]                       video_b;

assign tmds_tx_data0_TX_OE = 1'b1;
assign tmds_tx_data1_TX_OE = 1'b1;
assign tmds_tx_data2_TX_OE = 1'b1;
assign tmds_tx_clk_TX_OE   = 1'b1;

assign tmds_tx_data0_TX_RST = 1'b0;
assign tmds_tx_data1_TX_RST = 1'b0;
assign tmds_tx_data2_TX_RST = 1'b0;
assign tmds_tx_clk_TX_RST   = 1'b0;

// 	  color_bar color_bar_m0(
// 	.clk(hdmi_tx_slow_clk),
// 	.rst(~vid_rst_n),
// 	.hs(video_hs),
// 	.vs(video_vs),
// 	.de(video_de),
// 	.rgb_r(video_r),
// 	.rgb_g(video_g),
// 	.rgb_b(video_b)
// );

wire [9:0] tmds_data0;
wire [9:0] tmds_data1;
wire [9:0] tmds_data2;
wire [9:0] tmds_clk ;
wire [7:0] gamma_rdata ;
wire [7:0] gamma_gdata ;
wire [7:0] gamma_bdata ;
wire gamma_valid;
wire gamma_hs;
wire gamma_vs;
wire gamma_sel;
assign gamma_sel = 1'b0;

wire [7:0] con_rdata ;
wire [7:0] con_gdata ;
wire [7:0] con_bdata ;
wire con_de;
wire con_hs;
wire con_vs;
wire con_sel;

wire [7:0] BRIGHT_SIG    ;
wire CONTRAST_SIG_G;
wire CONTRAST_SIG_R;
wire [7:0] CONTRAST_G    ;
wire CONTRAST_SIG_B;
wire [7:0] BRIGHT        ;
wire [7:0] CONTRAST_R    ;


wire CONTRAST_B    ;


gamma_correction
#(
	.DATA_WIDTH		(8),
	.GAMMA_CURVE	("./rtl/gamma_conrrection/2P2.mem")
)
inst_gamma_correction
(
	.i_pclk		(hdmi_tx_slow_clk),
	.i_rstn		(vid_rst_n),
	
	.i_red		(hdmi_tx_rdata),//(con_rdata  ),//
	.i_green	(hdmi_tx_gdata),//(con_gdata  ),//
	.i_blue		(hdmi_tx_bdata),//(con_bdata  ),//
  .i_valid	(hdmi_tx_de   ),//(con_de     ),//
  .i_hs     (hdmi_tx_hs   ),//(con_hs     ),//
  .i_vs     (hdmi_tx_vs   ),//(con_vs     ),//
	.o_blue		(gamma_bdata		),
  .o_green	(gamma_gdata	  ),
	.o_red		(gamma_rdata		),
	.o_valid	(gamma_valid	  ),
  .o_hs     (gamma_hs       ),
  .o_vs     (gamma_vs       )
);

dvi_encoder dvi_encoder_m0
(
	.pixelclk      		(hdmi_tx_slow_clk          ),// system clock
	.rst_p         		(~vid_rst_n      ),// reset
	.i_bdata      		(gamma_sel ? gamma_bdata	: hdmi_tx_bdata 	),//(hdmi_tx_rdata ),//(video_b            ),//(bdata_in	),   //
	.i_gdata     		  (gamma_sel ? gamma_gdata	: hdmi_tx_gdata   ),//(hdmi_tx_gdata ),//(video_g            ),//(gdata_in	),   //   
	.i_rdata       		(gamma_sel ? gamma_rdata	: hdmi_tx_rdata 	),//(hdmi_tx_bdata ),//(video_r            ),//(rdata_in	),   //   
  .i_de            	(gamma_sel ? gamma_valid	: hdmi_tx_de      ),//(hdmi_tx_de    ),//(video_de           ),//(rx_de		  ),   //
	.i_hs         		(gamma_sel ? gamma_hs	    : hdmi_tx_hs    ),//(video_hs           ),//(rx_hsync	),   //   
	.i_vs         		(gamma_sel ? gamma_vs	    : hdmi_tx_vs    ),//(video_vs           ),//(rx_vsync	),   //  
	
  .video_format     (2'b00), //// 00 = RGB, 01 = YCbCr 4:2:2, 10 = YCbCr 4:4:4
  .video_VIC        (7'd0),
	.audio_L			    (24'd0),
  .audio_R			    (24'd0),
  .audio_valid		  (1'b0),
  .audio_N                (6144),     //(20'h01880),//     
  .audio_CTS              (20'd148500),      //(20'h28488),//      
  .audio_sample_frequency (4'b0010),    //(3'b000),// 
  .audio_word_length      (4'b1011),//(4'b1011),//

	.tmds_data0    		(tmds_data0),
  .tmds_data1    		(tmds_data1),
  .tmds_data2    		(tmds_data2),
  .tmds_clk      	  (tmds_clk  )
);
assign tmds_tx_clk_TX_DATA   = ~tmds_clk;
assign tmds_tx_data0_TX_DATA = ~tmds_data0;
assign tmds_tx_data1_TX_DATA = ~tmds_data1;
assign tmds_tx_data2_TX_DATA = ~tmds_data2;

// Control-island reset never resets the platform-owned writer or video path.
// Sapphire is the only TDO driver. EDB and the former TDI/TDO placeholder are absent.
(* syn_keep = 1 *) wire accel_start_test_pulse;
sapphire_control #(.COLOR_KEY_ENABLE(COLOR_KEY_ENABLE),.CPU_DDR_ENABLE(1)) u_control (
    .core_clk(core_clk), .platform_rst_n(i_arstn && w_arstn),
    .platform_ddr_rst_n(vid_rst_n),
    .jtag_tck(jtag_inst1_TCK), .jtag_tdi(jtag_inst1_TDI), .jtag_tdo(jtag_inst1_TDO),
    .jtag_sel(jtag_inst1_SEL), .jtag_capture(jtag_inst1_CAPTURE),
    .jtag_shift(jtag_inst1_SHIFT), .jtag_update(jtag_inst1_UPDATE),
    .jtag_reset(jtag_inst1_RESET),
    .display_buffer_base(rd_buffer_base), .tpg_write_buffer_base(wr_buffer_base),

    .init_done(fb_init_done),.init_error(fb_init_error),
    .engine_busy(fill_busy),.engine_done(fill_done),.engine_error(fill_error),.command_count(fill_command_count),
    .init_data_beats(init_data_beats),.init_aw_bursts(init_aw_bursts),.init_wlast_bursts(init_wlast_bursts),
    .init_b_responses(init_b_responses),.init_aw_beats(init_aw_beats),
    .cmd_x(fill_x),.cmd_y(fill_y),.cmd_width(fill_width),.cmd_height(fill_height),.cmd_color(fill_color),
    .cmd_op(graphics_op),.cmd_src_addr(graphics_src_addr),.cmd_src_stride(graphics_src_stride),
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
    .start_test_pulse(accel_start_test_pulse),
    .cpu_ddr_session_active(cpu_ddr_session_active),.cpu_ddr_session_status(cpu_ddr_session_status),
    .cpu_ddr_acquire(cpu_ddr_acquire),.cpu_ddr_release(cpu_ddr_release),
    .cpu_ddr_clear_error(cpu_ddr_clear_error),.cpu_ddr_busy(cpu_ddr_busy),.cpu_ddr_error(cpu_ddr_error),
    .asset_status(asset_status),.asset_begin(asset_begin),.asset_seal(asset_seal),
    .cpu_awaddr(cpu_awaddr),.cpu_awvalid(cpu_awvalid),.cpu_awready(cpu_awready),
    .cpu_wdata(cpu_wdata),.cpu_wstrb(cpu_wstrb),.cpu_wlast(cpu_wlast),
    .cpu_wvalid(cpu_wvalid),.cpu_wready(cpu_wready),
    .cpu_bid(cpu_bid),.cpu_bresp(cpu_bresp),.cpu_bvalid(cpu_bvalid),.cpu_bready(cpu_bready),
    .cpu_araddr(cpu_araddr),.cpu_arvalid(cpu_arvalid),.cpu_arready(cpu_arready),
    .cpu_rdata(cpu_rdata),.cpu_rid(cpu_rid),.cpu_rresp(cpu_rresp),
    .cpu_rlast(cpu_rlast),.cpu_rvalid(cpu_rvalid),.cpu_rready(cpu_rready)
);

// Nonfunctional diagnostics. Counters are local to the signal clock domains.
wire axi_diag_rst_n;
rst_n_piple #(.DLY(3)) u_axi_diag_reset (
    .clk(core_clk), .rst_n_i(vid_rst_n), .rst_n_o(axi_diag_rst_n)
);
(* syn_keep = 1 *) reg [31:0] axi_write_beat_count = 0;
(* syn_keep = 1 *) reg [31:0] axi_read_beat_count = 0;
(* syn_keep = 1 *) reg axi_error_sticky = 0;
(* syn_keep = 1 *) reg wr_fifo_full_sticky = 0;
(* syn_keep = 1 *) reg read_underflow_sticky = 0;
(* syn_keep = 1 *) wire axi_write_activity = s_axi_wvalid & s_axi_wready;
(* syn_keep = 1 *) wire axi_read_activity = s_axi_rvalid & s_axi_rready;
always @(posedge core_clk) begin
    if (!axi_diag_rst_n) begin
        axi_write_beat_count <= 0;
        axi_read_beat_count <= 0;
        axi_error_sticky <= 0;
    end else begin
        if (axi_write_activity) axi_write_beat_count <= axi_write_beat_count + 1'b1;
        if (axi_read_activity) axi_read_beat_count <= axi_read_beat_count + 1'b1;
        if ((s_axi_bvalid && s_axi_bready && |s_axi_bresp) ||
            (axi_read_activity && |s_axi_rresp)) axi_error_sticky <= 1'b1;
    end
end
always @(posedge i_mipi_rx_pclk) begin
    if (!tpg_rst_n) wr_fifo_full_sticky <= 0;
    else if (wr_fifo_full && tpg_de) wr_fifo_full_sticky <= 1;
end
always @(posedge vid_clk_dvi2) begin
    if (!vid_rst_n) read_underflow_sticky <= 0;
    else if (read_underflow) read_underflow_sticky <= 1;
end
assign led[1] = fb_init_done;
assign led[2] = wr_fifo_full_sticky;
assign led[3] = read_underflow;
assign led[4] = axi_write_beat_count[22];
assign led[5] = axi_read_beat_count[22];
assign led[6] = vid_rst_n;
assign led[7] = axi_error_sticky;

assign mipi_dp_clk_LP_P_OUT = 0;
assign mipi_dp_clk_LP_N_OUT = 0;
assign mipi_dp_clk_HS_OUT = 0;
assign mipi_dp_clk_HS_OE = 0;
assign mipi_dp_data3_LP_P_OUT = 0;
assign mipi_dp_data2_LP_P_OUT = 0;
assign mipi_dp_data1_LP_P_OUT = 0;
assign mipi_dp_data0_LP_P_OUT = 0;
assign mipi_dp_data3_LP_N_OUT = 0;
assign mipi_dp_data2_LP_N_OUT = 0;
assign mipi_dp_data1_LP_N_OUT = 0;
assign mipi_dp_data0_LP_N_OUT = 0;
assign mipi_dp_data0_HS_OUT = 0;
assign mipi_dp_data1_HS_OUT = 0;
assign mipi_dp_data2_HS_OUT = 0;
assign mipi_dp_data3_HS_OUT = 0;
assign mipi_dp_data3_HS_OE = 0;
assign mipi_dp_data2_HS_OE = 0;
assign mipi_dp_data1_HS_OE = 0;
assign mipi_dp_data0_HS_OE = 0;
assign mipi_dp_clk_LP_P_OE = 0;
assign mipi_dp_clk_LP_N_OE = 0;
assign mipi_dp_data3_LP_P_OE = 0;
assign mipi_dp_data3_LP_N_OE = 0;
assign mipi_dp_data2_LP_P_OE = 0;
assign mipi_dp_data2_LP_N_OE = 0;
assign mipi_dp_data1_LP_P_OE = 0;
assign mipi_dp_data1_LP_N_OE = 0;
assign mipi_dp_data0_LP_P_OE = 0;
assign mipi_dp_data0_LP_N_OE = 0;
endmodule
