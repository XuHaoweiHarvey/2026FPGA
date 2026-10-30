// One outstanding AXI128 burst; slot 0, XRGB8888. No read/modify/write.
// Edge pixels use four-byte lane strobes, preserving pixels outside the rect.
module fill_rect_writer #(
    parameter FRAME_WIDTH=1920, FRAME_HEIGHT=1080, FRAME_STRIDE=7680,
    parameter MAX_BURST_BEATS=32, WATCHDOG_BITS=27, SETTLE_FRAMES=2
)(
    input wire clk, input wire rst_n, input wire enabled, input wire start,
    input wire [31:0] rect_x,rect_y,rect_width,rect_height,rect_color,
    input wire display_frame_tick,
    output wire busy, output reg done,
    output reg [31:0] error_code, output reg [31:0] command_count,
    output wire [31:0] awaddr, output wire [7:0] awlen,
    output wire awvalid, input wire awready,
    output wire [127:0] wdata, output reg [15:0] wstrb,
    output wire wlast,output wire wvalid,input wire wready,
    input wire [3:0] bid,input wire [1:0] bresp,input wire bvalid,output wire bready
);
localparam IDLE=0,PREP=1,ADDR=2,DATA=3,RESP=4,SETTLE=5;
reg [2:0] state;
reg [31:0] cursor,row_start,row_end,rows_left,color,beat_addr;
reg [8:0] burst_beats,beat_index;
reg [31:0] settle_left;
reg [WATCHDOG_BITS-1:0] watchdog;
wire activity=(awvalid&&awready)||(wvalid&&wready)||(bvalid&&bready);
wire [31:0] remaining_beats=((row_end-1)>>4)-(cursor>>4)+1;
wire [31:0] page_beats=(4096-{20'b0,cursor[11:0]})>>4;
wire [31:0] capped=(remaining_beats<MAX_BURST_BEATS)?remaining_beats:MAX_BURST_BEATS;
wire [31:0] next_cursor=cursor+{19'b0,burst_beats,4'b0};
assign busy=state!=IDLE;
assign awaddr=cursor;
assign awlen=burst_beats-1'b1;
assign awvalid=state==ADDR;
assign wvalid=state==DATA;
assign wlast=(state==DATA)&&(beat_index==burst_beats-1'b1);
assign wdata={4{color}};
assign bready=state==RESP;
integer lane;
always @(*) begin
    wstrb=0;
    for(lane=0;lane<4;lane=lane+1)
        if(beat_addr+lane*4>=row_start && beat_addr+lane*4<row_end)
            wstrb[lane*4+:4]=4'hf;
end
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state<=IDLE;done<=0;error_code<=0;command_count<=0;
        cursor<=0;row_start<=0;row_end<=0;rows_left<=0;color<=0;
        beat_addr<=0;burst_beats<=0;beat_index<=0;watchdog<=0;settle_left<=0;
    end else begin
        if(state==IDLE || activity || (state==SETTLE && display_frame_tick)) watchdog<=0;
        else if(!(&watchdog)) watchdog<=watchdog+1'b1;
        // Never withdraw AWVALID/WVALID on timeout. Drain the accepted/pending
        // transaction, then report failure; CPU/debug reset is not rst_n.
        if(state!=IDLE && (&watchdog)) error_code<=32'h13;
        case(state)
        IDLE: if(start && enabled) begin
            done<=0;error_code<=0;watchdog<=0;command_count<=command_count+1;
            if(rect_width==0 || rect_height==0 || rect_x>=FRAME_WIDTH || rect_y>=FRAME_HEIGHT ||
               {1'b0,rect_x}+{1'b0,rect_width}>FRAME_WIDTH ||
               {1'b0,rect_y}+{1'b0,rect_height}>FRAME_HEIGHT) begin
                done<=1;error_code<=32'h11;
            end else begin
                row_start<=rect_y*FRAME_STRIDE+(rect_x<<2);
                row_end<=rect_y*FRAME_STRIDE+((rect_x+rect_width)<<2);
                cursor<=(rect_y*FRAME_STRIDE+(rect_x<<2))&32'hfffffff0;
                rows_left<=rect_height;color<=rect_color;state<=PREP;
            end
        end
        PREP: begin
            if(error_code!=0 || (&watchdog)) begin done<=1;state<=IDLE;end
            else begin burst_beats<=(capped<page_beats)?capped:page_beats;state<=ADDR;end
        end
        ADDR: if(awready) begin beat_addr<=cursor;beat_index<=0;state<=DATA;end
        DATA: if(wready) begin
            if(wlast) state<=RESP;
            else begin beat_addr<=beat_addr+16;beat_index<=beat_index+1'b1;end
        end
        RESP: if(bvalid) begin
            if(bresp!=0 || bid!=0 || error_code!=0 || (&watchdog)) begin
                if(bresp!=0 || bid!=0) error_code<=32'h12;
                done<=1;state<=IDLE;
            end else if(next_cursor>=row_end) begin
                if(rows_left==1) begin
                    if(SETTLE_FRAMES==0) begin done<=1;state<=IDLE;end
                    else begin settle_left<=SETTLE_FRAMES;state<=SETTLE;end
                end else begin
                    rows_left<=rows_left-1'b1;
                    row_start<=row_start+FRAME_STRIDE;row_end<=row_end+FRAME_STRIDE;
                    cursor<=(row_start+FRAME_STRIDE)&32'hfffffff0;state<=PREP;
                end
            end else begin cursor<=next_cursor;state<=PREP;end
        end
        SETTLE: begin
            // Wait for a complete updated display frame before exposing DONE.
            // No buffer swap or reader address change takes place.
            if(display_frame_tick) begin
                if(settle_left==1) begin done<=1;state<=IDLE;end
                else settle_left<=settle_left-1;
            end else if(&watchdog) begin done<=1;state<=IDLE;end
        end
        default: state<=IDLE;
        endcase
    end
end
// synthesis translate_off
initial if(MAX_BURST_BEATS<1 || MAX_BURST_BEATS>128 || FRAME_STRIDE!=FRAME_WIDTH*4 || FRAME_WIDTH%4!=0)
    $fatal(1,"Unsupported fill writer parameters");
// synthesis translate_on
endmodule
