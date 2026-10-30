// Normal-mode FIFO adapter with two beat slots and one-cycle read latency.
// Low 64 bits (P0/P1) precede high 64 bits (P2/P3). Supports AXIS stalls.
module rgb_unpack128_to64 #(
    parameter FRAME_WIDTH = 1920,
    parameter FRAME_HEIGHT = 1080
)(
    input wire clk, input wire rst_n, input wire frame_period,
    input wire [127:0] fifo_data, input wire fifo_empty,
    output wire fifo_read,
    output wire [63:0] m_axis_tdata,
    output wire m_axis_tvalid, input wire m_axis_tready,
    output wire m_axis_tuser, output wire m_axis_tlast
);
reg [127:0] words [0:1];
reg wr_index, rd_index, high_half, pending, period_d;
reg [1:0] count;
reg [12:0] x_pair, y_line;
reg frame_complete;
wire flush = frame_period && !period_d;
wire accept = m_axis_tvalid && m_axis_tready;
wire pop_word = accept && high_half;
wire [2:0] occupied = {1'b0,count} + {2'b0,pending};
assign fifo_read = rst_n && !frame_period && !frame_complete && !fifo_empty &&
                   (occupied < 2 || pop_word);
assign m_axis_tvalid = rst_n && !frame_period && !frame_complete && count != 0;
assign m_axis_tdata = high_half ? words[rd_index][127:64] : words[rd_index][63:0];
assign m_axis_tlast = m_axis_tvalid && x_pair == FRAME_WIDTH/2-1;
assign m_axis_tuser = m_axis_tvalid && x_pair == 0 && y_line == 0;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        period_d <= 0;
        wr_index <= 0; rd_index <= 0; count <= 0;
        high_half <= 0; pending <= 0;
        x_pair <= 0; y_line <= 0; frame_complete <= 0;
    end else begin
        period_d <= frame_period;
        if (flush) begin
            wr_index <= 0; rd_index <= 0; count <= 0;
            high_half <= 0; pending <= 0;
            x_pair <= 0; y_line <= 0; frame_complete <= 0;
        end else begin
            pending <= fifo_read;
            if (pending) begin
                words[wr_index] <= fifo_data;
                wr_index <= ~wr_index;
            end
            if (pop_word) rd_index <= ~rd_index;
            case ({pending,pop_word})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase
            if (accept) begin
                high_half <= ~high_half;
                if (x_pair == FRAME_WIDTH/2-1) begin
                    x_pair <= 0;
                    if (y_line == FRAME_HEIGHT-1) frame_complete <= 1;
                    else y_line <= y_line + 1'b1;
                end else x_pair <= x_pair + 1'b1;
            end
        end
    end
end
endmodule
