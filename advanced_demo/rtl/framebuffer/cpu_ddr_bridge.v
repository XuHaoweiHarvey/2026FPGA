// One transaction at a time between Sapphire's 128-bit external AXI and the
// existing framebuffer AXI clients. Reset with the DDR platform, never with
// a CPU debug reset: accepted DDR traffic must always reach B/RLAST.
module cpu_ddr_bridge #(
    parameter [31:0] CPU_BASE=32'h00001000,
    parameter [31:0] BUFFER1_BASE=32'h00800000,
    parameter [31:0] FRAME_BYTES=32'h007e9000
)(
    input wire clk, rst_n, cpu_reset, session_active,
    input wire [31:0] front_base, back_base,
    output wire busy, output reg [31:0] error_code,
    input wire clear_error,
    input wire [31:0] s_awaddr, input wire [7:0] s_awid,
    input wire [7:0] s_awlen, input wire [2:0] s_awsize,
    input wire [1:0] s_awburst, input wire s_awlock,
    input wire s_awvalid, output wire s_awready,
    input wire [127:0] s_wdata, input wire [15:0] s_wstrb,
    input wire s_wlast, input wire s_wvalid, output wire s_wready,
    output wire [7:0] s_bid, output wire [1:0] s_bresp,
    output wire s_bvalid, input wire s_bready,
    input wire [31:0] s_araddr, input wire [7:0] s_arid,
    input wire [7:0] s_arlen, input wire [2:0] s_arsize,
    input wire [1:0] s_arburst, input wire s_arlock,
    input wire s_arvalid, output wire s_arready,
    output wire [127:0] s_rdata, output wire [7:0] s_rid,
    output wire [1:0] s_rresp, output wire s_rlast,
    output wire s_rvalid, input wire s_rready,
    output wire [31:0] m_awaddr, output wire m_awvalid, input wire m_awready,
    output wire [127:0] m_wdata, output wire [15:0] m_wstrb,
    output wire m_wlast, output wire m_wvalid, input wire m_wready,
    input wire [3:0] m_bid, input wire [1:0] m_bresp,
    input wire m_bvalid, output wire m_bready,
    output wire [31:0] m_araddr, output wire m_arvalid, input wire m_arready,
    input wire [127:0] m_rdata, input wire [3:0] m_rid,
    input wire [1:0] m_rresp, input wire m_rlast,
    input wire m_rvalid, output wire m_rready
);
localparam IDLE=0, COLLECT=1, SEND_AW=2, SEND_W=3, WAIT_B=4,
           RESP_B=5, PREP_AR=6, SEND_AR=7, WAIT_R=8, DRAIN_R=9, RESP_R=10;
reg [3:0] state;
reg aw_seen,w_seen,aborted;
reg [31:0] aw_addr,ar_addr;
reg [7:0] aw_id,ar_id;
reg [7:0] aw_len,ar_len;
reg [2:0] aw_size,ar_size;
reg [1:0] aw_burst,ar_burst;
reg aw_lock,ar_lock,w_last;
reg [127:0] w_data,r_data;
reg [15:0] w_strb;
reg [1:0] b_resp,r_resp;
reg [31:0] physical_addr;

// The generated SoC passes the CPU byte address through unchanged and emits
// SIZE=4/LEN=0 even for a 32-bit store. Align the DDR address to the 16-byte
// word; keep its already-up-sized WDATA/WSTRB and full RDATA lane ordering.
function valid_frame_word;
    input [31:0] cpu_addr;
    input [31:0] frame_base;
    reg [32:0] translated, last_byte;
    begin
        translated={1'b0,cpu_addr}-{1'b0,CPU_BASE};
        last_byte={1'b0,frame_base}+{1'b0,FRAME_BYTES};
        valid_frame_word=cpu_addr>=CPU_BASE && translated>={1'b0,frame_base} &&
            (translated+33'd15)<last_byte && cpu_addr[1:0]==0;
    end
endfunction
wire aw_range=valid_frame_word(aw_addr,back_base);
wire ar_range=valid_frame_word(ar_addr,front_base) ||
              valid_frame_word(ar_addr,back_base);
wire [15:0] lane_mask=16'h000f << {aw_addr[3:2],2'b00};
wire write_ok=session_active && aw_range && aw_len==0 && aw_size==4 &&
              aw_burst==1 && !aw_lock && w_last && w_strb!=0 &&
              (w_strb & ~lane_mask)==0;
wire read_ok=session_active && ar_range && ar_len==0 && ar_size==4 &&
             ar_burst==1 && !ar_lock;
assign busy=state!=IDLE || aw_seen || w_seen;
assign s_arready=state==IDLE && !cpu_reset && !s_awvalid && !s_wvalid;
assign s_awready=(state==IDLE || state==COLLECT) && !cpu_reset && !aw_seen;
assign s_wready=(state==IDLE || state==COLLECT) && !cpu_reset && !w_seen;
assign s_bid=aw_id;
assign s_bresp=b_resp;
assign s_bvalid=state==RESP_B && !aborted && !cpu_reset;
assign s_rid=ar_id;
assign s_rdata=r_data;
assign s_rresp=r_resp;
assign s_rlast=1'b1;
assign s_rvalid=state==RESP_R && !aborted && !cpu_reset;
assign m_awaddr=physical_addr;
assign m_awvalid=state==SEND_AW;
assign m_wdata=w_data;
assign m_wstrb=w_strb;
assign m_wlast=1'b1;
assign m_wvalid=state==SEND_W;
assign m_bready=state==WAIT_B;
assign m_araddr=physical_addr;
assign m_arvalid=state==SEND_AR;
assign m_rready=state==WAIT_R || state==DRAIN_R;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state<=IDLE;aw_seen<=0;w_seen<=0;aborted<=0;
        aw_addr<=0;ar_addr<=0;aw_id<=0;ar_id<=0;
        aw_len<=0;ar_len<=0;aw_size<=0;ar_size<=0;
        aw_burst<=0;ar_burst<=0;aw_lock<=0;ar_lock<=0;
        w_last<=0;w_data<=0;w_strb<=0;r_data<=0;
        b_resp<=0;r_resp<=0;physical_addr<=0;error_code<=0;
    end else begin
        if(clear_error) error_code<=0;
        if(cpu_reset && state!=IDLE && state!=COLLECT) begin
            aborted<=1;
            if(error_code==0) error_code<=6;
        end
        if((state==IDLE || state==COLLECT) && cpu_reset) begin
            state<=IDLE;aw_seen<=0;w_seen<=0;aborted<=0;
        end else case(state)
        IDLE, COLLECT: begin
            if(s_arvalid && s_arready) begin
                ar_addr<=s_araddr;ar_id<=s_arid;ar_len<=s_arlen;
                ar_size<=s_arsize;ar_burst<=s_arburst;ar_lock<=s_arlock;
                state<=PREP_AR;
            end else begin
                if(s_awvalid && s_awready) begin
                    aw_addr<=s_awaddr;aw_id<=s_awid;aw_len<=s_awlen;
                    aw_size<=s_awsize;aw_burst<=s_awburst;aw_lock<=s_awlock;
                    aw_seen<=1;
                end
                if(s_wvalid && s_wready) begin
                    w_data<=s_wdata;w_strb<=s_wstrb;w_last<=s_wlast;
                    w_seen<=1;
                end
                if(aw_seen && w_seen) begin
                    aw_seen<=0;w_seen<=0;
                    if(write_ok) begin
                        physical_addr<=(aw_addr-CPU_BASE) & 32'hfffffff0;
                        state<=SEND_AW;
                    end else begin
                        b_resp<=2'b11;state<=RESP_B;
                        if(error_code==0) error_code<=1;
                    end
                end else if(s_awvalid || s_wvalid || aw_seen || w_seen)
                    state<=COLLECT;
            end
        end
        SEND_AW: if(m_awvalid && m_awready) state<=SEND_W;
        SEND_W: if(m_wvalid && m_wready) state<=WAIT_B;
        WAIT_B: if(m_bvalid && m_bready) begin
            b_resp<=(m_bid==0) ? m_bresp : 2'b10;
            if(m_bid!=0 && error_code==0) error_code<=3;
            else if(m_bresp!=0 && error_code==0) error_code<=4;
            state<=RESP_B;
        end
        RESP_B: if(aborted || cpu_reset || (s_bvalid && s_bready)) begin
            state<=IDLE;aborted<=0;
        end
        PREP_AR: begin
            if(!read_ok) begin
                r_data<=0;r_resp<=2'b11;state<=RESP_R;
                if(error_code==0) error_code<=1;
            end else begin
                physical_addr<=(ar_addr-CPU_BASE) & 32'hfffffff0;
                state<=SEND_AR;
            end
        end
        SEND_AR: if(m_arvalid && m_arready) state<=WAIT_R;
        WAIT_R: if(m_rvalid && m_rready) begin
            r_data<=m_rdata;
            r_resp<=(m_rid==0) ? m_rresp : 2'b10;
            if(m_rid!=0 && error_code==0) error_code<=3;
            else if(m_rresp!=0 && error_code==0) error_code<=4;
            if(m_rlast) state<=RESP_R;
            else begin
                state<=DRAIN_R;
                r_resp<=2'b10;
                if(error_code==0) error_code<=5;
            end
        end
        DRAIN_R: if(m_rvalid && m_rready && m_rlast) state<=RESP_R;
        RESP_R: if(aborted || cpu_reset || (s_rvalid && s_rready)) begin
            state<=IDLE;aborted<=0;
        end
        default: state<=IDLE;
        endcase
    end
end
endmodule
