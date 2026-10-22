`timescale 1ns/1ps
// Full 640x480 asset copy through the production guard/dispatcher/BLIT path.
// The shared AXI memory model deliberately stalls all five AXI channels.
module tb_m2_full_asset_blit;
localparam IMAGE_WORDS=640*480;
reg clk=0,rst_n=0,enabled=0,start=0,asset_ready=0;
always #5 clk=~clk;
reg [31:0] src_addr=32'h01000000;
wire source_valid,accept,busy,done;
wire [31:0] error_code,command_count,araddr,awaddr_relative;
wire [31:0] awaddr=32'h00800000+awaddr_relative;
wire [7:0] arlen,awlen;
wire arvalid,arready,rvalid,rready,rlast,awvalid,awready,wvalid,wready,wlast,bvalid,bready;
wire [127:0] rdata,wdata;
wire [15:0] wstrb;
wire [3:0] rid,bid;
wire [1:0] rresp,bresp;
wire [31:0] ar_count,r_count,aw_count,w_count,b_count;
wire memory_idle;
integer image,i,row,col,cycles;
reg [31:0] want;

blit_source_guard guard (
    .clk(clk),.rst_n(rst_n),.command_accept(accept),
    .front_base(32'd0),.back_base(32'h00800000),
    .src_addr(src_addr),.src_stride(32'd2560),.width(32'd640),.height(32'd480),
    .op(32'd1),.asset_ready(asset_ready),.src_range_valid(source_valid));
graphics_engine #(.WATCHDOG_BITS(27)) engine (
    .clk(clk),.rst_n(rst_n),.enabled(enabled),.start(start),
    .op(32'd1),.x(32'd640),.y(32'd300),.width(32'd640),.height(32'd480),
    .color(32'd0),.src_addr(src_addr),.src_stride(32'd2560),
    .src_range_valid(source_valid),.accept(accept),.busy(busy),.done(done),
    .error_code(error_code),.command_count(command_count),
    .araddr(araddr),.arlen(arlen),.arvalid(arvalid),.arready(arready),
    .rdata(rdata),.rid(rid),.rresp(rresp),.rlast(rlast),.rvalid(rvalid),.rready(rready),
    .awaddr(awaddr_relative),.awlen(awlen),.awvalid(awvalid),.awready(awready),
    .wdata(wdata),.wstrb(wstrb),.wlast(wlast),.wvalid(wvalid),.wready(wready),
    .bid(bid),.bresp(bresp),.bvalid(bvalid),.bready(bready));
blit_test_memory #(.FRAME_WIDTH(1920),.FRAME_HEIGHT(1080),
    .SOURCE_WORDS(3*IMAGE_WORDS)) memory (
    .clk(clk),.rst_n(rst_n),
    .stall_ar(1'b0),.stall_r(1'b0),.stall_aw(1'b0),.stall_w(1'b0),.stall_b(1'b0),
    .inject_rresp(1'b0),.inject_rid(1'b0),.inject_bresp(1'b0),.inject_bid(1'b0),
    .early_rlast(1'b0),.missing_rlast(1'b0),
    .araddr(araddr),.awaddr(awaddr),.arlen(arlen),.awlen(awlen),
    .arvalid(arvalid),.awvalid(awvalid),.arready(arready),.awready(awready),
    .rdata(rdata),.rid(rid),.rresp(rresp),.rlast(rlast),.rvalid(rvalid),.rready(rready),
    .wdata(wdata),.wstrb(wstrb),.wlast(wlast),.wvalid(wvalid),.wready(wready),
    .bid(bid),.bresp(bresp),.bvalid(bvalid),.bready(bready),
    .ar_count(ar_count),.r_count(r_count),.aw_count(aw_count),
    .w_count(w_count),.b_count(b_count),.idle(memory_idle));

function [31:0] pixel;
input integer img,index;
integer xx,yy,r,g,b,band;
begin
    xx=index%640;yy=index/640;
    if(img==0) begin
        r=(xx+(yy>>1))&255;g=(yy+(xx>>2))&255;
        b=(((xx+yy)>>5)&1) ? 'he0 : 'h28;
    end else if(img==1) begin
        band=((xx>>5)^(yy>>5))&1;
        r=band ? 'hf0 : 'h20;g=((xx>>2)^(yy>>1))&255;
        b=band ? 'h30 : 'he8;
    end else begin
        band=((xx+(yy<<1))>>4)&7;
        r=band*29+28;g=((xx^yy)>>1)&255;
        b=255-(((yy*3+xx)>>3)&255);
    end
    pixel=(r<<16)|(g<<8)|b;
end
endfunction
task submit;
begin
    @(negedge clk);start=1;
    @(negedge clk);start=0;
end
endtask
task await_done;
input [31:0] expected_error;
begin
    cycles=0;
    while(!done) begin
        @(negedge clk);cycles=cycles+1;
        if(cycles>5000000) $fatal(1,"M2 full BLIT timed out");
    end
    if(busy || !memory_idle || error_code!==expected_error || aw_count!=b_count)
        $fatal(1,"M2 full BLIT completion/AXI drain failed error=%h",error_code);
end
endtask
initial begin
    repeat(4) @(negedge clk);rst_n=1;enabled=1;
    for(image=0;image<3;image=image+1)
        for(i=0;i<IMAGE_WORDS;i=i+1)
            memory.source_mem[image*IMAGE_WORDS+i]=pixel(image,i);
    for(i=0;i<1920*1080;i=i+1) memory.target_mem[i]=32'h00556677;
    submit();await_done(32'h21);
    if(ar_count || aw_count) $fatal(1,"Unsealed asset issued AXI request");
    asset_ready=1;
    for(image=0;image<3;image=image+1) begin
        src_addr=32'h01000000+image*32'h0012c000;
        submit();await_done(0);
        if(r_count!=(image+1)*IMAGE_WORDS/4 || w_count!=r_count)
            $fatal(1,"Wrong full-image AXI beat count");
        for(row=0;row<480;row=row+1)
            for(col=0;col<640;col=col+1) begin
                want=pixel(image,row*640+col);
                if(memory.target_mem[(300+row)*1920+640+col]!==want)
                    $fatal(1,"Image %0d pixel (%0d,%0d) mismatch",image,col,row);
            end
        if(memory.target_mem[0]!==32'h00556677 ||
           memory.target_mem[300*1920+639]!==32'h00556677 ||
           memory.target_mem[780*1920+640]!==32'h00556677)
            $fatal(1,"BLIT overwrote pixels outside the 640x480 viewport");
    end
    if(command_count!=4) $fatal(1,"Guard rejection/three images count mismatch");
    $display("PASS M2 full asset BLIT: pre-READY rejection without AXI, three 640x480 images, 230400 read/write beats, stalled channels, final B drained, viewport exact");
    $finish;
end
endmodule
