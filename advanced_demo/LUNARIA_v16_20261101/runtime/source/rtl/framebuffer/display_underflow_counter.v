// Count every asserted CVO underflow video cycle, including startup. Registered
// Gray code crosses to core; no narrow pulse or raw binary counter crossing.
module display_underflow_counter (
    input wire video_clk,video_rst_n,underflow,
    input wire core_clk,core_rst_n,
    output reg [31:0] count
);
reg [31:0] binary_count,gray_count;
wire [31:0] next_count=binary_count+1'b1;
(* async_reg="true" *) reg [31:0] gray_sync0,gray_sync1,gray_sync2;
reg [31:0] decoded;
integer i;
always @(posedge video_clk or negedge video_rst_n)
    if(!video_rst_n) begin binary_count<=0;gray_count<=0;end
    else if(underflow) begin binary_count<=next_count;gray_count<=(next_count>>1)^next_count;end
always @(*) begin
    decoded[31]=gray_sync2[31];
    for(i=30;i>=0;i=i-1) decoded[i]=decoded[i+1]^gray_sync2[i];
end
always @(posedge core_clk or negedge core_rst_n)
    if(!core_rst_n) begin gray_sync0<=0;gray_sync1<=0;gray_sync2<=0;count<=0;end
    else begin gray_sync0<=gray_count;gray_sync1<=gray_sync0;gray_sync2<=gray_sync1;count<=decoded;end
endmodule
