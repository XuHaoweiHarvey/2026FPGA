`timescale 1ns/1ps
// Exact reference pixels plus DDR stalls, clipped cache hits, page splitting,
// cache read-error validity, reset lifetime and measured command cycle counts.
module tb_lunaria_beam;
parameter BEAM=1, OVERLAP=0;
localparam TILE=32'h01384700, STRIDE=1024, FRAME_WORDS=256*48;
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
integer i,p,addr_index,elapsed,cold_cycles,warm_cycles,trim_cycles,reads_before,bg_before;
integer trial;
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
graphics_engine #(.FRAME_WIDTH(256),.FRAME_HEIGHT(48),.FRAME_STRIDE(STRIDE),
    .MAX_BURST_BEATS(32),.ALPHA_ENABLE(1),.ALPHA_STREAM_ENABLE(1),
    .ALPHA_SPRITE_CACHE_ENABLE(1),.ALPHA_WIDE_CACHE_ENABLE(1),.BEAM_ENABLE(BEAM),
    .ALPHA_OVERLAP_ENABLE(OVERLAP),.WATCHDOG_BITS(12)) dut(
    .clk(clk),.rst_n(rst_n),.enabled(1'b1),.start(start),.op(32'd4),
    .src_addr(src),.src_stride(ss),.back_base(back),.color({ga,24'hff78d6}),
    .src_range_valid(1'b0),.x(x),.y(y),.width(w),.height(h),.busy(busy),.done(done),
    .error_code(error_code),.command_count(count),.accept(),
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
            if(araddr<back || araddr+(arlen+1)*16>back+FRAME_WORDS*4) $fatal(1,"beam read escaped Back");
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
function [31:0] beam_reference;
input integer distance;input [7:0] alpha;
integer q,a;reg [23:0] rgb;
begin
    q=(distance<0?-distance:distance)/4096;a=0;rgb=24'hff78d6;
    if(alpha<128) begin if(q<8)a=255-q*32;end
    else if(q<32) begin
        if(q<8)a=255;else if(q<16)a=255-(q-8)*8;
        else if(q<24)a=191-(q-16)*16;else a=63-(q-24)*8;
        if(q<6)rgb=24'hfff4ff;
    end
    beam_reference=(a<<24)|rgb;
end endfunction

task command;
input integer nx,ny,distance,dx,dy,ww,hh;
input [7:0] alpha;
input [31:0] want_error;
integer row,col,began,before_reads,before_writes;
begin
    @(negedge clk);src={ny[15:0],nx[15:0]};ss=distance;x=dx;y=dy;w=ww;h=hh;ga=alpha;
    if(!want_error) for(row=0;row<hh;row=row+1) for(col=0;col<ww;col=col+1)
        expected[(dy+row)*256+dx+col]=blend(beam_reference(distance+col*nx+row*ny,alpha),memory[(dy+row)*256+dx+col],alpha);
    began=cycle;before_reads=bg_reads;before_writes=writes;start=1;
    @(negedge clk);start=0;
    // Active commands must use latched inputs even if APB registers change.
    src=0;ss=0;x=9999;y=9999;w=0;h=0;ga=0;
    while(busy) begin @(negedge clk);if(cycle-began>150000)$fatal(1,"command timeout");end
    elapsed=cycle-began;
    if(!done || error_code!==want_error)$fatal(1,"error=%h expected=%h",error_code,want_error);
    if(source_reads)$fatal(1,"beam fetched a texture");
    if(want_error==32'h21 || want_error==32'h26 || alpha==0 || distance==10000000)
        if(bg_reads!=before_reads || writes!=before_writes)$fatal(1,"invalid/invisible beam issued DMA");
    for(row=0;row<FRAME_WORDS;row=row+1) if(want_error!=0) expected[row]=memory[row];
    if(!want_error) for(row=0;row<FRAME_WORDS;row=row+1)
        if(expected[row]!==memory[row])$fatal(1,"escaped/missing beam pixel %d",row);
end endtask
initial begin
    for(i=0;i<FRAME_WORDS;i=i+1) begin memory[i]=32'ha52b4671^(i*32'h010307);expected[i]=memory[i];end
    repeat(3)@(negedge clk);rst_n=1;
    if(!BEAM) begin
        command(16384,0,-80*16384,0,0,256,48,245,32'h26);
    end else begin
        command(16384,0,-80*16384,0,0,256,48,245,0);cold_cycles=elapsed;
        command(0,16384,-12*16384,0,0,256,48,245,0);warm_cycles=elapsed;
        command(11585,-11585,-30*16384,0,0,256,48,245,0);
        command(-11585,-11585,130*16384,0,0,256,48,245,0);
        command(16384,-201,-10*16384,4,3,252,40,70,0);
        command(201,16383,-10*16384,0,0,256,48,70,0);
        for(trial=0;trial<24;trial=trial+1)
            command((trial*997)%32769-16384,(trial*1583+8192)%32769-16384,
                    (trial-12)*8192,0,0,64,16,trial%2?245:70,0);
        command(16384,0,-4*16384,0,0,256,48,0,0);
        command(16384,0,10000000,0,0,256,48,245,0);
        command(16384,0,0,0,0,0,1,245,32'h21);
        command(16384,0,0,2,0,16,1,245,32'h21);
        command(0,0,0,0,0,16,1,245,32'h21);
        command(16385,0,0,0,0,16,1,245,32'h21);
        command(16384,0,0,252,0,8,1,245,32'h21);
        // Failed background read must not write partial results.
        inject_bg_error=1;
        command(0,16384,0,0,0,128,1,245,32'h22);
        inject_bg_error=0;
        inject_write_error=1;
        // Successful pixels before B error still match the reference.
        for(i=0;i<128;i=i+1) expected[i]=blend(beam_reference(0,245),memory[i],245);
        command(0,16384,0,0,0,128,1,245,32'h23);
        inject_write_error=0;
        @(negedge clk);rst_n=0;repeat(3)@(negedge clk);rst_n=1;
        command(0,-16384,12*16384,0,0,256,48,245,0);
    end
    $display("PASS BEAM=%0d: vertical=%0d horizontal=%0d cycles; exact pixels=%0d, source_reads=%0d; axes/diagonals/stalls/pages/errors/reset",BEAM,cold_cycles,warm_cycles,checked,source_reads);
    $finish;
end
initial begin #20000000;$fatal(1,"simulation timeout");end
endmodule
