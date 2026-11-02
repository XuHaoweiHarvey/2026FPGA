// Strided viewport reader. One outstanding AXI128 burst, platform reset only.
// Framebuffer coordinates/stride remain 1080p; only viewport pixels enter FIFO.
module window_display_reader #(
    parameter FRAME_STRIDE=7680, VIEW_X=640, VIEW_Y=300,
    parameter VIEW_WIDTH=640, VIEW_HEIGHT=480,
    parameter FIFO_DEPTH=1024, MAX_BURST_BEATS=128
)(
    input wire clk,rst_n,start,flush,
    input wire [31:0] frame_base,
    input wire video_clk,fifo_read,
    output wire [127:0] fifo_data,output wire fifo_empty,
    output wire idle,output wire fifo_write_empty,
    output wire [31:0] fifo_level,
    output wire [31:0] araddr,output wire [7:0] arlen,
    output wire arvalid,input wire arready,
    input wire [127:0] rdata,input wire rvalid,rlast,output wire rready
);
localparam IDLE=0,PREP=1,ADDRESS=2,DATA=3;
reg [1:0] state;
reg [31:0] row_start,cursor,rows_left,remaining;
reg [8:0] length;
reg write_pending;
reg [127:0] write_data;
wire [$clog2(FIFO_DEPTH):0] used;
wire full;
wire [31:0] page_left=(4096-{20'b0,cursor[11:0]})>>4;
wire [31:0] capped=remaining<MAX_BURST_BEATS ? remaining : MAX_BURST_BEATS;
wire [31:0] next_length=capped<page_left ? capped : page_left;
assign araddr=cursor;
assign arlen=length-1'b1;
assign arvalid=rst_n && state==ADDRESS;
assign rready=rst_n && state==DATA;
assign idle=state==IDLE && !write_pending && !arvalid && !rvalid;
assign fifo_level=used;
assign fifo_write_empty=used==0 && !write_pending;
DC_FIFO #(.FIFO_MODE("Normal"),.DATA_WIDTH(128),.FIFO_DEPTH(FIFO_DEPTH)) fifo (
    .Reset(!rst_n || flush),.WrClk(clk),.WrEn(write_pending),.WrData(write_data),
    .WrDNum(used),.WrFull(full),.RdClk(video_clk),.RdEn(fifo_read),
    .RdData(fifo_data),.RdEmpty(fifo_empty),.RdDNum());
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state<=IDLE;row_start<=0;cursor<=0;rows_left<=0;remaining<=0;
        length<=0;write_pending<=0;write_data<=0;
    end else begin
        write_pending<=rvalid && rready;
        if(rvalid && rready) write_data<=rdata;
        case(state)
        IDLE: if(start && !flush) begin
            row_start<=frame_base+VIEW_Y*FRAME_STRIDE+VIEW_X*4;
            cursor<=frame_base+VIEW_Y*FRAME_STRIDE+VIEW_X*4;
            rows_left<=VIEW_HEIGHT;remaining<=VIEW_WIDTH/4;state<=PREP;
        end
        PREP: if(!flush && used+next_length+4<=FIFO_DEPTH) begin
            length<=next_length[8:0];state<=ADDRESS;
        end
        ADDRESS: if(arready) state<=DATA;
        DATA: if(rvalid && rready && rlast) begin
            if(remaining==length) begin
                if(rows_left==1) state<=IDLE;
                else begin
                    rows_left<=rows_left-1'b1;row_start<=row_start+FRAME_STRIDE;
                    cursor<=row_start+FRAME_STRIDE;remaining<=VIEW_WIDTH/4;state<=PREP;
                end
            end else begin
                remaining<=remaining-length;cursor<=cursor+({23'b0,length}<<4);state<=PREP;
            end
        end
        default: state<=IDLE;
        endcase
    end
end
// synthesis translate_off
always @(posedge clk) if(rst_n) begin
    if(flush && !idle) $fatal(1,"Window FIFO flush with an outstanding read");
    if(write_pending && full) $fatal(1,"Window display FIFO overflow");
    if(start && !idle) $fatal(1,"Window reader launch while busy");
end
initial if(VIEW_WIDTH%4!=0 || VIEW_X%4!=0 || VIEW_WIDTH<4 || VIEW_HEIGHT<1 ||
           MAX_BURST_BEATS<1 || MAX_BURST_BEATS>128 || FIFO_DEPTH<MAX_BURST_BEATS+4)
    $fatal(1,"Invalid window reader geometry");
// synthesis translate_on
endmodule
