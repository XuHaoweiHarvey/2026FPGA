`timescale 1ns/1ps
// Replay real C-renderer commands with the actual atlas, compare every RGB
// pixel. Controlled AXI latency, not a model of the physical DDR controller.
module tb_lunaria_tile_trace;
parameter BATCH_SIZE=1024,TW=128,TH=48;
integer states[0:31],astates[0:31];
initial for(integer z=0;z<32;z=z+1)begin states[z]=0;astates[z]=0;end
always @(posedge clk)if(rst_n)begin states[dut.state]=states[dut.state]+1;astates[dut.core.alpha_path.alpha_unit.state]=astates[dut.core.alpha_path.alpha_unit.state]+1;end
wire pending;reg flush_request=0;
parameter OVERLAP=0, READ_AHEAD=0, READ_DEPTH=1;
reg clk=0,rst_n=0,start=0;
always #5 clk=~clk;
reg [31:0] op,src,stride,x,y,w,h,color;
wire busy,done;wire [31:0] error_code,araddr,awaddr;
wire [7:0] arlen,awlen;wire arvalid,rready,awvalid,wvalid,wlast,bready;
wire [127:0] wdata;wire [15:0] wstrb;
wire [511:0] perf;
reg [127:0] rdata=0;
reg rvalid=0,rlast=0,bvalid=0,ra_active=0,wa_active=0;
integer cycle=0,ri=0,rl=0,wi=0,wl=0,rd_delay=0,bd_delay=0;
reg [31:0] ra,wa;
reg [31:0] atlas[0:307199],memory[0:307199],expected[0:307199];
reg [2047:0] atlas_file,bg_file,expected_file,commands_file;
integer fd,n,scan,i,lane,began,frame_start,commands=0,rdbeats=0,wrbeats=0;
function integer local_pixel;
input [31:0] address;
integer row,col;
begin
    row=address/7680;col=(address%7680)/4;
    if(row<300 || row>=780 || col<640 || col>=1280) begin
        $display("outside gameplay window %h row=%0d col=%0d",address,row,col);
        $fatal(1,"rectangle escaped window");
    end
    local_pixel=(row-300)*640+col-640;
end endfunction
reg [31:0] read_addresses[0:3];
reg [7:0] read_lengths[0:3];
integer read_available[0:3];
integer read_head=0,read_tail=0;
wire arready=read_tail-read_head<READ_DEPTH && cycle%7!=0;
wire awready=!wa_active && !bvalid && bd_delay==0 && cycle%6!=0;
wire wready=cycle%5!=0;
tiled_graphics_engine #(.BATCH_SIZE(BATCH_SIZE),.TILE_WIDTH(TW),.TILE_HEIGHT(TH),.ALPHA_ENABLE(1),.ALPHA_STREAM_ENABLE(1),.ALPHA_SPRITE_CACHE_ENABLE(1),
    .ALPHA_WIDE_CACHE_ENABLE(1),.BEAM_ENABLE(1),.ALPHA_OVERLAP_ENABLE(OVERLAP),.ALPHA_READ_AHEAD_ENABLE(READ_AHEAD)) dut(
    .clk(clk),.rst_n(rst_n),.enabled(1'b1),.start(start),.op(op),.x(x),.y(y),
    .width(w),.height(h),.color(color),.src_addr(src),.src_stride(stride),
    .flush_request(flush_request),.pending(pending),.back_base(32'h00800000),.src_range_valid(1'b1),.busy(busy),.done(done),.error_code(error_code),
    .alpha_perf_counters(perf),.araddr(araddr),.arlen(arlen),.arvalid(arvalid),.arready(arready),
    .rdata(rdata),.rid(4'b0),.rresp(2'b0),.rlast(rlast),.rvalid(rvalid),.rready(rready),
    .awaddr(awaddr),.awlen(awlen),.awvalid(awvalid),.awready(awready),.wdata(wdata),.wstrb(wstrb),
    .wlast(wlast),.wvalid(wvalid),.wready(wready),.bid(4'b0),.bresp(2'b0),.bvalid(bvalid),.bready(bready));
always @(negedge clk) begin
    if(!rst_n) begin rvalid=0;rlast=0;end
    else if(!rvalid || rready) begin
        ra_active=read_tail!=read_head;
        ra=read_addresses[read_head%4];rl=read_lengths[read_head%4];
        rvalid=ra_active && cycle>=read_available[read_head%4] && cycle%4!=0;
        rlast=ri==rl;
        if(rvalid) for(lane=0;lane<4;lane=lane+1) begin
            if(ra>=32'h01384000 && ra<32'h014b0000)
                rdata[lane*32+:32]=atlas[(ra-32'h01384000)/4+ri*4+lane];
            else rdata[lane*32+:32]=memory[local_pixel(ra-32'h00800000+ri*16+lane*4)];
        end
    end
end
always @(posedge clk) begin
    cycle<=cycle+1;
    if(rst_n) begin
        if(arvalid&&arready) begin
            if({1'b0,araddr[11:0]}+(arlen+1)*16>4096) $fatal(1,"read protocol");
            read_addresses[read_tail%4]<=araddr;read_lengths[read_tail%4]<=arlen;
            read_available[read_tail%4]<=cycle+12;read_tail<=read_tail+1;
        end else if(rd_delay) rd_delay<=rd_delay-1;
        if(rvalid&&rready) begin
            rdbeats<=rdbeats+1;
            if(rlast) begin read_head<=read_head+1;ri<=0;end else ri<=ri+1;
        end
        if(awvalid&&awready) begin
            if({1'b0,awaddr[11:0]}+(awlen+1)*16>4096) $fatal(1,"write page");
            wa_active<=1;wa<=awaddr;wl<=awlen;wi<=0;
        end
        if(wvalid&&wready) begin
            if(!wa_active || wlast!==(wi==wl)) $fatal(1,"write protocol");
            for(integer p=0;p<4;p=p+1) for(integer byte_lane=0;byte_lane<4;byte_lane=byte_lane+1)
                if(wstrb[p*4+byte_lane]) memory[local_pixel(wa+wi*16+p*4)][byte_lane*8+:8]<=wdata[p*32+byte_lane*8+:8];
            wrbeats<=wrbeats+1;
            if(wlast) begin wa_active<=0;bd_delay<=12;end else wi<=wi+1;
        end
        if(bd_delay) begin bd_delay<=bd_delay-1;if(bd_delay==1)bvalid<=1;end
        if(bvalid&&bready)bvalid<=0;
    end
end
initial begin
    if(!$value$plusargs("ATLAS=%s",atlas_file) || !$value$plusargs("BG=%s",bg_file) ||
       !$value$plusargs("EXPECTED=%s",expected_file) || !$value$plusargs("COMMANDS=%s",commands_file)) $fatal(1,"missing input");
    $readmemh(atlas_file,atlas);$readmemh(bg_file,memory);$readmemh(expected_file,expected);
    fd=$fopen(commands_file,"r");if(!fd)$fatal(1,"commands file");
    repeat(3)@(negedge clk);rst_n=1;frame_start=cycle;
    while(!$feof(fd)) begin
        scan=$fscanf(fd,"%h %h %h %h %h %h %h %h\n",op,src,stride,x,y,w,h,color);
        if(scan!=8)$fatal(1,"command parse");
        if(op==1)$fatal(1,"background must be restored before replay");
        @(negedge clk);while(busy)@(negedge clk);start=1;began=cycle;
        @(negedge clk);start=0;
        while(busy) begin @(negedge clk);if(cycle-began>2000000)$fatal(1,"timeout");end
        if(!done || error_code || read_head!=read_tail || wa_active || bvalid || bd_delay)$fatal(1,"completion");
        commands=commands+1;
    end
    flush_request=1;
    while(pending || busy)@(negedge clk);
    if(error_code || read_head!=read_tail || wa_active || bvalid || bd_delay)$fatal(1,"final barrier");
    for(i=0;i<307200;i=i+1)
        if(memory[i][23:0]!==expected[i][23:0])$fatal(1,"RGB mismatch pixel=%0d got=%h want=%h",i,memory[i],expected[i]);
    $display("PASS TRACE overlap=%0d ahead=%0d commands=%0d cycles=%0d read_beats=%0d write_beats=%0d exact_RGB_pixels=307200",OVERLAP,READ_AHEAD,commands,cycle-frame_start,rdbeats,wrbeats);
    for(integer z=0;z<25;z=z+1)$display("STATE %0d wrapper=%0d alpha=%0d",z,states[z],astates[z]);
    $finish;
end
initial begin #1000000000;$fatal(1,"global timeout");end
endmodule
