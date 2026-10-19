`timescale 1ns/1ps

// Small AXI128 memory service for this unit test, not FPGA design logic.
// Separate, non-overlapping windows avoid allocating the address-space holes.
module blit_test_memory #(
    parameter FRAME_WIDTH = 64, FRAME_HEIGHT = 48,
    parameter SOURCE_WORDS = 32768,
    parameter ALLOW_PARTIAL_STROBES = 0,
    parameter [31:0] SOURCE_BASE = 32'h01000000,
    parameter [31:0] BACK_BASE = 32'h00800000
)(
    input wire clk, rst_n,
    input wire stall_ar, stall_r, stall_aw, stall_w, stall_b,
    input wire inject_rresp, inject_rid, inject_bresp, inject_bid,
    input wire early_rlast, missing_rlast,
    input wire [31:0] araddr, awaddr,
    input wire [7:0] arlen, awlen,
    input wire arvalid, awvalid,
    output wire arready, awready,
    output reg [127:0] rdata,
    output reg [3:0] rid,
    output reg [1:0] rresp,
    output reg rlast, rvalid,
    input wire rready,
    input wire [127:0] wdata,
    input wire [15:0] wstrb,
    input wire wlast, wvalid,
    output wire wready,
    output reg [3:0] bid,
    output reg [1:0] bresp,
    output reg bvalid,
    input wire bready,
    output reg [31:0] ar_count, r_count, aw_count, w_count, b_count,
    output wire idle
);
localparam TARGET_WORDS = FRAME_WIDTH * FRAME_HEIGHT;
reg [31:0] source_mem [0:SOURCE_WORDS-1];
reg [31:0] target_mem [0:TARGET_WORDS-1];
reg read_active, write_active;
integer tick, read_index, write_index, read_left, write_left, b_delay;
integer lane;
reg [134:0] held_r;
reg held_r_stall;
reg [5:0] held_b;
reg held_b_stall;
reg corrupt_write;
initial corrupt_write=$test$plusargs("CORRUPT_WRITE");

assign idle = !read_active && !rvalid && !write_active && !bvalid && b_delay == 0;
assign arready = idle && !stall_ar && tick % 5 != 0;
assign awready = idle && !stall_aw && tick % 7 != 0;
assign wready = write_active && !stall_w && tick % 3 != 0;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        read_active <= 0; write_active <= 0;
        rvalid <= 0; rlast <= 0; rdata <= 0; rid <= 0; rresp <= 0;
        bvalid <= 0; bid <= 0; bresp <= 0; b_delay <= 0;
        tick <= 0; read_index <= 0; write_index <= 0;
        read_left <= 0; write_left <= 0;
        ar_count <= 0; r_count <= 0; aw_count <= 0; w_count <= 0; b_count <= 0;
        held_r_stall <= 0; held_b_stall <= 0; held_r <= 0; held_b <= 0;
    end else begin
        tick <= tick + 1;
        if (held_r_stall && (!rvalid || {rdata,rid,rresp,rlast} !== held_r))
            $fatal(1, "Memory model changed stalled R");
        if (held_b_stall && (!bvalid || {bid,bresp} !== held_b))
            $fatal(1, "Memory model changed stalled B");
        held_r_stall <= rvalid && !rready;
        held_r <= {rdata,rid,rresp,rlast};
        held_b_stall <= bvalid && !bready;
        held_b <= {bid,bresp};

        if (arvalid && arready) begin
            if (araddr[3:0] != 0 || arlen >= 32 ||
                {1'b0,araddr[11:0]} + (arlen+1)*16 > 4096 ||
                araddr < SOURCE_BASE ||
                {32'b0,araddr} + (arlen+1)*16 > {32'b0,SOURCE_BASE}+SOURCE_WORDS*4)
                $fatal(1, "Illegal AR burst addr=%h len=%d", araddr, arlen);
            if (!idle || awvalid)
                $fatal(1, "More than one transaction exposed");
            read_active <= 1; read_index <= (araddr-SOURCE_BASE)/4;
            read_left <= arlen+1; ar_count <= ar_count+1;
        end
        if (read_active && !rvalid && !stall_r && tick % 4 != 0) begin
            for (lane=0; lane<4; lane=lane+1)
                rdata[lane*32+:32] <= source_mem[read_index+lane];
            rid <= inject_rid ? 4'd1 : 4'd0;
            rresp <= inject_rresp ? 2'b10 : 2'b00;
            rlast <= early_rlast || (!missing_rlast && read_left == 1);
            rvalid <= 1;
        end
        if (rvalid && rready) begin
            rvalid <= 0; read_index <= read_index+4;
            read_left <= read_left-1; r_count <= r_count+1;
            if (read_left == 1) read_active <= 0;
        end
        if (awvalid && awready) begin
            if (awaddr[3:0] != 0 || awlen >= 32 ||
                {1'b0,awaddr[11:0]} + (awlen+1)*16 > 4096 ||
                awaddr < BACK_BASE ||
                {32'b0,awaddr} + (awlen+1)*16 > {32'b0,BACK_BASE}+TARGET_WORDS*4)
                $fatal(1, "Illegal AW burst addr=%h len=%d", awaddr, awlen);
            if (!idle || arvalid)
                $fatal(1, "AW before the prior read/write drained");
            write_active <= 1; write_index <= (awaddr-BACK_BASE)/4;
            write_left <= awlen+1; aw_count <= aw_count+1;
        end
        if (wvalid && wready) begin
            if (wlast !== (write_left == 1) ||
                (!ALLOW_PARTIAL_STROBES && wstrb !== 16'hffff))
                $fatal(1, "Wrong WLAST/WSTRB");
            for (lane=0; lane<16; lane=lane+1)
                if (wstrb[lane])
                    target_mem[write_index+lane/4][(lane%4)*8+:8] <= wdata[lane*8+:8];
            // Negative control: the runner verifies that the independent
            // pixel scoreboard actually rejects a deliberately wrong pixel.
            if(corrupt_write && wstrb[0])
                target_mem[write_index][7:0] <= wdata[7:0] ^ 8'h1;
            write_index <= write_index+4; write_left <= write_left-1;
            w_count <= w_count+1;
            if (write_left == 1) begin write_active <= 0; b_delay <= 9; end
        end
        if (b_delay != 0 && !stall_b) begin
            b_delay <= b_delay-1;
            if (b_delay == 1) begin
                bvalid <= 1; bid <= inject_bid ? 4'd1 : 4'd0;
                bresp <= inject_bresp ? 2'b10 : 2'b00;
            end
        end
        if (bvalid && bready) begin bvalid <= 0; b_count <= b_count+1; end
    end
end
endmodule

module tb_blit_engine;
parameter FRAME_WIDTH = 64, FRAME_HEIGHT = 48, EDGE_ONLY = 0;
parameter MAX_BURST_BEATS = 32, ADDRESS_EDGE_ONLY = 0;
parameter [31:0] SOURCE_BASE = 32'h01000000;
localparam SOURCE_WORDS = 32768, TARGET_WORDS = FRAME_WIDTH*FRAME_HEIGHT;
localparam [31:0] BACK_BASE = 32'h00800000;
localparam [31:0] ERR_PARAM=32'h21, ERR_READ=32'h22, ERR_WRITE=32'h23,
    ERR_TIMEOUT=32'h24, ERR_PROTOCOL=32'h25;
reg clk=0, rst_n=0, enabled=0, start=0;
always #5 clk=~clk;
reg [31:0] src_addr=0, src_stride=0, dst_x=0, dst_y=0, width=0, height=0;
wire busy, done;
wire [31:0] error_code, command_count;
wire [31:0] araddr, awaddr_relative;
wire [31:0] awaddr_physical = BACK_BASE + awaddr_relative;
wire [7:0] arlen, awlen;
wire arvalid, arready, rvalid, rready, rlast;
wire awvalid, awready, wvalid, wready, wlast, bvalid, bready;
wire [127:0] rdata, wdata;
wire [15:0] wstrb;
wire [3:0] rid,bid;
wire [1:0] rresp,bresp;
reg stall_ar=0,stall_r=0,stall_aw=0,stall_w=0,stall_b=0;
reg inject_rresp=0,inject_rid=0,inject_bresp=0,inject_bid=0;
reg early_rlast=0,missing_rlast=0;
wire [31:0] ar_count,r_count,aw_count,w_count,b_count;
wire memory_idle;
reg [31:0] saved_source [0:SOURCE_WORDS-1];
reg [31:0] expected_target [0:TARGET_WORDS-1];
integer case_count=0;

blit_engine #(.FRAME_WIDTH(FRAME_WIDTH), .FRAME_HEIGHT(FRAME_HEIGHT),
    .FRAME_STRIDE(FRAME_WIDTH*4), .MAX_BURST_BEATS(MAX_BURST_BEATS),
    .WATCHDOG_BITS(9)) dut (
    .clk(clk),.rst_n(rst_n),.enabled(enabled),.start(start),
    .src_addr(src_addr),.src_stride(src_stride),.dst_x(dst_x),.dst_y(dst_y),
    .width(width),.height(height),.busy(busy),.done(done),
    .error_code(error_code),.command_count(command_count),
    .araddr(araddr),.arlen(arlen),.arvalid(arvalid),.arready(arready),
    .rdata(rdata),.rid(rid),.rresp(rresp),.rlast(rlast),.rvalid(rvalid),.rready(rready),
    .awaddr(awaddr_relative),.awlen(awlen),.awvalid(awvalid),.awready(awready),
    .wdata(wdata),.wstrb(wstrb),.wlast(wlast),.wvalid(wvalid),.wready(wready),
    .bid(bid),.bresp(bresp),.bvalid(bvalid),.bready(bready)
);
blit_test_memory #(.FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT),
    .SOURCE_WORDS(SOURCE_WORDS),.SOURCE_BASE(SOURCE_BASE),.BACK_BASE(BACK_BASE)) memory (
    .clk(clk),.rst_n(rst_n),
    .stall_ar(stall_ar),.stall_r(stall_r),.stall_aw(stall_aw),.stall_w(stall_w),.stall_b(stall_b),
    .inject_rresp(inject_rresp),.inject_rid(inject_rid),
    .inject_bresp(inject_bresp),.inject_bid(inject_bid),
    .early_rlast(early_rlast),.missing_rlast(missing_rlast),
    .araddr(araddr),.arlen(arlen),.arvalid(arvalid),.arready(arready),
    .rdata(rdata),.rid(rid),.rresp(rresp),.rlast(rlast),.rvalid(rvalid),.rready(rready),
    .awaddr(awaddr_physical),.awlen(awlen),.awvalid(awvalid),.awready(awready),
    .wdata(wdata),.wstrb(wstrb),.wlast(wlast),.wvalid(wvalid),.wready(wready),
    .bid(bid),.bresp(bresp),.bvalid(bvalid),.bready(bready),
    .ar_count(ar_count),.r_count(r_count),.aw_count(aw_count),.w_count(w_count),.b_count(b_count),
    .idle(memory_idle)
);

reg held_ar_stall=0,held_aw_stall=0,held_w_stall=0;
reg [39:0] held_ar=0,held_aw=0;
reg [144:0] held_w=0;
always @(posedge clk) begin
    if (!rst_n) begin held_ar_stall<=0;held_aw_stall<=0;held_w_stall<=0;end
    else begin
        if (held_ar_stall && (!arvalid || {araddr,arlen} !== held_ar))
            $fatal(1,"AR changed or VALID withdrawn during stall");
        if (held_aw_stall && (!awvalid || {awaddr_relative,awlen} !== held_aw))
            $fatal(1,"AW changed or VALID withdrawn during stall");
        if (held_w_stall && (!wvalid || {wdata,wstrb,wlast} !== held_w))
            $fatal(1,"W changed or VALID withdrawn during stall");
        held_ar_stall<=arvalid&&!arready;held_ar<={araddr,arlen};
        held_aw_stall<=awvalid&&!awready;held_aw<={awaddr_relative,awlen};
        held_w_stall<=wvalid&&!wready;held_w<={wdata,wstrb,wlast};
        if (done && (!memory_idle || busy || aw_count!=b_count) && error_code==0)
            $fatal(1,"Successful DONE before all transactions drained");
        if ((arvalid && arlen>=MAX_BURST_BEATS) || (awvalid && awlen>=MAX_BURST_BEATS))
            $fatal(1,"Configured burst cap exceeded");
    end
end

task announce;
input [8*100-1:0] name;
begin case_count=case_count+1;$display("CASE %0d: %0s",case_count,name);end
endtask

task initialize_memory;
input integer checker;
integer i,xx,yy;
begin
    if (!memory_idle || busy) $fatal(1,"Test changed memory while active");
    for(i=0;i<SOURCE_WORDS;i=i+1) begin
        saved_source[i]=32'ha5000000 ^ (i*32'h010203);
        if(checker && i<1024) begin
            xx=i%32;yy=i/32;
            saved_source[i]=((xx/4+yy/4)%2) ? 32'h00eeeeee : 32'h002040c0;
        end
        memory.source_mem[i]=saved_source[i];
    end
    for(i=0;i<TARGET_WORDS;i=i+1) begin
        expected_target[i]=checker ? 32'h00102030 : (32'h00556677 ^ i);
        memory.target_mem[i]=expected_target[i];
    end
end
endtask

task check_memory;
integer i;
begin
    for(i=0;i<TARGET_WORDS;i=i+1)
        if(memory.target_mem[i]!==expected_target[i])
            $fatal(1,"Target pixel (%0d,%0d): got %h expected %h",
                i%FRAME_WIDTH,i/FRAME_WIDTH,memory.target_mem[i],expected_target[i]);
    for(i=0;i<SOURCE_WORDS;i=i+1)
        if(memory.source_mem[i]!==saved_source[i]) $fatal(1,"Source changed at %0d",i);
end
endtask

// The expected result comes from pre-command source pixels and coordinates,
// not DUT counters, addresses, cache contents, or returned AXI read data.
task expect_copy;
input [31:0] ss, stride;
input integer xx,yy,ww,hh;
integer row,col;
begin
    for(row=0;row<hh;row=row+1)
        for(col=0;col<ww;col=col+1)
            expected_target[(yy+row)*FRAME_WIDTH+xx+col]=
                saved_source[(ss-SOURCE_BASE)/4+row*(stride/4)+col];
end
endtask

task submit;
input [31:0] ss,stride,xx,yy,ww,hh;
begin
    @(negedge clk);
    src_addr=ss;src_stride=stride;dst_x=xx;dst_y=yy;width=ww;height=hh;start=1;
    @(negedge clk);start=0;
end
endtask

task await_done;
input [31:0] wanted_error;
integer cycles;
begin
    cycles=0;
    while(!done) begin
        @(negedge clk);cycles=cycles+1;
        if(cycles>100000) $fatal(1,"Command did not complete, error=%h",error_code);
    end
    if(busy || error_code!==wanted_error || !memory_idle)
        $fatal(1,"Wrong completion: busy=%b error=%h wanted=%h idle=%b",
            busy,error_code,wanted_error,memory_idle);
end
endtask

task copy_case;
input [8*100-1:0] name;
input [31:0] ss,stride;
input integer xx,yy,ww,hh;
integer old_ar,old_r,old_aw,old_w,old_b,old_cmd;
begin
    announce(name);
    old_ar=ar_count;old_r=r_count;old_aw=aw_count;old_w=w_count;old_b=b_count;old_cmd=command_count;
    expect_copy(ss,stride,xx,yy,ww,hh);
    submit(ss,stride,xx,yy,ww,hh);
    // Mutating every external parameter must not alter the active copy.
    src_addr=32'hbad;src_stride=0;dst_x=32'hffffffff;dst_y=0;width=0;height=0;
    await_done(0);
    if(command_count!=old_cmd+1 || r_count-old_r!=ww*hh/4 || w_count-old_w!=ww*hh/4 ||
        ar_count-old_ar!=aw_count-old_aw || aw_count-old_aw!=b_count-old_b)
        $fatal(1,"Copy command/beat/response count mismatch");
    check_memory();
    $display("  PASS pixels=%0d, read/write beats=%0d, bursts=%0d",ww*hh,ww*hh/4,ar_count-old_ar);
end
endtask

task invalid_case;
input [8*100-1:0] name;
input [31:0] ss,stride,xx,yy,ww,hh;
integer old_ar,old_aw,old_cmd;
begin
    announce(name);old_ar=ar_count;old_aw=aw_count;old_cmd=command_count;
    submit(ss,stride,xx,yy,ww,hh);await_done(ERR_PARAM);
    if(ar_count!=old_ar || aw_count!=old_aw || command_count!=old_cmd+1)
        $fatal(1,"Invalid command touched AXI or was not counted");
    check_memory();
end
endtask

task timeout_case;
input integer channel; // 0=AR, 1=R, 2=AW, 3=W, 4=B
integer old_ar,old_aw,old_w,old_b;
begin
    announce("timeout, hold transaction, restore service, drain");
    $display("  stalled channel=%0d (AR/R/AW/W/B=0/1/2/3/4)",channel);
    initialize_memory(0);
    old_ar=ar_count;old_aw=aw_count;old_w=w_count;old_b=b_count;
    case(channel)
        0:stall_ar=1;1:stall_r=1;2:stall_aw=1;3:stall_w=1;4:stall_b=1;
    endcase
    submit(SOURCE_BASE,128,8,5,32,2);
    case(channel)
        0:wait(arvalid);1:wait(rready);2:wait(awvalid);3:wait(wvalid);4:wait(bready);
    endcase
    repeat(580)@(negedge clk);
    if(!busy || done || error_code!=ERR_TIMEOUT) $fatal(1,"Timeout did not retain ownership");
    case(channel)
        0:if(!arvalid)$fatal(1,"AR withdrawn");
        2:if(!awvalid)$fatal(1,"AW withdrawn");
        3:if(!wvalid)$fatal(1,"W withdrawn");
    endcase
    stall_ar=0;stall_r=0;stall_aw=0;stall_w=0;stall_b=0;
    await_done(ERR_TIMEOUT);
    if(ar_count!=old_ar+1) $fatal(1,"Timeout launched another read");
    if(channel<2) begin
        if(aw_count!=old_aw || w_count!=old_w || b_count!=old_b)
            $fatal(1,"Timed-out read was written");
    end else begin
        // Once AW is exposed we must complete that burst, even after timeout.
        expect_copy(SOURCE_BASE,128,8,5,32,1);
        if(aw_count!=old_aw+1 || w_count!=old_w+8 || b_count!=old_b+1)
            $fatal(1,"Timed-out write did not drain exactly once");
    end
    check_memory();
end
endtask

task response_error_case;
input integer kind; // 0=RRESP,1=RID,2=BRESP,3=BID
integer old_ar,old_aw,old_b;
begin
    announce("response error: drain current burst, stop before next");
    $display("  error kind=%0d (RRESP/RID/BRESP/BID=0/1/2/3)",kind);
    initialize_memory(0);old_ar=ar_count;old_aw=aw_count;old_b=b_count;
    case(kind)
        0:inject_rresp=1;1:inject_rid=1;2:inject_bresp=1;3:inject_bid=1;
    endcase
    submit(SOURCE_BASE,128,8,5,32,2);
    if(kind<2) begin
        // Only one bad read beat. Later OKAY beats must not erase the error.
        wait(rvalid && rready);@(negedge clk);
        inject_rresp=0;inject_rid=0;
    end
    await_done(kind<2 ? ERR_READ : ERR_WRITE);
    inject_rresp=0;inject_rid=0;inject_bresp=0;inject_bid=0;
    if(ar_count!=old_ar+1) $fatal(1,"Read continued after error");
    if(kind<2) begin
        if(aw_count!=old_aw || b_count!=old_b)$fatal(1,"Bad read segment was written");
    end else begin
        expect_copy(SOURCE_BASE,128,8,5,32,1);
        if(aw_count!=old_aw+1 || b_count!=old_b+1)$fatal(1,"Bad write response not drained");
    end
    check_memory();
end
endtask

// Export exact pixel data as PPM for optional viewing/conversion; checks above
// still decide success. No dependency on Python is needed to run simulation.
task export_checker;
integer fd,i;
begin
    fd=$fopen("checker_source.ppm","w");
    if(fd==0)$fatal(1,"Cannot create source preview");
    $fdisplay(fd,"P3\n32 32\n255");
    for(i=0;i<1024;i=i+1)
        $fdisplay(fd,"%0d %0d %0d",saved_source[i][23:16],saved_source[i][15:8],saved_source[i][7:0]);
    $fclose(fd);
    fd=$fopen("checker_target.ppm","w");
    if(fd==0)$fatal(1,"Cannot create target preview");
    $fdisplay(fd,"P3\n%0d %0d\n255",FRAME_WIDTH,FRAME_HEIGHT);
    for(i=0;i<TARGET_WORDS;i=i+1)
        $fdisplay(fd,"%0d %0d %0d",memory.target_mem[i][23:16],
            memory.target_mem[i][15:8],memory.target_mem[i][7:0]);
    $fclose(fd);
end
endtask

integer old_cmd,old_ar,old_aw,n;
initial begin
    if($test$plusargs("VCD")) begin
        $dumpfile("blit.vcd");$dumpvars(0,dut);$dumpvars(1,tb_blit_engine);
    end
    repeat(4)@(negedge clk);rst_n=1;
    @(negedge clk);
    initialize_memory(0);
    if(busy || done || command_count!=0 || error_code!=0)$fatal(1,"Bad idle reset");

    if(ADDRESS_EDGE_ONLY) begin
        enabled=1;
        copy_case("last source beat ends exactly at 4GiB",32'hfffffff0,16,0,0,4,1);
        copy_case("two source rows end exactly at 4GiB",32'hfffff000,32'hff0,4,2,4,2);
        copy_case("two final source beats preserve all 32 address bits",32'hffffffe0,32,8,4,8,1);
        invalid_case("one beat past address space",32'hfffffff0,32,0,0,8,1);
        invalid_case("full precision stride product exceeds address space",SOURCE_BASE,32'hfffffff0,0,0,4,2);
        invalid_case("zero height with maximum aligned stride",SOURCE_BASE,32'hfffffff0,0,0,4,0);
        invalid_case("huge height cannot wrap into a valid geometry",SOURCE_BASE,16,0,0,4,32'hffffffff);
    end else if(EDGE_ONLY) begin
        enabled=1;
        copy_case("wide row exceeds burst buffer",SOURCE_BASE,1024,0,0,256,2);
        copy_case("source 4KiB split",SOURCE_BASE+32'hff0,256,0,2,64,2);
        copy_case("destination 4KiB split",SOURCE_BASE,256,1020,0,64,2);
        copy_case("different source and target page distances",SOURCE_BASE+32'hfe0,256,1020,0,64,3);
        copy_case("right/bottom edge",SOURCE_BASE,64,FRAME_WIDTH-16,FRAME_HEIGHT-1,16,1);
    end else begin
        announce("disabled commands ignored");
        submit(SOURCE_BASE,16,0,0,4,1);repeat(8)@(negedge clk);
        if(command_count!=0 || ar_count!=0 || busy || done)$fatal(1,"Command accepted while disabled");
        enabled=1;
        copy_case("four distinct pixels / one beat",SOURCE_BASE,16,4,2,4,1);

        initialize_memory(1);
        copy_case("32x32 checker at (8,5)",SOURCE_BASE,128,8,5,32,32);
        export_checker();
        initialize_memory(0);
        copy_case("32x32 unique pixels, padded source stride",SOURCE_BASE,192,8,5,32,32);
        copy_case("right/bottom edge",SOURCE_BASE,64,FRAME_WIDTH-16,FRAME_HEIGHT-1,16,1);

        announce("busy ignores a second START; command parameters are snapshots");
        old_cmd=command_count;
        expect_copy(SOURCE_BASE,128,8,5,32,32);
        submit(SOURCE_BASE,128,8,5,32,32);
        submit(SOURCE_BASE+256,16,0,0,4,1);
        await_done(0);
        if(command_count!=old_cmd+1)$fatal(1,"Busy accepted a second command");
        check_memory();

        invalid_case("zero width",SOURCE_BASE,128,0,0,0,1);
        invalid_case("zero height",SOURCE_BASE,128,0,0,32,0);
        invalid_case("source misalignment",SOURCE_BASE+4,128,0,0,32,1);
        invalid_case("source stride misalignment",SOURCE_BASE,132,0,0,32,1);
        invalid_case("destination x misalignment",SOURCE_BASE,128,1,0,32,1);
        invalid_case("width misalignment",SOURCE_BASE,128,0,0,30,1);
        invalid_case("source stride too short",SOURCE_BASE,112,0,0,32,1);
        invalid_case("destination right overflow",SOURCE_BASE,128,FRAME_WIDTH-16,0,32,1);
        invalid_case("destination bottom overflow",SOURCE_BASE,128,0,FRAME_HEIGHT-1,32,2);
        invalid_case("x arithmetic overflow",SOURCE_BASE,128,32'hfffffffc,0,32,1);
        invalid_case("y arithmetic overflow",SOURCE_BASE,128,0,32'hffffffff,32,2);
        invalid_case("source last byte overflow",32'hfffffff0,32,0,0,8,1);
        invalid_case("source stride multiplication overflow",SOURCE_BASE,32'hfffffff0,0,0,32,2);

        for(n=0;n<4;n=n+1)response_error_case(n);
        for(n=0;n<5;n=n+1)timeout_case(n);
        copy_case("new good command after drained errors",SOURCE_BASE,128,8,8,32,2);

        // Malformed RLAST is fail-stop: no successful DONE or new commands.
        // Recovery is tested using PLATFORM reset, with the model reset too.
        for(n=0;n<2;n=n+1) begin
            announce("malformed RLAST locks engine until platform reset");
            initialize_memory(0);
            old_aw=aw_count;
            if(n==0)early_rlast=1;else missing_rlast=1;
            submit(SOURCE_BASE,128,8,5,32,1);
            repeat(80)@(negedge clk);
            if(!busy || done || error_code!=ERR_PROTOCOL || aw_count!=old_aw)
                $fatal(1,"Malformed RLAST did not fail-stop");
            old_cmd=command_count;submit(SOURCE_BASE,16,0,0,4,1);
            repeat(5)@(negedge clk);
            if(command_count!=old_cmd || !busy)$fatal(1,"Fault state accepted command");
            early_rlast=0;missing_rlast=0;rst_n=0;
            repeat(4)@(negedge clk);rst_n=1;@(negedge clk);
            if(busy || done || command_count!=0 || error_code!=0)$fatal(1,"Platform reset failed");
        end
        initialize_memory(0);
        copy_case("copy after platform reset",SOURCE_BASE,16,0,0,4,1);
    end
    $display("PASS BLIT: %0d cases, canvas=%0dx%0d, burst_cap=%0d; RTL simulation only.",
        case_count,FRAME_WIDTH,FRAME_HEIGHT,MAX_BURST_BEATS);
    $finish;
end
initial begin #50000000;$fatal(1,"Testbench global timeout");end
endmodule
