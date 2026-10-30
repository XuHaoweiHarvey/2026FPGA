// Two source lines in synchronous RAM; every source pixel becomes a 2x2 block.
// The DDR FIFO still supplies exactly 640*480/4 words per output frame.
module window_scale2_composer #(
    parameter FRAME_WIDTH=1920, FRAME_HEIGHT=1080,
    parameter SOURCE_WIDTH=640, SOURCE_HEIGHT=480,
    parameter OUTPUT_X=320, OUTPUT_Y=60
)(
    input wire clk,rst_n,frame_period,
    input wire [127:0] fifo_data,input wire fifo_empty,output wire fifo_read,
    output wire [63:0] m_axis_tdata,output wire m_axis_tvalid,
    input wire m_axis_tready,output wire m_axis_tuser,m_axis_tlast
);
localparam WORDS=SOURCE_WIDTH/4;
// Four banks allow one 128-bit fill and one synchronous pixel lookup per clock.
reg [31:0] lane0[0:2*WORDS-1],lane1[0:2*WORDS-1];
reg [31:0] lane2[0:2*WORDS-1],lane3[0:2*WORDS-1];
reg [31:0] q0,q1,q2,q3;
reg [1:0] selected_lane,row_ready;
reg pending,pixel_valid,frame_complete;
reg [12:0] x_pair,y_line,fill_row,fill_word;
wire inside_window=x_pair>=OUTPUT_X/2 && x_pair<OUTPUT_X/2+SOURCE_WIDTH &&
                   y_line>=OUTPUT_Y && y_line<OUTPUT_Y+2*SOURCE_HEIGHT;
wire accept=m_axis_tvalid && m_axis_tready;
wire [12:0] next_x=accept ? (x_pair==FRAME_WIDTH/2-1 ? 13'b0 : x_pair+13'd1) : x_pair;
wire [12:0] next_y=accept && x_pair==FRAME_WIDTH/2-1 ? y_line+13'd1 : y_line;
wire next_inside=next_x>=OUTPUT_X/2 && next_x<OUTPUT_X/2+SOURCE_WIDTH &&
                 next_y>=OUTPUT_Y && next_y<OUTPUT_Y+2*SOURCE_HEIGHT;
wire [12:0] source_x=next_x-OUTPUT_X/2;
wire [12:0] source_y=(next_y-OUTPUT_Y)>>1;
wire next_ready=next_inside && row_ready[source_y[0]];
wire [$clog2(2*WORDS)-1:0] lookup=(source_y[0] ? WORDS : 0)+(source_x>>2);
wire [$clog2(2*WORDS)-1:0] fill_address=(fill_row[0] ? WORDS : 0)+fill_word;
wire [31:0] pixel=selected_lane==0 ? q0 : selected_lane==1 ? q1 : selected_lane==2 ? q2 : q3;
assign fifo_read=rst_n && !frame_period && fill_row<SOURCE_HEIGHT &&
                 !row_ready[fill_row[0]] && !pending && !fifo_empty;
assign m_axis_tvalid=rst_n && !frame_period && !frame_complete &&
                     (!inside_window || pixel_valid);
assign m_axis_tdata=inside_window ? {pixel,pixel} : 64'b0;
assign m_axis_tuser=m_axis_tvalid && x_pair==0 && y_line==0;
assign m_axis_tlast=m_axis_tvalid && x_pair==FRAME_WIDTH/2-1;
// No data reset: these arrays must infer block RAM, not resettable registers.
always @(posedge clk) begin
    if(rst_n && !frame_period && pending) begin
        lane0[fill_address]<=fifo_data[31:0];lane1[fill_address]<=fifo_data[63:32];
        lane2[fill_address]<=fifo_data[95:64];lane3[fill_address]<=fifo_data[127:96];
    end
    if(next_ready) begin
        q0<=lane0[lookup];q1<=lane1[lookup];q2<=lane2[lookup];q3<=lane3[lookup];
    end
end
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        x_pair<=0;y_line<=0;fill_row<=0;fill_word<=0;
        pending<=0;pixel_valid<=0;row_ready<=0;selected_lane<=0;frame_complete<=0;
    end else if(frame_period) begin
        x_pair<=0;y_line<=0;fill_row<=0;fill_word<=0;
        pending<=0;pixel_valid<=0;row_ready<=0;selected_lane<=0;frame_complete<=0;
    end else begin
        pending<=fifo_read;
        pixel_valid<=next_ready;
        selected_lane<=source_x[1:0];
        if(pending) begin
            if(fill_word==WORDS-1) begin
                row_ready[fill_row[0]]<=1;fill_row<=fill_row+13'd1;fill_word<=0;
            end else fill_word<=fill_word+13'd1;
        end
        if(accept) begin
            x_pair<=next_x;y_line<=next_y;
            if(x_pair==FRAME_WIDTH/2-1 && y_line==FRAME_HEIGHT-1) frame_complete<=1;
            // Release only after both vertical copies have been accepted.
            if(inside_window && x_pair==OUTPUT_X/2+SOURCE_WIDTH-1 &&
               ((y_line-OUTPUT_Y)&1)) row_ready[((y_line-OUTPUT_Y)>>1)&1]<=0;
        end
    end
end
// synthesis translate_off
initial if(SOURCE_WIDTH%4!=0 || OUTPUT_X%2!=0 || SOURCE_WIDTH<4 || SOURCE_HEIGHT<1 ||
           OUTPUT_X+2*SOURCE_WIDTH>FRAME_WIDTH || OUTPUT_Y+2*SOURCE_HEIGHT>FRAME_HEIGHT)
    $fatal(1,"Invalid scale2 geometry");
// synthesis translate_on
endmodule
