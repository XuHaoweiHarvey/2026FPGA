`timescale 1ns/1ps
// Reuses blit_test_memory from tb_blit_engine.v, with byte strobes enabled.
module tb_graphics_engine;
parameter MAX_BURST_BEATS = 32;
parameter [31:0] OP_FILL = 0, OP_BLIT = 1;
localparam FRAME_WIDTH = 64, FRAME_HEIGHT = 48;
localparam SOURCE_WORDS = 32768, TARGET_WORDS = FRAME_WIDTH * FRAME_HEIGHT;
localparam [31:0] SOURCE_BASE = 32'h01000000, BACK_BASE = 32'h00800000;
localparam [31:0] ERR_OPCODE = 32'h26;
reg clk = 0, rst_n = 0, enabled = 0, start = 0;
reg range_decision = 1, src_range_valid = 0;
always #5 clk = ~clk;
reg [31:0] cmd_op = 0, cmd_x = 0, cmd_y = 0, cmd_width = 0, cmd_height = 0;
reg [31:0] cmd_color = 0, cmd_src_addr = 0, cmd_src_stride = 0;
wire busy, done, accept;
wire [31:0] error_code, command_count;
wire [31:0] araddr, awaddr;
wire [7:0] arlen, awlen;
wire arvalid, arready, rvalid, rready, rlast;
wire awvalid, awready, wvalid, wready, wlast, bvalid, bready;
wire [127:0] rdata, wdata;
wire [15:0] wstrb;
wire [3:0] rid, bid;
wire [1:0] rresp, bresp;
reg stall_ar = 0, stall_r = 0, stall_aw = 0, stall_w = 0, stall_b = 0;
reg inject_rresp = 0, inject_rid = 0, inject_bresp = 0, inject_bid = 0;
reg early_rlast = 0, missing_rlast = 0;
wire [31:0] ar_count, r_count, aw_count, w_count, b_count;
wire memory_idle;
reg [31:0] saved_source [0:SOURCE_WORDS-1];
reg [31:0] expected_target [0:TARGET_WORDS-1];
integer case_count = 0;

// C's validator registers its result on the final ACCEPT edge, not earlier.
// This makes the previous command's result visible at that edge and detects
// a B implementation that samples the register too soon.
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) src_range_valid <= 0;
    else if (accept) src_range_valid <= range_decision;
end

graphics_engine #(
    .FRAME_WIDTH(FRAME_WIDTH), .FRAME_HEIGHT(FRAME_HEIGHT),
    .FRAME_STRIDE(FRAME_WIDTH*4), .MAX_BURST_BEATS(MAX_BURST_BEATS),
    .WATCHDOG_BITS(9), .OP_FILL(OP_FILL), .OP_BLIT(OP_BLIT)
) dut (
    .clk(clk), .rst_n(rst_n), .enabled(enabled), .start(start),
    .op(cmd_op), .x(cmd_x), .y(cmd_y),
    .width(cmd_width), .height(cmd_height), .color(cmd_color),
    .src_addr(cmd_src_addr), .src_stride(cmd_src_stride),
    .src_range_valid(src_range_valid), .accept(accept),
    .busy(busy), .done(done), .error_code(error_code), .command_count(command_count),
    .araddr(araddr), .arlen(arlen), .arvalid(arvalid), .arready(arready),
    .rdata(rdata), .rid(rid), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready),
    .awaddr(awaddr), .awlen(awlen), .awvalid(awvalid), .awready(awready),
    .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
    .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready)
);
blit_test_memory #(
    .FRAME_WIDTH(FRAME_WIDTH), .FRAME_HEIGHT(FRAME_HEIGHT),
    .SOURCE_WORDS(SOURCE_WORDS), .ALLOW_PARTIAL_STROBES(1),
    .SOURCE_BASE(SOURCE_BASE), .BACK_BASE(BACK_BASE)
) memory (
    .clk(clk), .rst_n(rst_n),
    .stall_ar(stall_ar), .stall_r(stall_r), .stall_aw(stall_aw),
    .stall_w(stall_w), .stall_b(stall_b),
    .inject_rresp(inject_rresp), .inject_rid(inject_rid),
    .inject_bresp(inject_bresp), .inject_bid(inject_bid),
    .early_rlast(early_rlast), .missing_rlast(missing_rlast),
    .araddr(araddr), .arlen(arlen), .arvalid(arvalid), .arready(arready),
    .rdata(rdata), .rid(rid), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready),
    // The platform wrapper will add the latched Back once. Model that here.
    .awaddr(BACK_BASE + awaddr), .awlen(awlen), .awvalid(awvalid), .awready(awready),
    .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
    .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
    .ar_count(ar_count), .r_count(r_count), .aw_count(aw_count),
    .w_count(w_count), .b_count(b_count), .idle(memory_idle)
);

reg held_ar_stall = 0, held_aw_stall = 0, held_w_stall = 0;
reg [39:0] held_ar = 0, held_aw = 0;
reg [144:0] held_w = 0;
reg was_busy = 0, previous_owner = 0;
reg [31:0] accepted_requests = 0;
reg checking_range_rejection = 0;
always @(posedge clk) begin
    if (!rst_n) begin
        held_ar_stall <= 0; held_aw_stall <= 0; held_w_stall <= 0; was_busy <= 0;
        accepted_requests <= 0;
    end else begin
        if (command_count !== accepted_requests)
            $fatal(1, "COUNT did not match the actual ACCEPT events");
        if (accept) accepted_requests <= accepted_requests + 1'b1;
        if (accept && (busy || !enabled || !start))
            $fatal(1, "ACCEPT without an enabled idle START");
        if (checking_range_rejection && (arvalid || awvalid || wvalid || dut.blit_unit.start))
            $fatal(1, "Rejected source range started BLIT or exposed AXI");
        if (held_ar_stall && (!arvalid || {araddr,arlen} !== held_ar))
            $fatal(1, "Dispatcher changed stalled AR");
        if (held_aw_stall && (!awvalid || {awaddr,awlen} !== held_aw))
            $fatal(1, "Dispatcher changed stalled AW");
        if (held_w_stall && (!wvalid || {wdata,wstrb,wlast} !== held_w))
            $fatal(1, "Dispatcher changed stalled W");
        held_ar_stall <= arvalid && !arready; held_ar <= {araddr,arlen};
        held_aw_stall <= awvalid && !awready; held_aw <= {awaddr,awlen};
        held_w_stall <= wvalid && !wready; held_w <= {wdata,wstrb,wlast};
        if (done && (busy || !memory_idle || aw_count != b_count))
            $fatal(1, "Public DONE before command/transactions drained");
        if (!busy && (arvalid || rready || awvalid || wvalid || bready))
            $fatal(1, "Idle dispatcher exposed a transaction");
        if (dut.fill_busy && dut.blit_busy)
            $fatal(1, "Both execution units started together");
        if (was_busy && busy && previous_owner != dut.selected_blit)
            $fatal(1, "Dispatcher changed owner during a command");
        if ((arvalid && arlen >= MAX_BURST_BEATS) ||
            (awvalid && awlen >= MAX_BURST_BEATS))
            $fatal(1, "Configured burst cap exceeded");
        was_busy <= busy; previous_owner <= dut.selected_blit;
    end
end

task announce;
input [8*100-1:0] name;
begin case_count = case_count + 1; $display("CASE %0d: %0s", case_count, name); end
endtask

task platform_reset;
begin
    @(negedge clk); rst_n = 0; enabled = 0; start = 0;
    range_decision = 1;
    stall_ar = 0; stall_r = 0; stall_aw = 0; stall_w = 0; stall_b = 0;
    inject_rresp = 0; inject_rid = 0; inject_bresp = 0; inject_bid = 0;
    early_rlast = 0; missing_rlast = 0;
    repeat (4) @(negedge clk);
    rst_n = 1;
    @(negedge clk); enabled = 1;
    if (busy || done || command_count != 0 || error_code != 0)
        $fatal(1, "Wrong platform reset state");
end
endtask

task initialize_memory;
integer i, xx, yy;
begin
    if (!memory_idle || busy) $fatal(1, "Test changed active memory");
    for (i=0; i<SOURCE_WORDS; i=i+1) begin
        saved_source[i] = 32'ha5000000 ^ (i*32'h010203);
        if (i<1024) begin
            xx=i%32; yy=i/32;
            saved_source[i] = ((xx/4+yy/4)%2) ? 32'h00eeeeee : 32'h002040c0;
        end
        memory.source_mem[i] = saved_source[i];
    end
    for (i=0; i<TARGET_WORDS; i=i+1) begin
        expected_target[i] = 32'h00556677 ^ i;
        memory.target_mem[i] = expected_target[i];
    end
end
endtask

// This scoreboard uses scene coordinates and saved source pixels, never the
// dispatcher's internal addresses, selected child, cache or beat counters.
task expect_fill;
input integer xx, yy, ww, hh;
input [31:0] cc;
integer row, col;
begin
    for (row=0; row<hh; row=row+1)
        for (col=0; col<ww; col=col+1)
            expected_target[(yy+row)*FRAME_WIDTH+xx+col] = cc;
end
endtask

task expect_copy;
input [31:0] ss, stride;
input integer xx, yy, ww, hh;
integer row, col;
begin
    for (row=0; row<hh; row=row+1)
        for (col=0; col<ww; col=col+1)
            expected_target[(yy+row)*FRAME_WIDTH+xx+col] =
                saved_source[(ss-SOURCE_BASE)/4+row*(stride/4)+col];
end
endtask

task check_memory;
integer i;
begin
    for (i=0; i<TARGET_WORDS; i=i+1)
        if (memory.target_mem[i] !== expected_target[i])
            $fatal(1, "Target pixel (%0d,%0d): got %h expected %h",
                i%FRAME_WIDTH, i/FRAME_WIDTH, memory.target_mem[i], expected_target[i]);
    for (i=0; i<SOURCE_WORDS; i=i+1)
        if (memory.source_mem[i] !== saved_source[i]) $fatal(1, "Source changed at %0d", i);
end
endtask

task submit;
input [31:0] op, xx, yy, ww, hh, cc, ss, stride;
begin
    @(negedge clk);
    cmd_op=op; cmd_x=xx; cmd_y=yy; cmd_width=ww; cmd_height=hh;
    cmd_color=cc; cmd_src_addr=ss; cmd_src_stride=stride; start=1;
    @(negedge clk); start=0;
end
endtask

task poison_inputs;
begin
    // Change opcode AND every parameter before the child samples START.
    cmd_op=32'hfffffffe; cmd_x=32'hffffffff; cmd_y=32'hffffffff;
    cmd_width=0; cmd_height=0; cmd_color=32'hbad;
    cmd_src_addr=3; cmd_src_stride=0; enabled=0;
    // C keeps the accepted decision while later inputs change.
    range_decision=0;
end
endtask

task await_done;
input [31:0] wanted_error;
integer cycles;
begin
    cycles=0;
    while (!done) begin
        @(negedge clk); cycles=cycles+1;
        if (cycles>100000) $fatal(1, "Command stuck, error=%h", error_code);
    end
    if (busy || !memory_idle || error_code !== wanted_error)
        $fatal(1, "Wrong completion busy=%b idle=%b error=%h expected=%h",
            busy, memory_idle, error_code, wanted_error);
    repeat (3) @(negedge clk);
    if (!done || error_code !== wanted_error) $fatal(1, "Result was not sticky");
end
endtask

task fill_case;
input [8*100-1:0] name;
input integer xx, yy, ww, hh;
input [31:0] cc;
integer old_cmd, old_ar;
begin
    announce(name); old_cmd=command_count; old_ar=ar_count; enabled=1;
    expect_fill(xx,yy,ww,hh,cc);
    submit(OP_FILL,xx,yy,ww,hh,cc,3,0);
    poison_inputs(); await_done(0); enabled=1; range_decision=1;
    if (command_count != old_cmd+1 || ar_count != old_ar)
        $fatal(1, "FILL count mismatch or unexpected read");
    check_memory();
end
endtask

task copy_case;
input [8*100-1:0] name;
input [31:0] ss, stride;
input integer xx, yy, ww, hh;
integer old_cmd, old_r, old_w;
begin
    announce(name); old_cmd=command_count; old_r=r_count; old_w=w_count; enabled=1;
    expect_copy(ss,stride,xx,yy,ww,hh);
    submit(OP_BLIT,xx,yy,ww,hh,32'hffffffff,ss,stride);
    poison_inputs(); await_done(0); enabled=1; range_decision=1;
    if (command_count != old_cmd+1 || r_count-old_r != ww*hh/4 || w_count-old_w != ww*hh/4)
        $fatal(1, "BLIT public count or transferred pixel count mismatch");
    check_memory();
end
endtask

task disabled_case;
reg old_done;
reg [31:0] old_error;
integer old_cmd, old_ar, old_aw;
begin
    announce("disabled request preserves the previous public result");
    old_done=done; old_error=error_code; old_cmd=command_count;
    old_ar=ar_count; old_aw=aw_count; enabled=0;
    submit(OP_FILL,0,0,4,1,0,SOURCE_BASE,128);
    repeat (8) @(negedge clk);
    if (busy || done !== old_done || error_code !== old_error ||
        command_count != old_cmd || ar_count != old_ar || aw_count != old_aw)
        $fatal(1, "Disabled request changed state");
    enabled=1; check_memory();
end
endtask

task invalid_case;
input [8*100-1:0] name;
input [31:0] op, xx, yy, ww, hh, ss, wanted_error;
integer old_cmd, old_ar, old_aw;
begin
    announce(name); old_cmd=command_count; old_ar=ar_count; old_aw=aw_count;
    submit(op,xx,yy,ww,hh,0,ss,128); await_done(wanted_error);
    if (command_count != old_cmd+1 || ar_count != old_ar || aw_count != old_aw)
        $fatal(1, "Invalid request touched AXI or counted incorrectly");
    check_memory();
end
endtask

task response_error_case;
input integer kind;
integer old_cmd, old_ar, old_aw, first_pixels;
begin
    announce("BLIT response error routes only to the active command");
    $display("  error kind=%0d (RRESP/RID/BRESP/BID=0/1/2/3)",kind);
    initialize_memory(); old_cmd=command_count; old_ar=ar_count; old_aw=aw_count;
    case (kind)
        0:inject_rresp=1; 1:inject_rid=1; 2:inject_bresp=1; 3:inject_bid=1;
    endcase
    submit(OP_BLIT,8,5,32,2,0,SOURCE_BASE,128);
    if (kind<2) begin
        wait (rvalid && rready); @(negedge clk); inject_rresp=0; inject_rid=0;
    end
    await_done(kind<2 ? 32'h22 : 32'h23);
    inject_rresp=0; inject_rid=0; inject_bresp=0; inject_bid=0;
    first_pixels = MAX_BURST_BEATS<8 ? MAX_BURST_BEATS*4 : 32;
    if (kind>=2) expect_copy(SOURCE_BASE,128,8,5,first_pixels,1);
    if (command_count != old_cmd+1 || ar_count != old_ar+1 || aw_count != old_aw+(kind>=2))
        $fatal(1, "Response error did not stop after the current burst");
    check_memory();
end
endtask

task rejected_source_case;
integer old_cmd, old_ar, old_aw, old_child_count;
begin
    announce("invalid source range counts once and uses C's accepted snapshot");
    old_cmd=command_count; old_ar=ar_count; old_aw=aw_count;
    old_child_count=dut.blit_unit.command_count;
    checking_range_rejection=1; range_decision=0;
    submit(OP_BLIT,8,5,32,2,0,SOURCE_BASE,128);
    // Restore live inputs before CHECK_SOURCE. C holds this command's result.
    range_decision=1;
    await_done(32'h21);
    if (command_count != old_cmd+1 || ar_count != old_ar || aw_count != old_aw ||
        dut.blit_unit.command_count != old_child_count)
        $fatal(1, "Source rejection lost COUNT or launched a child");
    checking_range_rejection=0; check_memory();
end
endtask

task timeout_case;
input [31:0] op;
input integer channel; // AR/R/AW/W/B=0/1/2/3/4
integer old_cmd, old_ar, old_aw, first_pixels;
reg [31:0] wanted_error;
begin
    announce("timeout keeps public BUSY and owner until service resumes and drains");
    $display("  op=%0d channel=%0d",op,channel);
    initialize_memory(); old_cmd=command_count; old_ar=ar_count; old_aw=aw_count;
    wanted_error = op==OP_FILL ? 32'h13 : 32'h24;
    case (channel)
        0:stall_ar=1; 1:stall_r=1; 2:stall_aw=1; 3:stall_w=1; 4:stall_b=1;
    endcase
    submit(op,0,5,32,2,32'h00ffcc00,SOURCE_BASE,128);
    case (channel)
        0:wait(arvalid); 1:wait(rready); 2:wait(awvalid); 3:wait(wvalid); 4:wait(bready);
    endcase
    repeat (580) @(negedge clk);
    if (!busy || done || error_code != wanted_error)
        $fatal(1, "Public timeout lost ownership or error");
    submit(op==OP_FILL ? OP_BLIT : OP_FILL,0,0,4,1,0,SOURCE_BASE,128);
    if (command_count != old_cmd+1) $fatal(1, "Timed-out command accepted another START");
    stall_ar=0; stall_r=0; stall_aw=0; stall_w=0; stall_b=0;
    await_done(wanted_error);
    first_pixels = MAX_BURST_BEATS<8 ? MAX_BURST_BEATS*4 : 32;
    if (channel>=2) begin
        if (op==OP_FILL) expect_fill(0,5,first_pixels,1,32'h00ffcc00);
        else expect_copy(SOURCE_BASE,128,0,5,first_pixels,1);
    end
    if (ar_count != old_ar+(op==OP_BLIT) || aw_count != old_aw+(channel>=2))
        $fatal(1, "Timeout did not drain exactly one transaction");
    check_memory();
end
endtask

task fault_case;
input integer early;
integer old_cmd, old_aw, cycles;
begin
    announce("malformed RLAST retains public BUSY until platform reset");
    $display("  early=%0d",early);
    initialize_memory(); old_cmd=command_count; old_aw=aw_count;
    early_rlast=early; missing_rlast=!early;
    submit(OP_BLIT,8,5,32,2,0,SOURCE_BASE,128);
    cycles=0;
    while (error_code != 32'h25) begin
        @(negedge clk); cycles=cycles+1;
        if (cycles>1000) $fatal(1, "Public protocol fault not reported");
    end
    submit(OP_FILL,0,0,4,1,0,SOURCE_BASE,128);
    repeat (12) @(negedge clk);
    if (!busy || done || command_count != old_cmd+1 || aw_count != old_aw || error_code != 32'h25)
        $fatal(1, "Fault released ownership or accepted another command");
    check_memory(); platform_reset(); initialize_memory();
end
endtask

task export_target;
input [8*100-1:0] path;
integer fd, i;
begin
    fd=$fopen(path,"w"); if (!fd) $fatal(1,"Cannot create target preview");
    $fdisplay(fd,"P3\n%0d %0d\n255",FRAME_WIDTH,FRAME_HEIGHT);
    for (i=0; i<TARGET_WORDS; i=i+1)
        $fdisplay(fd,"%0d %0d %0d",memory.target_mem[i][23:16],
            memory.target_mem[i][15:8],memory.target_mem[i][7:0]);
    $fclose(fd);
end
endtask

task export_source;
integer fd, i;
begin
    fd=$fopen("checker_source.ppm","w"); if (!fd) $fatal(1,"Cannot create source preview");
    $fdisplay(fd,"P3\n32 32\n255");
    for (i=0; i<1024; i=i+1)
        $fdisplay(fd,"%0d %0d %0d",saved_source[i][23:16],saved_source[i][15:8],saved_source[i][7:0]);
    $fclose(fd);
end
endtask

integer old_cmd, old_ar, old_aw, n, first_pixels;
initial begin
    if ($test$plusargs("VCD")) begin
        $dumpfile("graphics.vcd"); $dumpvars(0,dut); $dumpvars(1,tb_graphics_engine);
    end
    platform_reset(); initialize_memory(); disabled_case();

    fill_case("scene 1: FILL the full background",0,0,64,48,32'h00102050);
    export_target("01_fill.ppm"); export_source();
    copy_case("scene 2: BLIT checker, ignore old FILL DONE",SOURCE_BASE,128,8,5,32,32);
    export_target("02_blit.ppm");
    fill_case("scene 3: unaligned FILL over checker, ignore old BLIT DONE",11,12,13,5,32'h00e04040);
    export_target("03_overlay.ppm");
    fill_case("consecutive FILL, preserve pixels outside a one-pixel rect",1,1,1,1,32'h0011dd88);
    fill_case("unaligned FILL at right/bottom edge",61,47,3,1,32'h00ffaa11);
    copy_case("BLIT with padded source stride",SOURCE_BASE,192,4,2,16,3);
    copy_case("consecutive BLIT, a single beat on each row",SOURCE_BASE+16,32,0,0,4,2);

    invalid_case("unknown opcode",32'hffffffff,0,0,4,1,SOURCE_BASE,ERR_OPCODE);
    invalid_case("FILL zero width completes without child BUSY",OP_FILL,0,0,0,1,SOURCE_BASE,32'h11);
    invalid_case("FILL target outside frame",OP_FILL,63,0,2,1,SOURCE_BASE,32'h11);
    invalid_case("BLIT alignment differs from FILL",OP_BLIT,1,0,4,1,SOURCE_BASE,32'h21);
    invalid_case("BLIT source address misaligned",OP_BLIT,0,0,4,1,SOURCE_BASE+4,32'h21);
    disabled_case();
    fill_case("FILL success after BLIT parameter error",3,7,9,2,32'h007799aa);
    copy_case("BLIT clears its own stale parameter error",SOURCE_BASE,128,4,4,8,2);
    rejected_source_case();
    disabled_case(); // An unaccepted START cannot clear 0x21.
    copy_case("a newly accepted BLIT clears the source-range error",SOURCE_BASE,128,4,4,8,2);
    range_decision=0;
    invalid_case("unknown opcode wins over invalid source range",32'hffffffff,0,0,4,1,SOURCE_BASE,ERR_OPCODE);
    fill_case("unaligned FILL ignores C's BLIT-only source restriction",3,9,7,2,32'h00112233);

    announce("FILL busy ignores a BLIT START and holds its write selection");
    old_cmd=command_count; old_ar=ar_count; stall_aw=1;
    expect_fill(3,8,17,2,32'h0066ccff);
    submit(OP_FILL,3,8,17,2,32'h0066ccff,0,0); wait(awvalid);
    submit(OP_BLIT,0,0,4,1,0,SOURCE_BASE,128);
    if (!busy || done || command_count != old_cmd+1) $fatal(1,"Busy FILL accepted START");
    stall_aw=0; await_done(0); check_memory();
    if (ar_count != old_ar) $fatal(1,"Busy FILL started a read");

    announce("BLIT busy covers its read-only phase and ignores a FILL START");
    old_cmd=command_count; stall_r=1;
    expect_copy(SOURCE_BASE,128,8,5,32,2);
    submit(OP_BLIT,8,5,32,2,0,SOURCE_BASE,128); wait(rready);
    submit(OP_FILL,0,0,4,1,0,0,0);
    if (!busy || done || command_count != old_cmd+1) $fatal(1,"Busy BLIT accepted START");
    stall_r=0; await_done(0); check_memory();

    announce("DONE waits for delayed final B response");
    stall_b=1; expect_fill(0,0,4,1,32'h00abcdef);
    submit(OP_FILL,0,0,4,1,32'h00abcdef,0,0); wait(bready);
    repeat (30) @(negedge clk);
    if (!busy || done) $fatal(1,"Public DONE before B");
    stall_b=0; await_done(0); check_memory();

    for (n=0; n<4; n=n+1) response_error_case(n);
    announce("FILL B error is forwarded without using stale BLIT error");
    initialize_memory(); old_cmd=command_count; old_ar=ar_count; old_aw=aw_count;
    inject_bresp=1;
    submit(OP_FILL,3,2,17,2,32'h00123456,0,0); await_done(32'h12); inject_bresp=0;
    first_pixels=MAX_BURST_BEATS*4-3; if(first_pixels>17) first_pixels=17;
    expect_fill(3,2,first_pixels,1,32'h00123456); check_memory();
    if (command_count != old_cmd+1 || ar_count != old_ar || aw_count != old_aw+1)
        $fatal(1,"FILL response-error count mismatch");
    copy_case("BLIT success clears inactive FILL error",SOURCE_BASE,128,0,0,8,1);
    fill_case("FILL success clears its own old B error",3,2,9,1,32'h00123456);

    for (n=2; n<5; n=n+1) timeout_case(OP_FILL,n);
    for (n=0; n<5; n=n+1) timeout_case(OP_BLIT,n);
    if (MAX_BURST_BEATS>1) fault_case(1);
    fault_case(0);
    fill_case("FILL works after platform reset",1,2,7,2,32'h00aabbcc);
    copy_case("BLIT works after platform reset",SOURCE_BASE,128,8,5,8,2);

    $display("PASS GRAPHICS: %0d cases, MAX_BURST_BEATS=%0d, OP_FILL=%0d, OP_BLIT=%0d",
        case_count,MAX_BURST_BEATS,OP_FILL,OP_BLIT);
    $finish;
end
initial begin #60000000; $fatal(1,"Global graphics test watchdog"); end
endmodule
