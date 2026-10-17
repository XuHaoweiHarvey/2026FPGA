`timescale 1ns/1ps
// Real B executor + real buffer_manager, with two persistent memory slots.
// Real source guard; commands, reader-safe/FIFO ack and frame boundaries are
// test stimuli. This is NOT an APB/DDR arbiter/HDMI integration test.
module tb_graphics_double_buffer;
parameter MAX_BURST_BEATS = 32;
localparam FRAME_WIDTH = 64, FRAME_HEIGHT = 48, FRAME_WORDS = FRAME_WIDTH*FRAME_HEIGHT;
localparam [31:0] BUFFER0_BASE = 32'h00000000, BUFFER1_BASE = 32'h00800000;
localparam [31:0] BACKGROUND = 32'h00101428;
reg clk=0, rst_n=0, request=0;
always #5 clk=~clk;
reg [31:0] op=0, x=0, y=0, width=0, height=0, color=0, src_addr=0;
wire src_range_valid;
reg swap_request=0, clear_done=0, boundary_tick=0;
reg reader_safe=1, reader_fifo_empty=1, stall_ar=0, stall_b=0;
wire manager_accept, accept, busy, done, owned, draw_ready, pending, swap_done;
wire front_index, back_index, front_valid, reader_flush, reader_launch;
wire [31:0] error_code, command_count, front_base, back_base, command_base, reader_base;
wire [31:0] boundary_count, swap_count, missed_boundary_count;
wire [31:0] araddr, awaddr;
wire [7:0] arlen, awlen;
wire arvalid, arready, rvalid, rready, rlast, awvalid, awready;
wire wvalid, wready, wlast, bvalid, bready, memory_idle;
wire [127:0] rdata, wdata;
wire [15:0] wstrb;
wire [3:0] rid, bid;
wire [1:0] rresp, bresp;
wire [31:0] ar_count, r_count, aw_count, w_count, b_count;
reg stale_back_base, corrupt_frame, corruption_done=0;
initial begin
    stale_back_base=$test$plusargs("STALE_BACK_BASE");
    corrupt_frame=$test$plusargs("CORRUPT_FRAME");
end
// The negative control deliberately simulates a wrapper that keeps writing
// slot 1 after the first swap. Normally the latched base is added exactly once.
wire [31:0] physical_awaddr=(stale_back_base ? BUFFER1_BASE : command_base)+awaddr;

blit_source_guard #(.FRAME_WIDTH(FRAME_WIDTH), .FRAME_HEIGHT(FRAME_HEIGHT),
    .FRAME_STRIDE(FRAME_WIDTH*4)) source_guard (
    .clk(clk), .rst_n(rst_n), .command_accept(manager_accept),
    .front_base(front_base), .back_base(back_base), .src_addr(src_addr),
    .src_stride(32'd256), .width(width), .height(height),
    .src_range_valid(src_range_valid)
);

buffer_manager #(.BUFFER0_BASE(BUFFER0_BASE), .BUFFER1_BASE(BUFFER1_BASE),
    .FLUSH_CYCLES(4)) manager (
    .clk(clk), .rst_n(rst_n), .init_done(1'b1), .cmd_request(request),
    .writer_busy(busy), .writer_done(done), .writer_error(error_code),
    .swap_request(swap_request), .clear_done(clear_done),
    .boundary_tick(boundary_tick), .blank_active(1'b1),
    .reader_safe(reader_safe), .reader_fifo_empty(reader_fifo_empty),
    .command_accept(manager_accept), .draw_ready(draw_ready), .writer_owned(owned),
    .front_index(front_index), .back_index(back_index), .front_valid(front_valid),
    .swap_pending(pending), .swap_done(swap_done), .front_base(front_base),
    .back_base(back_base), .command_base(command_base), .reader_base(reader_base),
    .reader_flush(reader_flush), .reader_launch(reader_launch),
    .boundary_count(boundary_count), .swap_count(swap_count),
    .missed_boundary_count(missed_boundary_count)
);
graphics_engine #(.FRAME_WIDTH(FRAME_WIDTH), .FRAME_HEIGHT(FRAME_HEIGHT),
    .FRAME_STRIDE(FRAME_WIDTH*4), .MAX_BURST_BEATS(MAX_BURST_BEATS),
    .WATCHDOG_BITS(12)) dut (
    .clk(clk), .rst_n(rst_n), .enabled(1'b1), .start(manager_accept), .accept(accept),
    .op(op), .x(x), .y(y), .width(width), .height(height), .color(color),
    .src_addr(src_addr), .src_stride(32'd256), .src_range_valid(src_range_valid),
    .busy(busy), .done(done), .error_code(error_code), .command_count(command_count),
    .araddr(araddr), .arlen(arlen), .arvalid(arvalid), .arready(arready),
    .rdata(rdata), .rid(rid), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready),
    .awaddr(awaddr), .awlen(awlen), .awvalid(awvalid), .awready(awready),
    .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
    .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready)
);
graphics_double_buffer_memory #(.FRAME_WORDS(FRAME_WORDS),
    .BUFFER0_BASE(BUFFER0_BASE), .BUFFER1_BASE(BUFFER1_BASE)) memory (
    .clk(clk), .rst_n(rst_n), .stall_ar(stall_ar), .stall_b(stall_b),
    .araddr(araddr), .arlen(arlen), .arvalid(arvalid), .arready(arready),
    .rdata(rdata), .rid(rid), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready),
    .awaddr(physical_awaddr), .awlen(awlen), .awvalid(awvalid), .awready(awready),
    .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
    .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
    .ar_count(ar_count), .r_count(r_count), .aw_count(aw_count),
    .w_count(w_count), .b_count(b_count), .idle(memory_idle)
);

// Independent scene-level reference. Neither expected pixels nor role changes
// are inferred from AXI addresses or the execution units' internal counters.
reg [31:0] expected [0:2*FRAME_WORDS-1];
integer wanted_front=0, wanted_back=1, wanted_swaps=0, wanted_commands=0;
integer cases=0, pixel_checks=0;
reg [31:0] locked_front=0, locked_back=0, accepted_count=0;
reg [31:0] previous_front=BUFFER0_BASE, previous_reader=BUFFER0_BASE;
reg held_ar_stall=0, held_aw_stall=0, held_w_stall=0;
reg [39:0] held_ar=0, held_aw=0;
reg [144:0] held_w=0;
always @(posedge clk) if (rst_n) begin
    if (manager_accept !== accept) $fatal(1,"B/manager ACCEPT mismatch");
    if (command_count !== accepted_count) $fatal(1,"Command count differs from ACCEPTs");
    if (accept) begin
        accepted_count<=accepted_count+1;
        locked_front<=front_base; locked_back<=back_base;
    end
    if (busy && !owned) $fatal(1,"Active command lost Back ownership");
    if (owned && (command_base!==locked_back || front_base!==locked_front))
        $fatal(1,"Active command changed its locked buffer roles");
    if (arvalid && (!owned || araddr<locked_front ||
        {32'b0,araddr}+(arlen+1)*16>{32'b0,locked_front}+FRAME_WORDS*4))
        $fatal(1,"AR outside locked Front: %h",araddr);
    if (awvalid && (!owned || physical_awaddr<locked_back ||
        {32'b0,physical_awaddr}+(awlen+1)*16>{32'b0,locked_back}+FRAME_WORDS*4))
        $fatal(1,"AW outside locked Back: %h expected base %h",physical_awaddr,locked_back);
    if ((arvalid && arlen>=MAX_BURST_BEATS) || (awvalid && awlen>=MAX_BURST_BEATS))
        $fatal(1,"Two-buffer burst exceeded configured cap");
    if (held_ar_stall && (!arvalid || {araddr,arlen}!==held_ar))
        $fatal(1,"AR changed under backpressure");
    if (held_aw_stall && (!awvalid || {physical_awaddr,awlen}!==held_aw))
        $fatal(1,"Physical AW changed under backpressure");
    if (held_w_stall && (!wvalid || {wdata,wstrb,wlast}!==held_w))
        $fatal(1,"W changed under backpressure");
    held_ar_stall<=arvalid && !arready; held_ar<={araddr,arlen};
    held_aw_stall<=awvalid && !awready; held_aw<={physical_awaddr,awlen};
    held_w_stall<=wvalid && !wready; held_w<={wdata,wstrb,wlast};
    if (done && (busy || !memory_idle || aw_count!=b_count))
        $fatal(1,"DONE preceded final B/drain");
    if (front_base!==previous_front &&
        (busy || owned || !memory_idle || !reader_launch))
        $fatal(1,"Front changed before command completion/safe launch");
    if (reader_base!==previous_reader && !reader_launch)
        $fatal(1,"Reader base changed within a frame");
    if (reader_launch && (!reader_safe || !reader_fifo_empty || reader_flush))
        $fatal(1,"Reader launched without safe/FIFO acknowledgement");
    previous_front<=front_base; previous_reader<=reader_base;
end

task announce;
input [8*100-1:0] name;
begin cases=cases+1; $display("DOUBLE BUFFER %0d: %0s",cases,name); end
endtask

task check_pixels;
integer i;
begin
    if (busy || !memory_idle) $fatal(1,"Scoreboard sampled active memory");
    if (corrupt_frame && wanted_swaps==2 && !corruption_done) begin
        memory.pixels[wanted_front*FRAME_WORDS+8*FRAME_WIDTH+8]=
            memory.pixels[wanted_front*FRAME_WORDS+8*FRAME_WIDTH+8]^32'h1;
        corruption_done=1;
    end
    for (i=0; i<2*FRAME_WORDS; i=i+1) begin
        if (memory.pixels[i]!==expected[i])
            $fatal(1,"Double-buffer pixel slot=%0d (%0d,%0d): got %h expected %h",
                i/FRAME_WORDS,i%FRAME_WIDTH,(i%FRAME_WORDS)/FRAME_WIDTH,
                memory.pixels[i],expected[i]);
        pixel_checks=pixel_checks+1;
    end
end
endtask

task check_roles;
begin
    if (front_index!==wanted_front[0] || back_index!==wanted_back[0] ||
        front_base!==(wanted_front ? BUFFER1_BASE : BUFFER0_BASE) ||
        back_base!==(wanted_back ? BUFFER1_BASE : BUFFER0_BASE) ||
        reader_base!==front_base || swap_count!=wanted_swaps ||
        command_count!=wanted_commands || !front_valid)
        $fatal(1,"Unexpected roles/counts: Front=%h Back=%h swaps=%0d commands=%0d",
            front_base,back_base,swap_count,command_count);
end
endtask

task expect_fill;
input integer xx, yy, ww, hh;
input [31:0] cc;
integer row, col;
begin
    for (row=yy; row<yy+hh; row=row+1)
        for (col=xx; col<xx+ww; col=col+1)
            expected[wanted_back*FRAME_WORDS+row*FRAME_WIDTH+col]=cc;
end
endtask

task expect_copy;
input integer sx, sy, dx, dy;
integer row, col;
begin
    for (row=0; row<32; row=row+1)
        for (col=0; col<32; col=col+1)
            expected[wanted_back*FRAME_WORDS+(dy+row)*FRAME_WIDTH+dx+col]=
                expected[wanted_front*FRAME_WORDS+(sy+row)*FRAME_WIDTH+sx+col];
end
endtask

task issue;
input [31:0] operation, xx, yy, ww, hh, cc, source;
begin
    @(negedge clk);
    if (!draw_ready) $fatal(1,"Test submitted before ready");
    op=operation; x=xx; y=yy; width=ww; height=hh; color=cc; src_addr=source; request=1;
    #1; if (!accept) $fatal(1,"Ready command was not accepted");
    @(negedge clk); request=0; wanted_commands=wanted_commands+1;
    if (!owned || command_count!=wanted_commands)
        $fatal(1,"Accepted command did not lock Back/count once");
end
endtask

task await_release;
integer cycles;
begin
    cycles=0;
    while (!done || busy || owned) begin
        @(negedge clk); cycles=cycles+1;
        if (cycles>100000) $fatal(1,"Two-buffer command timed out");
    end
    if (error_code!=0 || !memory_idle || aw_count!=b_count)
        $fatal(1,"Two-buffer command failed/drained early: %h",error_code);
    check_roles(); check_pixels();
end
endtask

task fill;
input integer xx, yy, ww, hh;
input [31:0] cc;
begin
    expect_fill(xx,yy,ww,hh,cc);
    issue(0,xx,yy,ww,hh,cc,0); await_release();
end
endtask

task begin_copy;
input integer sx, sy, dx, dy;
reg [31:0] source;
begin
    source=(wanted_front ? BUFFER1_BASE : BUFFER0_BASE)+(sy*FRAME_WIDTH+sx)*4;
    expect_copy(sx,sy,dx,dy);
    issue(1,dx,dy,32,32,0,source);
end
endtask

task request_swap;
begin
    @(negedge clk); swap_request=1;
    @(negedge clk); swap_request=0;
    if (!pending || draw_ready) $fatal(1,"Swap request did not block new commands");
end
endtask

task boundary;
begin
    @(negedge clk); boundary_tick=1;
    @(negedge clk); boundary_tick=0;
    repeat(20) @(negedge clk);
end
endtask

task confirm_swap;
integer temp;
begin
    temp=wanted_front; wanted_front=wanted_back; wanted_back=temp;
    wanted_swaps=wanted_swaps+1;
    if (pending || !swap_done || busy || owned) $fatal(1,"Swap did not complete cleanly");
    check_roles(); check_pixels();
    // Acknowledging the sticky result must not cause another swap.
    clear_done=1; @(negedge clk); clear_done=0; @(negedge clk);
    if (swap_done) $fatal(1,"Sticky swap result did not clear");
    check_roles();
end
endtask

task swap_after_release;
begin request_swap(); boundary(); confirm_swap(); end
endtask

task export_frame;
input [8*80-1:0] filename;
input integer slot;
integer fd, row, col;
reg [31:0] pixel;
begin
    fd=$fopen(filename,"w");
    if (!fd) $fatal(1,"Cannot create two-buffer PPM");
    $fdisplay(fd,"P3\n%0d %0d\n255",FRAME_WIDTH,FRAME_HEIGHT);
    for (row=0; row<FRAME_HEIGHT; row=row+1)
        for (col=0; col<FRAME_WIDTH; col=col+1) begin
            pixel=memory.pixels[slot*FRAME_WORDS+row*FRAME_WIDTH+col];
            $fdisplay(fd,"%0d %0d %0d",pixel[23:16],pixel[15:8],pixel[7:0]);
        end
    $fclose(fd);
end
endtask

integer i, before_w, source_x, source_y, destination_x, destination_y;
initial begin
    if ($test$plusargs("VCD")) begin
        $dumpfile("graphics.vcd"); $dumpvars(0,tb_graphics_double_buffer);
    end
    // Seed only reset contents, never the source pattern: the latter must be
    // produced by real FILL transactions and survive each physical role swap.
    for (i=0; i<2*FRAME_WORDS; i=i+1) begin
        memory.pixels[i]=i<FRAME_WORDS ? 32'h00202020 : 32'h00445566;
        expected[i]=i<FRAME_WORDS ? 32'h00202020 : 32'h00445566;
    end
    repeat(4) @(negedge clk); rst_n=1; repeat(3) @(negedge clk);
    announce("distinct physical slots and initial Front0/Back1 roles");
    check_roles(); check_pixels();

    announce("FILL creates a 32x32 four-colour source in Back1; Front0 stays unchanged");
    fill(0,0,64,48,BACKGROUND);
    fill(0,0,16,16,32'h00e04040); fill(16,0,16,16,32'h0040c060);
    fill(0,16,16,16,32'h004080e0); fill(16,16,16,16,32'h00f0d050);
    export_frame("01_source_back.ppm",wanted_back);

    announce("reader drain blocks first swap; late readiness waits for another boundary");
    request_swap(); reader_safe=0; boundary();
    if (swap_count!=0 || !pending || reader_flush || reader_launch || missed_boundary_count!=1)
        $fatal(1,"Unsafe reader allowed flush/swap");
    reader_safe=1; repeat(8) @(negedge clk);
    if (swap_count!=0 || !pending) $fatal(1,"Late reader drain swapped without boundary");

    announce("FIFO empty acknowledgement gates successful first publication");
    reader_fifo_empty=0;
    fork
        boundary();
        begin
            wait(reader_flush); wait(!reader_flush); repeat(3) @(negedge clk);
            if (swap_count!=0 || !pending || reader_launch)
                $fatal(1,"Swap ignored FIFO empty acknowledgement");
            reader_fifo_empty=1;
        end
    join
    confirm_swap(); export_frame("02_source_front.ppm",wanted_front);

    announce("clear new Back0 while the four-colour Front1 remains intact");
    fill(0,0,64,48,BACKGROUND); export_frame("03_cleared_back.ppm",wanted_back);

    announce("BLIT with stalled AR accepts pending swap but rejects another command");
    stall_ar=1; before_w=w_count; begin_copy(0,0,8,8);
    wait(arvalid); request_swap();
    @(negedge clk); request=1; op=32'hffffffff; src_addr=32'hdeadbeef;
    #1; if (accept || manager_accept) $fatal(1,"Pending swap accepted a second command");
    @(negedge clk); request=0;
    boundary();
    if (swap_count!=1 || !pending || !busy || !owned || command_count!=wanted_commands)
        $fatal(1,"Stalled AR allowed early publication/extra command");
    stall_ar=0;

    announce("hold final B after all 256 W beats; writer and pending swap stay owned");
    while (w_count<before_w+256) @(negedge clk);
    stall_b=1;
    if (aw_count!=b_count+1 || done || !busy || !owned)
        $fatal(1,"Last W incorrectly completed BLIT before B");
    boundary();
    if (swap_count!=1 || !pending || done || !busy || !owned)
        $fatal(1,"Boundary published a frame before final B");
    export_frame("04_pending_front.ppm",wanted_front);
    stall_b=0; await_release();
    repeat(12) @(negedge clk);
    if (swap_count!=1 || !pending) $fatal(1,"Final B swapped without a new boundary");

    announce("new boundary publishes the copied Back0 as Front0");
    boundary(); confirm_swap(); export_frame("05_copy_front.ppm",wanted_front);

    announce("reverse copy reads Front0 and writes Back1 at the right/bottom edge");
    fill(0,0,64,48,32'h00183020);
    begin_copy(8,8,28,16); await_release(); swap_after_release();
    export_frame("06_return_front.ppm",wanted_front);

    announce("copy from a nonzero source offset, then partial-strobe FILL overlay");
    fill(0,0,64,48,BACKGROUND);
    begin_copy(28,16,0,0); await_release();
    fill(11,12,13,5,32'h00ff5030); swap_after_release();
    export_frame("07_overlay_front.ppm",wanted_front);

    announce("four more alternating copies preserve each newly published source");
    source_x=0; source_y=0;
    for (i=0; i<4; i=i+1) begin
        destination_x=(i%2==0) ? 28 : 4; destination_y=(i%2==0) ? 16 : 4;
        fill(0,0,64,48,BACKGROUND+i*32'h00070403);
        begin_copy(source_x,source_y,destination_x,destination_y);
        await_release(); swap_after_release();
        source_x=destination_x; source_y=destination_y;
    end
    if (wanted_swaps!=8 || wanted_commands!=20 || missed_boundary_count!=1)
        $fatal(1,"Unexpected scenario totals");
    $display("PASS GRAPHICS DOUBLE BUFFER: %0d cases, %0d commands, %0d swaps, %0d pixel comparisons; real source guard, model boundaries/DDR, no display arbiter",
        cases,command_count,swap_count,pixel_checks);
    $finish;
end
initial begin #20000000; $fatal(1,"Global double-buffer watchdog"); end
endmodule
