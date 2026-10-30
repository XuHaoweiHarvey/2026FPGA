`timescale 1ns/1ps
module tb_color_key_blit;
parameter FRAME_WIDTH = 64, FRAME_HEIGHT = 48, MAX_BURST_BEATS = 32;
localparam SOURCE_WORDS = 32768, TARGET_WORDS = FRAME_WIDTH*FRAME_HEIGHT;
localparam FINAL_B_BEATS = MAX_BURST_BEATS < 8 ? MAX_BURST_BEATS : 8;
localparam [31:0] SOURCE_BASE = 32'h01000000, BACK_BASE = 32'h00800000;
localparam [23:0] MAGENTA = 24'hff00ff;
reg clk=0, rst_n=0, enabled=0, start=0, color_key_enable=0;
always #5 clk=~clk;
reg [23:0] color_key_rgb=0;
reg [31:0] src_addr=0, src_stride=0, dst_x=0, dst_y=0, width=0, height=0;
wire busy, done;
wire [31:0] error_code, command_count, araddr, awaddr;
wire [7:0] arlen, awlen;
wire arvalid, arready, rvalid, rready, rlast;
wire awvalid, awready, wvalid, wready, wlast, bvalid, bready;
wire [127:0] rdata, wdata;
wire [15:0] wstrb;
wire [3:0] rid, bid;
wire [1:0] rresp, bresp;
reg stall_ar=0, stall_r=0, stall_aw=0, stall_w=0, stall_b=0;
reg inject_rresp=0, inject_bresp=0;
wire [31:0] ar_count, r_count, aw_count, w_count, b_count;
wire memory_idle;
reg [31:0] saved_source[0:SOURCE_WORDS-1];
reg [31:0] expected_target[0:TARGET_WORDS-1];
integer case_count=0, zero_beats=0, mixed_beats=0, full_beats=0;

color_key_blit_engine #(
    .FRAME_WIDTH(FRAME_WIDTH), .FRAME_HEIGHT(FRAME_HEIGHT),
    .FRAME_STRIDE(FRAME_WIDTH*4), .MAX_BURST_BEATS(MAX_BURST_BEATS),
    .WATCHDOG_BITS(9)
) dut (
    .clk(clk), .rst_n(rst_n), .enabled(enabled), .start(start),
    .color_key_enable(color_key_enable), .color_key_rgb(color_key_rgb),
    .src_addr(src_addr), .src_stride(src_stride), .dst_x(dst_x), .dst_y(dst_y),
    .width(width), .height(height), .busy(busy), .done(done),
    .error_code(error_code), .command_count(command_count),
    .araddr(araddr), .arlen(arlen), .arvalid(arvalid), .arready(arready),
    .rdata(rdata), .rid(rid), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready),
    .awaddr(awaddr), .awlen(awlen), .awvalid(awvalid), .awready(awready),
    .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
    .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready)
);

// Reuse the byte-strobe-aware AXI test memory, not its expected-pixel logic.
blit_test_memory #(
    .FRAME_WIDTH(FRAME_WIDTH), .FRAME_HEIGHT(FRAME_HEIGHT),
    .SOURCE_WORDS(SOURCE_WORDS), .SOURCE_BASE(SOURCE_BASE), .BACK_BASE(BACK_BASE),
    .ALLOW_PARTIAL_STROBES(1)
) memory (
    .clk(clk), .rst_n(rst_n),
    .stall_ar(stall_ar), .stall_r(stall_r), .stall_aw(stall_aw),
    .stall_w(stall_w), .stall_b(stall_b),
    .inject_rresp(inject_rresp), .inject_rid(1'b0),
    .inject_bresp(inject_bresp), .inject_bid(1'b0),
    .early_rlast(1'b0), .missing_rlast(1'b0),
    .araddr(araddr), .arlen(arlen), .arvalid(arvalid), .arready(arready),
    .rdata(rdata), .rid(rid), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready),
    .awaddr(BACK_BASE+awaddr), .awlen(awlen), .awvalid(awvalid), .awready(awready),
    .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
    .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
    .ar_count(ar_count), .r_count(r_count), .aw_count(aw_count),
    .w_count(w_count), .b_count(b_count), .idle(memory_idle)
);

reg held_ar_stall=0, held_aw_stall=0, held_w_stall=0;
reg [39:0] held_ar=0, held_aw=0;
reg [144:0] held_w=0;
integer lane;
always @(posedge clk) begin
    if (!rst_n) begin
        held_ar_stall<=0; held_aw_stall<=0; held_w_stall<=0;
    end else begin
        if (held_ar_stall && (!arvalid || {araddr,arlen} !== held_ar))
            $fatal(1,"AR changed while stalled");
        if (held_aw_stall && (!awvalid || {awaddr,awlen} !== held_aw))
            $fatal(1,"AW changed while stalled");
        if (held_w_stall && (!wvalid || {wdata,wstrb,wlast} !== held_w))
            $fatal(1,"W data/key mask changed while stalled");
        held_ar_stall<=arvalid&&!arready; held_ar<={araddr,arlen};
        held_aw_stall<=awvalid&&!awready; held_aw<={awaddr,awlen};
        held_w_stall<=wvalid&&!wready; held_w<={wdata,wstrb,wlast};
        if (done && error_code==0 && (busy || !memory_idle || aw_count!=b_count))
            $fatal(1,"Successful DONE before final B drained");
        if ((arvalid && arlen>=MAX_BURST_BEATS) || (awvalid && awlen>=MAX_BURST_BEATS))
            $fatal(1,"Burst cap exceeded");
        if (wvalid && wready) begin
            for (lane=0;lane<4;lane=lane+1)
                if (wstrb[lane*4+:4] !== 4'h0 && wstrb[lane*4+:4] !== 4'hf)
                    $fatal(1,"Color key only masked part of a 32-bit pixel");
            if (wstrb==0) zero_beats=zero_beats+1;
            else if (wstrb==16'hffff) full_beats=full_beats+1;
            else mixed_beats=mixed_beats+1;
        end
    end
end

task announce;
input [8*100-1:0] name;
begin case_count=case_count+1; $display("CASE %0d: %0s",case_count,name); end
endtask

// Patterns: mixed, all key, no key, all 16 lane masks, and a 32x32 robot.
task initialize_memory;
input integer pattern;
input [23:0] key;
integer i,xx,yy;
reg [31:0] value;
begin
    if (busy || !memory_idle) $fatal(1,"Memory initialized during command");
    for (i=0;i<SOURCE_WORDS;i=i+1) begin
        value=32'ha5000000 ^ (i*32'h010203);
        if (value[23:0]==key) value=value^1;
        if (pattern==1 || (pattern==0 && i%7==0) ||
            (pattern==3 && ((i/4) & (1 << (i%4)))!=0))
            value={8'h80,key} ^ ((i%256) << 24);
        if (pattern==4 && i<1024) begin
            xx=i%32; yy=i/32;
            value=32'h00ff00ff;
            if ((xx>=8 && xx<24 && yy>=6 && yy<24) ||
                (xx>=15 && xx<17 && yy>=2 && yy<6) ||
                (yy>=24 && yy<30 && ((xx>=8 && xx<13) || (xx>=19 && xx<24))))
                value=32'h00ffc040;
            if (yy>=10 && yy<14 && ((xx>=10 && xx<13) || (xx>=19 && xx<22)))
                value=32'h00203040;
        end
        saved_source[i]=value; memory.source_mem[i]=value;
    end
    for (i=0;i<TARGET_WORDS;i=i+1) begin
        xx=i%FRAME_WIDTH; yy=i/FRAME_WIDTH;
        expected_target[i]=((xx/8+yy/8)%2) ? 32'h00345678 : 32'h00182838;
        // Exercise preservation of X as well as RGB on transparent pixels.
        if (pattern!=4) expected_target[i]=expected_target[i] ^ ((i%256) << 24);
        memory.target_mem[i]=expected_target[i];
    end
end
endtask

// Reference: iterate command coordinates and original pixels, independently
// of DMA addresses, strobes, caches or internal states.
task expect_copy;
input [31:0] ss,stride;
input integer xx,yy,ww,hh;
input key_enabled;
input [23:0] key;
integer row,col;
reg [31:0] pixel;
begin
    for (row=0;row<hh;row=row+1)
        for (col=0;col<ww;col=col+1) begin
            pixel=saved_source[(ss-SOURCE_BASE)/4+row*(stride/4)+col];
            if (!key_enabled || pixel[23:0]!=key)
                expected_target[(yy+row)*FRAME_WIDTH+xx+col]=pixel;
        end
end
endtask

task check_memory;
integer i;
begin
    for (i=0;i<TARGET_WORDS;i=i+1)
        if (memory.target_mem[i]!==expected_target[i])
            $fatal(1,"Target pixel (%0d,%0d): got %h expected %h",
                i%FRAME_WIDTH,i/FRAME_WIDTH,memory.target_mem[i],expected_target[i]);
    for (i=0;i<SOURCE_WORDS;i=i+1)
        if (memory.source_mem[i]!==saved_source[i]) $fatal(1,"Source modified at %0d",i);
end
endtask

task submit;
input [31:0] ss,stride,xx,yy,ww,hh;
input key_enabled;
input [23:0] key;
begin
    @(negedge clk);
    src_addr=ss; src_stride=stride; dst_x=xx; dst_y=yy; width=ww; height=hh;
    color_key_enable=key_enabled; color_key_rgb=key; start=1;
    @(negedge clk); start=0;
end
endtask

task await_done;
input [31:0] wanted_error;
integer cycles;
begin
    cycles=0;
    while (!done) begin
        @(negedge clk); cycles=cycles+1;
        if (cycles>100000) $fatal(1,"Command completion timed out");
    end
    if (busy || error_code!==wanted_error || !memory_idle)
        $fatal(1,"Wrong completion busy=%b error=%h wanted=%h idle=%b",
            busy,error_code,wanted_error,memory_idle);
end
endtask

task copy_case;
input [8*100-1:0] name;
input [31:0] ss,stride;
input integer xx,yy,ww,hh;
input key_enabled;
input [23:0] key;
integer old_cmd,old_r,old_w,old_ar,old_aw,old_b;
begin
    announce(name);
    old_cmd=command_count; old_r=r_count; old_w=w_count;
    old_ar=ar_count; old_aw=aw_count; old_b=b_count;
    expect_copy(ss,stride,xx,yy,ww,hh,key_enabled,key);
    submit(ss,stride,xx,yy,ww,hh,key_enabled,key);
    // Changing the inputs immediately after acceptance must have no effect.
    color_key_enable=!key_enabled; color_key_rgb=~key;
    src_addr=32'hbad; src_stride=0; dst_x=32'hffffffff; width=0; height=0;
    await_done(0);
    if (command_count!=old_cmd+1 || r_count-old_r!=ww*hh/4 || w_count-old_w!=ww*hh/4 ||
        ar_count-old_ar!=aw_count-old_aw || aw_count-old_aw!=b_count-old_b)
        $fatal(1,"Masked copy dropped a beat/response or miscounted a command");
    check_memory();
end
endtask

// Export memory produced by RTL, after full pixel checking. The PNG script
// converts these pixels; it does not manufacture a rendering result.
task export_target;
input [8*100-1:0] filename;
integer fd,i;
begin
    fd=$fopen(filename,"w"); if (!fd) $fatal(1,"Cannot open target preview");
    $fdisplay(fd,"P3\n%0d %0d\n255",FRAME_WIDTH,FRAME_HEIGHT);
    for (i=0;i<TARGET_WORDS;i=i+1)
        $fdisplay(fd,"%0d %0d %0d",memory.target_mem[i][23:16],
            memory.target_mem[i][15:8],memory.target_mem[i][7:0]);
    $fclose(fd);
end
endtask

task export_source;
integer fd,i;
begin
    fd=$fopen("sprite_source.ppm","w"); if (!fd) $fatal(1,"Cannot open source preview");
    $fdisplay(fd,"P3\n32 32\n255");
    for (i=0;i<1024;i=i+1)
        $fdisplay(fd,"%0d %0d %0d",saved_source[i][23:16],saved_source[i][15:8],saved_source[i][7:0]);
    $fclose(fd);
end
endtask

integer old_cmd,old_ar,old_aw,old_w,old_b,n;
initial begin
    if ($test$plusargs("VCD")) begin
        $dumpfile("color_key.vcd"); $dumpvars(0,dut); $dumpvars(1,tb_color_key_blit);
    end
    repeat (4) @(negedge clk); rst_n=1; @(negedge clk);
    initialize_memory(0,MAGENTA);
    announce("disabled engine ignores START");
    submit(SOURCE_BASE,16,0,0,4,1,1,MAGENTA);
    repeat (8) @(negedge clk);
    if (busy || done || command_count!=0 || ar_count!=0) $fatal(1,"Disabled engine accepted command");
    enabled=1;

    initialize_memory(3,MAGENTA);
    copy_case("all 16 transparent/opaque lane combinations, varied X",SOURCE_BASE,256,0,0,64,1,1,MAGENTA);
    initialize_memory(1,MAGENTA);
    copy_case("key disabled is ordinary BLIT including X",SOURCE_BASE,128,8,5,32,2,0,MAGENTA);
    initialize_memory(2,MAGENTA);
    copy_case("no matching colors",SOURCE_BASE,128,8,5,32,2,1,MAGENTA);
    initialize_memory(0,MAGENTA);
    copy_case("mixed pixels and padded source stride",SOURCE_BASE,192,8,5,32,5,1,MAGENTA);
    copy_case("right and bottom edge",SOURCE_BASE,64,FRAME_WIDTH-16,FRAME_HEIGHT-1,16,1,1,MAGENTA);
    for (n=0;n<2;n=n+1) begin
        initialize_memory(1,n==0 ? 24'h000000 : 24'hffffff);
        copy_case("new command replaces old key, black/white endpoints",SOURCE_BASE,64,4,3,16,2,
            1,n==0 ? 24'h000000 : 24'hffffff);
    end

    initialize_memory(1,MAGENTA);
    saved_source[1]=32'h00ff00fe; saved_source[2]=32'h00ff01ff; saved_source[3]=32'h00fe00ff;
    for (n=0;n<4;n=n+1) memory.source_mem[n]=saved_source[n];
    copy_case("exact RGB equality, not individual-channel equality",SOURCE_BASE,16,0,0,4,1,1,MAGENTA);

    announce("snapshot key through AR/W stalls and ignored busy START");
    initialize_memory(3,MAGENTA);
    old_cmd=command_count; stall_ar=1; stall_w=1;
    expect_copy(SOURCE_BASE,64,8,5,16,1,1,MAGENTA);
    submit(SOURCE_BASE,64,8,5,16,1,1,MAGENTA);
    wait (arvalid); @(negedge clk);
    submit(SOURCE_BASE+256,16,0,0,4,1,0,24'h123456);
    repeat (12) @(negedge clk); stall_ar=0;
    wait (wvalid); @(negedge clk); enabled=0;
    repeat (20) begin
        @(negedge clk); color_key_enable=~color_key_enable; color_key_rgb=~color_key_rgb;
    end
    stall_w=0; await_done(0); enabled=1;
    if (command_count!=old_cmd+1) $fatal(1,"Busy START was accepted");
    check_memory();

    announce("all-transparent burst still waits for final B");
    initialize_memory(1,MAGENTA); old_w=w_count; old_b=b_count; stall_b=1;
    submit(SOURCE_BASE,128,8,5,4*FINAL_B_BEATS,1,1,MAGENTA);
    wait (bready); repeat (30) @(negedge clk);
    if (!busy || done || w_count-old_w!=FINAL_B_BEATS || b_count!=old_b)
        $fatal(1,"All-transparent command skipped beats or finished before B");
    stall_b=0; await_done(0); check_memory();

    announce("invalid geometry returns original BLIT error without AXI");
    old_ar=ar_count; old_aw=aw_count; old_cmd=command_count;
    submit(SOURCE_BASE,32,0,0,6,1,1,MAGENTA); await_done(32'h21);
    if (ar_count!=old_ar || aw_count!=old_aw || command_count!=old_cmd+1)
        $fatal(1,"Invalid masked command touched AXI or lost count");
    check_memory();

    for (n=0;n<2;n=n+1) begin
        announce("masked copy preserves read/write error handling");
        initialize_memory(0,MAGENTA); old_ar=ar_count; old_aw=aw_count;
        if (n==0) inject_rresp=1;
        else begin inject_bresp=1; expect_copy(SOURCE_BASE,16,8,5,4,1,1,MAGENTA); end
        submit(SOURCE_BASE,16,8,5,4,2,1,MAGENTA);
        await_done(n==0 ? 32'h22 : 32'h23);
        inject_rresp=0; inject_bresp=0;
        if (ar_count!=old_ar+1 || aw_count!=old_aw+n) $fatal(1,"Error did not stop after first burst");
        check_memory();
    end

    announce("W timeout retains stable key mask and drains accepted burst");
    initialize_memory(0,MAGENTA); old_w=w_count; old_b=b_count; stall_w=1;
    expect_copy(SOURCE_BASE,16,8,5,4,1,1,MAGENTA);
    submit(SOURCE_BASE,16,8,5,4,2,1,MAGENTA);
    wait (wvalid);
    repeat (580) begin
        @(negedge clk); color_key_enable=~color_key_enable; color_key_rgb=~color_key_rgb;
    end
    if (!busy || done || !wvalid || error_code!=32'h24) $fatal(1,"Timed-out W was withdrawn");
    stall_w=0; await_done(32'h24);
    if (w_count!=old_w+1 || b_count!=old_b+1) $fatal(1,"Timeout did not drain exactly one beat");
    check_memory();

    if (FRAME_WIDTH>=1088) begin
        initialize_memory(0,MAGENTA);
        copy_case("wide copy split by burst buffer",SOURCE_BASE,1024,0,0,256,2,1,MAGENTA);
        copy_case("source and destination independent 4KiB splits",SOURCE_BASE+32'hfe0,256,1020,0,64,2,1,MAGENTA);
    end

    initialize_memory(4,MAGENTA); export_source(); export_target("background.ppm");
    copy_case("robot sprite, ordinary rectangular copy",SOURCE_BASE,128,16,8,32,32,0,MAGENTA);
    export_target("opaque_copy.ppm");
    initialize_memory(4,MAGENTA);
    copy_case("robot sprite, magenta preserves existing Back background",SOURCE_BASE,128,16,8,32,32,1,MAGENTA);
    export_target("color_key_copy.ppm");
    if (zero_beats==0 || mixed_beats==0 || full_beats==0) $fatal(1,"Missing mask coverage");
    $display("PASS COLOR KEY: %0d cases, canvas=%0dx%0d, burst_cap=%0d; zero/mixed/full beats=%0d/%0d/%0d; independent RTL only.",
        case_count,FRAME_WIDTH,FRAME_HEIGHT,MAX_BURST_BEATS,zero_beats,mixed_beats,full_beats);
    $finish;
end
initial begin #50000000; $fatal(1,"Color-key testbench global timeout"); end
endmodule
