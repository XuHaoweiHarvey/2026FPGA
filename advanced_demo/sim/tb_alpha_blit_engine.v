`timescale 1ns/1ps
module tb_alpha_blit_engine;
parameter INJECT_RRESP=0,INJECT_BRESP=0,MALFORMED_RLAST=0,TIMEOUT_READ=0;
parameter STREAM_ENABLE=0, OVERLAP=0;
localparam [31:0] SRC=32'h00100000,BACK=32'h00200000;
reg clk=0,rst_n=0,start=0;
reg [31:0] src_addr=SRC,src_stride=64,back_base=BACK;
reg [7:0] global_alpha=173;
reg [31:0] x=0,y=0,width=8,height=2;
wire busy,done;wire [31:0] error_code,command_count;
wire [31:0] araddr,awaddr;wire [7:0] arlen,awlen;
wire arvalid,rready,awvalid,wlast,wvalid,bready;
wire [127:0] wdata;wire [15:0] wstrb;
reg arready=1,rvalid=0,rlast=0;reg [127:0] rdata=0;reg [3:0] rid=0;
reg [1:0] rresp=0;reg awready=1,wready=1,bvalid=0;
reg stall_read=0;
reg [3:0] bid=0;reg [1:0] bresp=0;
reg read_active=0,read_background=0,write_active=0;
reg [31:0] read_addr;reg [7:0] read_len;reg [8:0] read_index;
reg [127:0] source_mem[0:31],dest_mem[0:31],saved_source[0:31];
reg [127:0] saved_dest[0:31];
integer i,p,c,cycles,idx,srcv,dstv,alpha,expected;
reg [31:0] a_pixel,b_pixel,out_pixel;
reg [31:0] shadow_src=SRC,shadow_stride=64,shadow_back=BACK;
reg [7:0] shadow_alpha=173;
reg [31:0] shadow_x=4,shadow_y=1,shadow_width=8,shadow_height=2;
always #5 clk=~clk;

alpha_blit_engine #(.FRAME_WIDTH(32),.FRAME_HEIGHT(8),.FRAME_STRIDE(128),
    .MAX_BURST_BEATS(2),.WATCHDOG_BITS(12),.STREAM_ENABLE(STREAM_ENABLE),.OVERLAP_ENABLE(OVERLAP)) dut(
    .clk(clk),.rst_n(rst_n),.enabled(1'b1),.start(start),
    .src_addr(src_addr),.src_stride(src_stride),.back_base(back_base),
    .global_alpha(global_alpha),.dst_x(x),.dst_y(y),.width(width),.height(height),
    .busy(busy),.done(done),.error_code(error_code),.command_count(command_count),
    .araddr(araddr),.arlen(arlen),.arvalid(arvalid),.arready(arready),
    .rdata(rdata),.rid(rid),.rresp(rresp),.rlast(rlast),.rvalid(rvalid),.rready(rready),
    .awaddr(awaddr),.awlen(awlen),.awvalid(awvalid),.awready(awready),
    .wdata(wdata),.wstrb(wstrb),.wlast(wlast),.wvalid(wvalid),.wready(wready),
    .bid(bid),.bresp(bresp),.bvalid(bvalid),.bready(bready));

always @* begin
    rdata=0;rlast=0;
    if(read_active) begin
        idx=(read_addr-(read_background?BACK:SRC))/16+read_index;
        rdata=read_background?dest_mem[idx]:source_mem[idx];
        if(MALFORMED_RLAST==1) rlast=(read_index==0);
        else if(MALFORMED_RLAST==2) rlast=(read_index==read_len+1'b1);
        else rlast=(read_index==read_len);
    end
end

always @(posedge clk) if(rst_n) begin
    if(arvalid&&arready) begin
        if(read_active)$fatal(1,"unexpected overlapping alpha reads");
        read_active<=1;read_background<=(araddr>=BACK);
        read_addr<=araddr;read_len<=arlen;read_index<=0;
    end
    if(read_active&&!rvalid&&!stall_read) rvalid<=1;
    if(read_active&&rvalid&&rready) begin
        if(read_index==(MALFORMED_RLAST==1?0:read_len+(MALFORMED_RLAST==2?1:0))) begin read_active<=0;rvalid<=0;end
        else read_index<=read_index+1'b1;
    end
    if(awvalid&&awready) begin
        if(write_active)$fatal(1,"overlapping writes");
        write_active<=1;write_addr<=awaddr;write_len<=awlen;write_index<=0;
        aw_count<=aw_count+1;
    end
    if(wvalid&&wready) begin
        if(!write_active)$fatal(1,"W without AW");
        dest_mem[write_addr/16+write_index]<=wdata;
        if(wlast!==(write_index==write_len))$fatal(1,"W LAST mismatch");
        if(wlast) begin write_active<=0;b_delay<=2;end
        else write_index<=write_index+1'b1;
    end
    if(b_delay!=0) begin b_delay<=b_delay-1'b1;if(b_delay==1)begin bvalid<=1;bresp<=INJECT_BRESP?2'b10:2'b00;end end
    if(bvalid&&bready) begin bvalid<=0;write_response_seen<=1;end
end
reg [31:0] write_addr;reg [7:0] write_len;reg [8:0] write_index;
reg [2:0] b_delay=0;reg write_response_seen=0;
integer aw_count=0;

function [31:0] blend;
input [31:0] fg,bg;input [7:0] ga;
integer a,rr,gg,bb;
begin
    a=(((fg>>24)&255)*ga+127)/255;
    rr=((((fg>>16)&255)*a+((bg>>16)&255)*(255-a)+127)/255);
    gg=((((fg>>8)&255)*a+((bg>>8)&255)*(255-a)+127)/255);
    bb=(((fg&255)*a+(bg&255)*(255-a)+127)/255);
    blend=(bg&32'hff000000)|(rr<<16)|(gg<<8)|bb;
end
endfunction

initial begin
    for(i=0;i<32;i=i+1) begin
        source_mem[i]=0;dest_mem[i]=0;
        for(p=0;p<4;p=p+1) begin
            source_mem[i][p*32+24+:8]=(i*47+p*59)&255;
            source_mem[i][p*32+16+:8]=(i*13+p*37)&255;
            source_mem[i][p*32+8+:8]=(i*29+p*17)&255;
            source_mem[i][p*32+:8]=(i*7+p*11)&255;
            dest_mem[i][p*32+24+:8]=(i*3+p)&255;
            dest_mem[i][p*32+16+:8]=(i*31+p*23)&255;
            dest_mem[i][p*32+8+:8]=(i*19+p*41)&255;
            dest_mem[i][p*32+:8]=(i*5+p*61)&255;
        end
        saved_source[i]=source_mem[i];saved_dest[i]=dest_mem[i];
    end
    repeat(3)@(negedge clk);rst_n=1;
    rresp=INJECT_RRESP?2'b10:2'b00;
    @(negedge clk);start=1;
    @(negedge clk);start=0;
    repeat(2) @(negedge clk);
    // Mutate the live command bus after its acceptance; all child inputs must
    // continue to use the accepted snapshot.
    src_addr=0;src_stride=0;back_base=0;global_alpha=0;
    x=0;y=0;width=0;height=0;
    if(TIMEOUT_READ) begin stall_read=1;repeat(4200)@(negedge clk);stall_read=0;end
    cycles=0;
    while(!done||busy) begin
        @(negedge clk);cycles=cycles+1;
        if(cycles==20 && done)$fatal(1,"Done asserted before final B response");
        if(cycles>3000)$fatal(1,"alpha BLIT watchdog state=%0d",dut.state);
    end
    if(command_count!=1)$fatal(1,"Accepted command count mismatch");
    if(INJECT_RRESP || MALFORMED_RLAST!=0 || TIMEOUT_READ) begin
        if(error_code!==(INJECT_RRESP?32'h22:MALFORMED_RLAST!=0?32'h25:32'h24) ||
           aw_count!=0 || write_response_seen)
            $fatal(1,"Read drain failure error=%h aw=%0d",error_code,aw_count);
        $display("PASS ALPHA BLIT drain: error=%h rlast_mode=%0d timeout=%0d",error_code,MALFORMED_RLAST,TIMEOUT_READ);
        $finish;
    end
    if(error_code!==(INJECT_BRESP?32'h23:32'h0) || !write_response_seen)
        $fatal(1,"Unexpected final alpha command state error=%h",error_code);
    if(!INJECT_BRESP) for(i=0;i<32;i=i+1) begin
        if(source_mem[i]!==saved_source[i])$fatal(1,"source memory changed");
        if(i==0 || i==1 || i==8 || i==9) begin
            for(p=0;p<4;p=p+1) begin
                idx=i>=8?i-4:i;
                a_pixel=source_mem[idx][p*32+:32];
                b_pixel=saved_dest[i][p*32+:32];
                out_pixel=dest_mem[i][p*32+:32];
                expected=blend(a_pixel,b_pixel,173);
                if(out_pixel!==expected[31:0])
                    $fatal(1,"alpha write mismatch beat=%0d lane=%0d got=%h want=%h",i,p,out_pixel,expected);
            end
        end else if(dest_mem[i]!==saved_dest[i])
            $fatal(1,"write escaped target rectangle beat=%0d old=%h new=%h awaddr=%h latchedxy=%d,%d",i,saved_dest[i],dest_mem[i],write_addr,dut.x,dut.y);
    end
    $display("PASS ALPHA BLIT: snapshot, source preservation, exact pixels, B completion, bresp=%0d",INJECT_BRESP);
    $finish;
end
initial begin #1000000;$fatal(1,"Alpha BLIT global watchdog");end
endmodule
