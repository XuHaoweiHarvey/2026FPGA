// The one-way ownership barrier. Beat counts and burst counts have distinct units.
module init_write_monitor #(
    parameter FRAME_BEATS=518400, WATCHDOG_BITS=27
)(
    input wire clk,rst_n,source_done,fifo_empty,writer_idle,source_overflow,
    input wire [31:0] awaddr,input wire [7:0] awlen,input wire [2:0] awsize,
    input wire [1:0] awburst,input wire awvalid,awready,
    input wire [15:0] wstrb,input wire wvalid,wready,wlast,
    input wire [3:0] bid,input wire [1:0] bresp,input wire bvalid,bready,
    output reg init_done,output reg [31:0] init_error,
    output reg [31:0] data_beats,aw_bursts,wlast_bursts,b_responses,aw_reserved_beats
);
wire af=awvalid&&awready,wf=wvalid&&wready,bf=bvalid&&bready;
reg [8:0] data_left;
reg [WATCHDOG_BITS-1:0] watchdog;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        init_done<=0;init_error<=0;data_beats<=0;aw_bursts<=0;
        wlast_bursts<=0;b_responses<=0;aw_reserved_beats<=0;data_left<=0;watchdog<=0;
    end else if(!init_done) begin
        if(af || wf || bf) watchdog<=0;
        else if((aw_bursts!=0 || source_done) && !(&watchdog)) watchdog<=watchdog+1'b1;
        if(source_overflow) init_error<=32'h1001;
        if(&watchdog) init_error<=32'h1004;
        if(af) begin
            aw_bursts<=aw_bursts+1;aw_reserved_beats<=aw_reserved_beats+{24'b0,awlen}+1;
            data_left<={1'b0,awlen}+1'b1;
            if(data_left!=0 || awaddr!=(aw_reserved_beats<<4) || awsize!=4 || awburst!=1 ||
               aw_reserved_beats+{24'b0,awlen}+1>FRAME_BEATS ||
               {1'b0,awaddr[11:0]}+(({5'b0,awlen}+1)<<4)>4096) init_error<=32'h1003;
        end
        if(wf) begin
            data_beats<=data_beats+1;
            if(wlast) wlast_bursts<=wlast_bursts+1;
            data_left<=data_left-1'b1;
            if(data_left==0 || wlast!=(data_left==1) || wstrb!=16'hffff || data_beats>=FRAME_BEATS)
                init_error<=32'h1003;
        end
        if(bf) begin
            b_responses<=b_responses+1;
            if(b_responses>=aw_bursts || b_responses>=wlast_bursts) init_error<=32'h1003;
            if(bresp!=0 || bid!=0) init_error<=32'h1002;
        end
        // Counters here reflect prior completed edges. In particular, the last
        // B must have been accepted successfully before this condition can pass.
        if(init_error==0 && !source_overflow && !(&watchdog) && source_done && fifo_empty && writer_idle &&
           !awvalid && !wvalid && !bvalid && data_left==0 &&
           data_beats==FRAME_BEATS && aw_reserved_beats==FRAME_BEATS && aw_bursts!=0 &&
           aw_bursts==wlast_bursts && aw_bursts==b_responses) init_done<=1;
    end
end
endmodule
