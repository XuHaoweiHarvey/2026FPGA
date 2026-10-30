`timescale 1ns/1ps
// Exact reference pixels plus DDR stalls, clipped cache hits, page splitting,
// cache read-error validity, reset lifetime and measured command cycle counts.
module tb_alpha_stream_cache;
parameter STREAM=1, CACHE=1;
localparam TILE=32'h01384240, STRIDE=1024, FRAME_WORDS=256*48;
reg clk=0,rst_n=0,start=0;
always #5 clk=~clk;
reg [31:0] src=TILE,ss=2560,back=32'h00200000,x=4,y=1,w=16,h=16;
reg [7:0] ga=225;
wire busy,done;wire [31:0] error_code,count,araddr,awaddr;
wire [7:0] arlen,awlen;wire arvalid,arready,rready,awvalid,awready,wvalid,wready,wlast,bready;
wire [127:0] wdata;wire [15:0] wstrb;
reg [127:0] rdata;wire rvalid,rlast;wire [1:0] rresp;
reg bvalid=0;reg [1:0] bresp=0;
reg read_active=0,write_active=0,read_hold=0;
reg [31:0] ra,wa;
integer ri=0,rl=0,wi=0,wl=0,bd=0;
integer cycle=0,source_reads=0,bg_reads=0,writes=0,checked=0;
reg [31:0] memory[0:FRAME_WORDS-1],expected[0:FRAME_WORDS-1];
reg inject_source_error=0,inject_bg_error=0,inject_write_error=0;
integer i,p,addr_index,elapsed,cold_cycles,warm_cycles,reads_before,bg_before;
reg stalled_aw=0,stalled_ar=0,stalled_w=0;
reg [31:0] held_aw,held_ar;reg [7:0] held_awlen,held_arlen;
reg [127:0] held_w;reg held_last;
assign arready=(cycle%7 != 0 && cycle%7 != 1);
assign awready=(cycle%6 != 0 && cycle%6 != 1);
assign wready=(cycle%5 != 0 && cycle%5 != 1);
assign rvalid=read_active && (read_hold || cycle%4!=0);
assign rlast=ri==rl;
assign rresp=((ra>=32'h01000000 ? inject_source_error : inject_bg_error) && ri==0) ? 2'b10 : 0;
function [31:0] foreground;
input [31:0] a;
begin foreground={(a[9:2]*8'd47+8'd13),(a[11:4]*8'd29),(a[8:1]*8'd17),(a[10:3]*8'd7)};end
endfunction
function [31:0] blend;
input [31:0] fg,bg;input [7:0] alpha;
integer a,r,g,b;
begin
    a=((fg>>24)*alpha+127)/255;
    r=(((fg>>16)&255)*a+((bg>>16)&255)*(255-a)+127)/255;
    g=(((fg>>8)&255)*a+((bg>>8)&255)*(255-a)+127)/255;
    b=((fg&255)*a+(bg&255)*(255-a)+127)/255;
    blend=(bg&32'hff000000)|(r<<16)|(g<<8)|b;
end endfunction
alpha_blit_engine #(.FRAME_WIDTH(256),.FRAME_HEIGHT(48),.FRAME_STRIDE(STRIDE),
    .MAX_BURST_BEATS(32),.STREAM_ENABLE(STREAM),.SPRITE_CACHE_ENABLE(CACHE),.WATCHDOG_BITS(12)) dut(
    .clk(clk),.rst_n(rst_n),.enabled(1'b1),.start(start),
    .src_addr(src),.src_stride(ss),.back_base(back),.global_alpha(ga),
    .dst_x(x),.dst_y(y),.width(w),.height(h),.busy(busy),.done(done),
    .error_code(error_code),.command_count(count),
    .araddr(araddr),.arlen(arlen),.arvalid(arvalid),.arready(arready),
    .rdata(rdata),.rid(4'b0),.rresp(rresp),.rlast(rlast),.rvalid(rvalid),.rready(rready),
    .awaddr(awaddr),.awlen(awlen),.awvalid(awvalid),.awready(awready),
    .wdata(wdata),.wstrb(wstrb),.wlast(wlast),.wvalid(wvalid),.wready(wready),
    .bid(4'b0),.bresp(bresp),.bvalid(bvalid),.bready(bready));
always @* begin
    rdata=0;
    if(read_active) for(integer lane=0;lane<4;lane=lane+1)
        rdata[lane*32+:32]=ra>=32'h01000000 ? foreground(ra+ri*16+lane*4) :
            memory[(ra-back)/4+ri*4+lane];
end
always @(posedge clk) begin
    cycle<=cycle+1;
    if(!rst_n) begin
        read_active<=0;write_active<=0;bvalid<=0;bd<=0;read_hold<=0;
        stalled_ar<=0;stalled_aw<=0;stalled_w<=0;
    end else begin
        if(stalled_ar && (!arvalid || araddr!==held_ar || arlen!==held_arlen)) $fatal(1,"AR changed under stall");
        if(stalled_aw && (!awvalid || awaddr!==held_aw || awlen!==held_awlen)) $fatal(1,"AW changed under stall");
        if(stalled_w && (!wvalid || wdata!==held_w || wlast!==held_last)) $fatal(1,"W changed under stall");
        stalled_ar<=arvalid&&!arready;held_ar<=araddr;held_arlen<=arlen;
        stalled_aw<=awvalid&&!awready;held_aw<=awaddr;held_awlen<=awlen;
        stalled_w<=wvalid&&!wready;held_w<=wdata;held_last<=wlast;
        read_hold<=rvalid&&!rready;
        if(arvalid&&arready) begin
            if(read_active) $fatal(1,"overlapping read");
            if({1'b0,araddr[11:0]}+(arlen+1)*16>4096) $fatal(1,"AR crossed page");
            read_active<=1;ra<=araddr;rl<=arlen;ri<=0;
            if(araddr>=32'h01000000) source_reads<=source_reads+1;
            else bg_reads<=bg_reads+1;
        end
        if(rvalid&&rready) begin
            if(rlast) read_active<=0;else ri<=ri+1;
        end
        if(awvalid&&awready) begin
            if(write_active || bvalid || bd) $fatal(1,"overlapping write");
            if({1'b0,awaddr[11:0]}+(awlen+1)*16>4096) $fatal(1,"AW crossed page");
            write_active<=1;wa<=awaddr;wl<=awlen;wi<=0;writes<=writes+1;
        end
        if(wvalid&&wready) begin
            if(!write_active || wlast!==(wi==wl) || wstrb!==16'hffff) $fatal(1,"write protocol");
            for(integer lane=0;lane<4;lane=lane+1) begin
                if(wdata[lane*32+:32] !== expected[wa/4+wi*4+lane])
                    $fatal(1,"pixel mismatch addr=%h got=%h expected=%h",wa+wi*16+lane*4,wdata[lane*32+:32],expected[wa/4+wi*4+lane]);
                memory[wa/4+wi*4+lane]<=wdata[lane*32+:32];
                checked=checked+1;
            end
            if(wlast) begin write_active<=0;bd<=4;end else wi<=wi+1;
        end
        if(bd) begin bd<=bd-1;if(bd==1) begin bvalid<=1;bresp<=inject_write_error?2'b10:0;end end
        if(bvalid&&bready) bvalid<=0;
        if(done&&!busy && (read_active||write_active||bvalid||bd)) $fatal(1,"early completion");
    end
end
task command;
input [31:0] s,stride,dx,dy,ww,hh;
input [7:0] alpha;
input [31:0] want_error;
integer row,col,began;
begin
    @(negedge clk);src=s;ss=stride;x=dx;y=dy;w=ww;h=hh;ga=alpha;
    for(row=0;row<hh;row=row+1) for(col=0;col<ww;col=col+1)
        expected[(dy+row)*256+dx+col]=blend(foreground(s+row*stride+col*4),memory[(dy+row)*256+dx+col],alpha);
    began=cycle;start=1;
    @(negedge clk);start=0;
    while(busy) begin @(negedge clk);if(cycle-began>25000)$fatal(1,"command timeout");end
    elapsed=cycle-began;
    if(!done || error_code!==want_error)$fatal(1,"error=%h expected=%h",error_code,want_error);
    // Error read commands leave the destination intact; resync the reference.
    for(row=0;row<FRAME_WORDS;row=row+1) if(want_error!=0) expected[row]=memory[row];
    if(!want_error) for(row=0;row<FRAME_WORDS;row=row+1)
        if(expected[row]!==memory[row])$fatal(1,"escaped/missing rectangle pixel %d",row);
end endtask
initial begin
    for(i=0;i<FRAME_WORDS;i=i+1) begin memory[i]=32'ha52b4671^(i*32'h010307);expected[i]=memory[i];end
    repeat(3)@(negedge clk);rst_n=1;
    command(TILE,2560,4,1,16,16,225,0);cold_cycles=elapsed;
    reads_before=source_reads;bg_before=bg_reads;
    command(TILE,2560,24,2,16,16,225,0);warm_cycles=elapsed;
    if(CACHE && source_reads!=reads_before)$fatal(1,"warm full tile fetched source");
    if(bg_reads-bg_before!=16)$fatal(1,"warm tile skipped background");
    if(CACHE && dut.sprite_cache_valid!==16'hffff)$fatal(1,"tile rows not all cached");
    reads_before=source_reads;
    command(TILE+3*2560+16,2560,252,20,4,5,0,0);
    command(TILE+9*2560+32,2560,0,30,8,7,255,0);
    if(CACHE && source_reads!=reads_before)$fatal(1,"clipped tile fetched cached source");
    // Non-tile and wrong-stride commands must always fall back to DDR.
    reads_before=source_reads;
    command(TILE+64,2560,0,2,16,1,127,0);
    command(TILE,128,0,3,16,1,225,0);
    if(source_reads-reads_before!=2)$fatal(1,"cache matched wrong source/stride");
    // Source 4KiB split; 32-beat, 1-beat and consecutive result bursts.
    command(32'h01400ff0,640,124,3,132,2,173,0);
    command(32'h01400000,512,0,0,128,2,1,0);
    command(TILE,2560,0,0,4,1,254,0);
    // Platform reset invalidates every row, including after a partial fill.
    @(negedge clk);rst_n=0;repeat(3)@(negedge clk);rst_n=1;
    inject_source_error=1;
    command(TILE,2560,0,0,16,1,225,32'h22);
    if(CACHE && dut.sprite_cache_valid!=0)$fatal(1,"failed read cached a row");
    inject_source_error=0;reads_before=source_reads;
    command(TILE,2560,0,0,4,1,225,0);
    command(TILE,2560,0,0,16,1,225,0);
    if(source_reads-reads_before!=2)$fatal(1,"partial row falsely marked valid");
    inject_bg_error=1;
    command(TILE,2560,0,0,16,1,225,32'h22);inject_bg_error=0;
    command(TILE,2560,0,0,16,1,225,0);
    inject_write_error=1;
    command(TILE,2560,0,0,16,1,225,32'h23);inject_write_error=0;
    $display("PASS Alpha stream=%0d cache=%0d: cold=%0d warm=%0d cycles; source_reads=%0d background_reads=%0d exact_pixels=%0d; stalls/pages/clipping/errors/reset",STREAM,CACHE,cold_cycles,warm_cycles,source_reads,bg_reads,checked);
    $finish;
end
initial begin #10000000;$fatal(1,"global timeout");end
endmodule
