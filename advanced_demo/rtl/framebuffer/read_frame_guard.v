// Observe complete read responses, not just the last AR. Original reader has
// one outstanding burst. A frame becomes safe only after its FIFO write pipe idles.
module read_frame_guard # (parameter FRAME_BEATS=518400,
    parameter STRIDED=0,ROW_BEATS=160,ROWS=480,ROW_STRIDE=7680,START_OFFSET=2306560)(
    input wire clk,rst_n,launch,input wire [31:0] frame_base,
    input wire reader_idle,input wire [31:0] araddr,input wire [7:0] arlen,
    input wire [2:0] arsize,input wire [1:0] arburst,input wire arvalid,arready,
    input wire rvalid,rready,rlast,input wire [3:0] rid,input wire [1:0] rresp,
    output wire safe,output reg active,
    output reg [31:0] outstanding,data_beats,reserved_beats,error_code
);
reg started;
reg [31:0] base,ar_bursts,r_bursts;
reg [8:0] burst_left;
reg [31:0] expected_address,row_address,row_remaining;
wire [31:0] address_expected=STRIDED ? expected_address : base+(reserved_beats<<4);
wire af=arvalid&&arready,rf=rvalid&&rready,lf=rf&&rlast;
assign safe=!active && reader_idle && !arvalid && !rvalid && outstanding==0 && error_code==0;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        started<=0;active<=0;base<=0;ar_bursts<=0;r_bursts<=0;
        outstanding<=0;data_beats<=0;reserved_beats<=0;error_code<=0;burst_left<=0;
        expected_address<=0;row_address<=0;row_remaining<=0;
    end else begin
        if(launch) begin
            if(!safe) error_code<=32'h2001;
            started<=1;active<=1;base<=frame_base;
            ar_bursts<=0;r_bursts<=0;outstanding<=0;data_beats<=0;reserved_beats<=0;burst_left<=0;
            expected_address<=frame_base+START_OFFSET;row_address<=frame_base+START_OFFSET;row_remaining<=ROW_BEATS;
        end else begin
            case({af,lf})
                2'b10:outstanding<=outstanding+1;
                2'b01:outstanding<=outstanding-1;
                default:;
            endcase
            if(af) begin
                ar_bursts<=ar_bursts+1;reserved_beats<=reserved_beats+{24'b0,arlen}+1;
                burst_left<={1'b0,arlen}+1'b1;
                if(STRIDED) begin
                    if({24'b0,arlen}+1==row_remaining) begin
                        row_address<=row_address+ROW_STRIDE;expected_address<=row_address+ROW_STRIDE;
                        row_remaining<=ROW_BEATS;
                    end else begin
                        expected_address<=expected_address+(({24'b0,arlen}+1)<<4);
                        row_remaining<=row_remaining-({24'b0,arlen}+1);
                    end
                end
                if(!active || burst_left!=0 || araddr!=address_expected ||
                   (STRIDED && {24'b0,arlen}+1>row_remaining) ||
                   arsize!=4 || arburst!=1 || reserved_beats+{24'b0,arlen}+1>FRAME_BEATS ||
                   {1'b0,araddr[11:0]}+(({5'b0,arlen}+1)<<4)>4096) error_code<=32'h2002;
            end
            if(rf) begin
                data_beats<=data_beats+1;burst_left<=burst_left-1'b1;
                if(rlast) r_bursts<=r_bursts+1;
                if(!active || outstanding==0 || burst_left==0 || rlast!=(burst_left==1) || data_beats>=FRAME_BEATS)
                    error_code<=32'h2002;
                if(rresp!=0 || rid!=0) error_code<=32'h2003;
            end
            if(started && active && data_beats==FRAME_BEATS && reserved_beats==FRAME_BEATS &&
               outstanding==0 && ar_bursts==r_bursts && burst_left==0 && reader_idle && !arvalid && !rvalid)
                active<=0;
        end
    end
end
endmodule
