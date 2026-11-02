// Only the event crosses domains. All buffer addresses stay on core_clk.
// Events must be separated by >= 4 core clocks (actual frame period ~16.7ms).
module video_frame_cdc (
    input wire video_clk,video_rst_n,video_period,
    input wire core_clk,core_rst_n,
    output wire boundary_tick,output wire blank_active
);
reg period_d,toggle;
always @(posedge video_clk or negedge video_rst_n)
    if(!video_rst_n) begin period_d<=0;toggle<=0;end
    else begin
        period_d<=video_period;
        if(video_period && !period_d) toggle<=~toggle;
    end
(* async_reg="true" *) reg [2:0] event_sync,blank_sync;
reg seen;
always @(posedge core_clk or negedge core_rst_n)
    if(!core_rst_n) begin event_sync<=0;blank_sync<=0;seen<=0;end
    else begin
        event_sync<={event_sync[1:0],toggle};
        blank_sync<={blank_sync[1:0],video_period};
        seen<=event_sync[2];
    end
assign boundary_tick=event_sync[2]^seen;
assign blank_active=blank_sync[2];
endmodule
