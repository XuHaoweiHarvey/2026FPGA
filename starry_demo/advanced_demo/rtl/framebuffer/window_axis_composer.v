// Emit a complete 1080p AXIS frame, consuming DDR words only inside viewport.
// Same normal FIFO one-cycle latency as rgb_unpack128_to64; two word slots.
module window_axis_composer #(
    parameter FRAME_WIDTH=1920,FRAME_HEIGHT=1080,
    parameter VIEW_X=640,VIEW_Y=300,VIEW_WIDTH=640,VIEW_HEIGHT=480
)(
    input wire clk,rst_n,frame_period,
    input wire [127:0] fifo_data,input wire fifo_empty,output wire fifo_read,
    output wire [63:0] m_axis_tdata,output wire m_axis_tvalid,
    input wire m_axis_tready,output wire m_axis_tuser,m_axis_tlast
);
reg [127:0] words[0:1];
reg wr_index,rd_index,high_half,pending,period_d;
reg [1:0] count;
reg [12:0] x_pair,y_line;
reg frame_complete,window_complete;
wire inside_window=x_pair>=VIEW_X/2 && x_pair<(VIEW_X+VIEW_WIDTH)/2 &&
                   y_line>=VIEW_Y && y_line<VIEW_Y+VIEW_HEIGHT;
wire accept=m_axis_tvalid && m_axis_tready;
wire consume=accept && inside_window;
wire pop_word=consume && high_half;
wire [2:0] occupied={1'b0,count}+{2'b0,pending};
assign fifo_read=rst_n && !frame_period && !window_complete && !fifo_empty &&
                 (occupied<2 || pop_word);
assign m_axis_tvalid=rst_n && !frame_period && !frame_complete &&
                     (!inside_window || count!=0);
assign m_axis_tdata=inside_window ?
    (high_half ? words[rd_index][127:64] : words[rd_index][63:0]) : 64'b0;
assign m_axis_tuser=m_axis_tvalid && x_pair==0 && y_line==0;
assign m_axis_tlast=m_axis_tvalid && x_pair==FRAME_WIDTH/2-1;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        wr_index<=0;rd_index<=0;high_half<=0;pending<=0;period_d<=0;count<=0;
        x_pair<=0;y_line<=0;frame_complete<=0;window_complete<=0;
    end else begin
        period_d<=frame_period;
        if(frame_period && !period_d) begin
            wr_index<=0;rd_index<=0;high_half<=0;pending<=0;count<=0;
            x_pair<=0;y_line<=0;frame_complete<=0;window_complete<=0;
        end else begin
            pending<=fifo_read;
            if(pending) begin words[wr_index]<=fifo_data;wr_index<=~wr_index;end
            if(pop_word) rd_index<=~rd_index;
            case({pending,pop_word})
                2'b10: count<=count+1'b1;
                2'b01: count<=count-1'b1;
                default:;
            endcase
            if(consume) begin
                high_half<=~high_half;
                if(x_pair==(VIEW_X+VIEW_WIDTH)/2-1 && y_line==VIEW_Y+VIEW_HEIGHT-1)
                    window_complete<=1;
            end
            if(accept) begin
                if(x_pair==FRAME_WIDTH/2-1) begin
                    x_pair<=0;
                    if(y_line==FRAME_HEIGHT-1) frame_complete<=1;
                    else y_line<=y_line+1'b1;
                end else x_pair<=x_pair+1'b1;
            end
        end
    end
end
// synthesis translate_off
initial if(VIEW_X%4!=0 || VIEW_WIDTH%4!=0 || VIEW_WIDTH<4 || VIEW_HEIGHT<1 ||
           VIEW_X+VIEW_WIDTH>FRAME_WIDTH || VIEW_Y+VIEW_HEIGHT>FRAME_HEIGHT)
    $fatal(1,"Invalid window composer geometry");
// synthesis translate_on
endmodule
