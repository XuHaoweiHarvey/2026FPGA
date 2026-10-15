`timescale 1ns/1ps
// Exercise real legacy DDR writers/readers and DC_FIFO against byte-addressed
// mock DDR. Four different adjacent pixels cannot hide reversed lane order.
module tb_rgb_framebuffer;
parameter WIDTH=64, HEIGHT=64;
localparam BEATS=WIDTH*HEIGHT/4;
localparam SLOT_BEATS=BEATS+32;
localparam [31:0] P0=32'h00ff0000, P1=32'h0000ff00;
localparam [31:0] P2=32'h000000ff, P3=32'h00123456;
localparam [127:0] PATTERN={P3,P2,P1,P0};
reg axi_clk=0, i_clk=0, o_clk=0, rst_n=0;
always #5 axi_clk=~axi_clk;
always #10 i_clk=~i_clk;
always #6.734 o_clk=~o_clk;
reg frame_start=0, source_de=0, period=0;
reg [127:0] vin=PATTERN;
wire [31:0] awaddr,araddr;
wire [7:0] awlen,arlen;
wire [2:0] awsize,arsize;
wire [1:0] awburst,arburst;
wire awvalid,wvalid,wlast,bready,arvalid,rready;
wire [127:0] wdata;
wire [15:0] wstrb;
reg bvalid=0,rvalid=0,rlast=0;
reg [127:0] rdata=0;
reg write_active=0,read_active=0;
integer w_index=0,w_left=0,r_index=0,r_left=0;
integer ticks=0,w_beats=0,r_beats=0,aw_count=0,ar_count=0,b_count=0;
wire awready=!write_active && ticks%5!=0;
wire wready=write_active && ticks%7!=0;
wire arready=!read_active && !rvalid && ticks%3!=0;
wire [63:0] axis_data;
wire axis_valid,axis_last,axis_user,full;
reg axis_ready=0;
wire [1:0] wr_bank,rd_bank;
rgb_framebuffer #(.FRAME_WIDTH(WIDTH),.FRAME_HEIGHT(HEIGHT)) dut (
    .axi_clk(axi_clk),.rst_n(rst_n),.i_clk(i_clk),.i_frame_start(frame_start),
    .i_de(source_de),.vin(vin),.o_clk(o_clk),.fifo_rd_period(period),
    .m_axis_tdata(axis_data),.m_axis_tvalid(axis_valid),.m_axis_tready(axis_ready),
    .m_axis_tlast(axis_last),.m_axis_tuser(axis_user),
    .awaddr(awaddr),.awlen(awlen),.awsize(awsize),.awburst(awburst),
    .awvalid(awvalid),.awready(awready),.wdata(wdata),.wstrb(wstrb),
    .wlast(wlast),.wvalid(wvalid),.wready(wready),
    .bid(4'b0),.bvalid(bvalid),.bready(bready),
    .araddr(araddr),.arlen(arlen),.arsize(arsize),.arburst(arburst),
    .arvalid(arvalid),.arready(arready),.rid(4'b0),.rdata(rdata),
    .rlast(rlast),.rvalid(rvalid),.rready(rready),.rresp(2'b0),
    .diag_wr_fifo_full(full),.diag_wr_bank(wr_bank),.diag_rd_bank(rd_bank));
reg [127:0] memory [0:3*SLOT_BEATS-1];
integer j,lane;
always @(posedge axi_clk) begin
    if(rst_n) begin
        ticks<=ticks+1;
        if(bvalid && bready) begin bvalid<=0; b_count<=b_count+1; end
        if(awvalid && awready) begin
            if(awsize!=4 || awburst!=1 || awaddr[3:0]!=0 ||
                awaddr[11:0]+(awlen+1)*16>4096) $fatal(1,"Bad AW burst/alignment");
            if(awaddr/16>=3*SLOT_BEATS) $fatal(1,"AW outside mock DDR");
            write_active<=1; w_index<=awaddr/16; w_left<=awlen+1;
            aw_count<=aw_count+1;
        end
        if(wvalid && wready) begin
            if(wstrb!==16'hffff || wdata!==PATTERN || wlast!==(w_left==1))
                $fatal(1,"AXI WDATA/WSTRB/WLAST at beat %0d: %h",w_beats,wdata);
            for(lane=0;lane<16;lane=lane+1)
                if(wstrb[lane]) memory[w_index][lane*8+:8]<=wdata[lane*8+:8];
            // Explicit byte layout: red P0 is bytes 00 00 FF 00.
            if(wdata[31:0]!==P0 || wdata[63:32]!==P1 ||
               wdata[95:64]!==P2 || wdata[127:96]!==P3) $fatal(1,"AXI lane order");
            w_index<=w_index+1; w_left<=w_left-1; w_beats<=w_beats+1;
            if(w_left==1) begin write_active<=0; bvalid<=1; end
        end
        if(arvalid && arready) begin
            if(arsize!=4 || arburst!=1 || araddr[3:0]!=0 ||
                araddr[11:0]+(arlen+1)*16>4096 || araddr/16>=3*SLOT_BEATS)
                $fatal(1,"Bad AR burst");
            read_active<=1; r_index<=araddr/16; r_left<=arlen+1;
            ar_count<=ar_count+1;
        end
        if(rvalid && rready) begin rvalid<=0; r_beats<=r_beats+1; end
        if(read_active && (!rvalid || rready) && ticks%4!=0) begin
            rvalid<=1; rdata<=memory[r_index]; rlast<=(r_left==1);
            r_index<=r_index+1; r_left<=r_left-1;
            if(r_left==1) read_active<=0;
        end
    end
end
reg stalled=0;
reg [65:0] stalled_value;
always @(posedge o_clk) begin
    if(rst_n && !period) begin
        if(stalled && (!axis_valid || {axis_user,axis_last,axis_data}!==stalled_value))
            $fatal(1,"AXIS data changed under backpressure");
        stalled <= axis_valid && !axis_ready;
        stalled_value <= {axis_user,axis_last,axis_data};
    end else stalled <= 0;
end
integer pairs=0,frame_number=0,video_ticks=0;
reg checking=0;
reg [63:0] expected;
always @(negedge o_clk) begin
    video_ticks=video_ticks+1;
    axis_ready=rst_n && !period && video_ticks%6!=0;
end
always @(posedge i_clk) if(source_de && full) $fatal(1,"Writer FIFO overflow");
always @(posedge o_clk) if(checking && axis_valid && axis_ready) begin
    expected=(frame_number==1) ? 64'b0 : ((pairs%2) ? {P3,P2}:{P1,P0});
    if(axis_data!==expected) $fatal(1,"RGB unpack frame %0d pair %0d: %h != %h",frame_number,pairs,axis_data,expected);
    if(axis_user!==(pairs==0) || axis_last!==(pairs%(WIDTH/2)==WIDTH/2-1))
        $fatal(1,"RGB AXIS frame/line markers");
    pairs=pairs+1;
end
task read_frame;
begin
    @(negedge o_clk); checking=0; period=1;
    repeat(30) @(negedge o_clk);
    pairs=0; frame_number=frame_number+1; checking=1; period=0;
    wait(pairs==WIDTH*HEIGHT/2);
    @(negedge o_clk); checking=0;
    repeat(30) @(negedge o_clk);
end
endtask
initial begin
    for(j=0;j<3*SLOT_BEATS;j=j+1) memory[j]=0;
    repeat(20) @(negedge i_clk); rst_n=1;
    repeat(20) @(negedge i_clk); frame_start=1;
    @(negedge i_clk); frame_start=0;
    repeat(30) @(negedge i_clk);
    for(j=0;j<HEIGHT;j=j+1) begin
        source_de=1; repeat(WIDTH/4) @(negedge i_clk);
        source_de=0; repeat(30) @(negedge i_clk);
    end
    wait(w_beats==BEATS && b_count==BEATS/128);
    repeat(20) @(negedge axi_clk);
    for(j=0;j<BEATS;j=j+1) if(memory[j]!==PATTERN) $fatal(1,"DDR memory beat %0d",j);
    for(j=BEATS;j<3*SLOT_BEATS;j=j+1) if(memory[j]!==0) $fatal(1,"Slot padding/other slot modified");
    $display("RGB DDR write/memory check complete: %0d beats; reading initial slot 1",w_beats);
    read_frame; // Initial camera reader bank is slot 1.
    $display("RGB DDR initial slot read complete; reading completed slot 0");
    read_frame; // Original bank_switch now selects completed slot 0.
    if(r_beats!=BEATS*2 || aw_count!=BEATS/128) $fatal(1,"AXI/frame totals");
    $display("PASS RGB DDR: %0d written beats, byte lanes P0/P1/P2/P3, triple slots, two read frames, AXIS stalls",w_beats);
    $finish;
end
initial begin #(BEATS*200); $fatal(1,"RGB DDR timeout writes=%0d reads=%0d pairs=%0d",w_beats,r_beats,pairs); end
endmodule
