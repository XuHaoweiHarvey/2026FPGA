`timescale 1ns/1ps
// B + the existing real buffer_manager. C's source-window validator and DDR
// read arbiter are NOT implemented here; range_ok is the C-side contract input.
module tb_graphics_contract;
localparam [31:0] FRONT_BASE=32'h01000000, BACK_BASE=32'h00800000;
reg clk=0, rst_n=0, request=0, range_ok=1;
reg registered_range_ok=0;
always #5 clk=~clk;
reg [31:0] op=0;
// FILL exercises partial strobes; BLIT needs aligned multi-beat geometry.
wire [31:0] command_x=op==1 ? 32'd0 : 32'd3;
wire [31:0] command_width=op==1 ? 32'd32 : 32'd9;
reg swap_request=0, boundary_tick=0;
wire manager_accept, accept, busy, done, owned, pending, swap_done;
wire front_index, back_index, front_valid, draw_ready, reader_flush, reader_launch;
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
reg early_rlast=0;
reg no_axi_expected=0;
integer cases=0;

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) registered_range_ok<=0;
    else if(manager_accept) registered_range_ok<=range_ok;
end

buffer_manager #(.BUFFER0_BASE(FRONT_BASE), .BUFFER1_BASE(BACK_BASE)) manager (
    .clk(clk), .rst_n(rst_n), .init_done(1'b1), .cmd_request(request),
    .writer_busy(busy), .writer_done(done), .writer_error(error_code),
    .swap_request(swap_request), .clear_done(1'b0),
    .boundary_tick(boundary_tick), .blank_active(1'b1),
    .reader_safe(1'b1), .reader_fifo_empty(1'b1),
    .command_accept(manager_accept), .draw_ready(draw_ready), .writer_owned(owned),
    .front_index(front_index), .back_index(back_index), .front_valid(front_valid),
    .swap_pending(pending), .swap_done(swap_done), .front_base(front_base),
    .back_base(back_base), .command_base(command_base), .reader_base(reader_base),
    .reader_flush(reader_flush), .reader_launch(reader_launch),
    .boundary_count(boundary_count), .swap_count(swap_count),
    .missed_boundary_count(missed_boundary_count)
);

graphics_engine #(.FRAME_WIDTH(64), .FRAME_HEIGHT(48), .FRAME_STRIDE(256),
    .WATCHDOG_BITS(9)) dut (
    .clk(clk), .rst_n(rst_n), .enabled(1'b1), .start(manager_accept), .accept(accept),
    .op(op), .x(command_x), .y(32'd2), .width(command_width), .height(32'd1),
    .color(32'h00abcdef), .src_addr(FRONT_BASE), .src_stride(32'd256),
    .src_range_valid(registered_range_ok), .busy(busy), .done(done),
    .error_code(error_code), .command_count(command_count),
    .araddr(araddr), .arlen(arlen), .arvalid(arvalid), .arready(arready),
    .rdata(rdata), .rid(rid), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready),
    .awaddr(awaddr), .awlen(awlen), .awvalid(awvalid), .awready(awready),
    .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
    .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready)
);

blit_test_memory #(.FRAME_WIDTH(64), .FRAME_HEIGHT(48), .ALLOW_PARTIAL_STROBES(1),
    .SOURCE_BASE(FRONT_BASE), .BACK_BASE(BACK_BASE)) memory (
    .clk(clk), .rst_n(rst_n),
    .stall_ar(1'b0), .stall_r(1'b0), .stall_aw(1'b0), .stall_w(1'b0), .stall_b(1'b0),
    .inject_rresp(1'b0), .inject_rid(1'b0), .inject_bresp(1'b0), .inject_bid(1'b0),
    .early_rlast(early_rlast), .missing_rlast(1'b0),
    .araddr(araddr), .arlen(arlen), .arvalid(arvalid), .arready(arready),
    .rdata(rdata), .rid(rid), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready),
    .awaddr(command_base+awaddr), .awlen(awlen), .awvalid(awvalid), .awready(awready),
    .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
    .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
    .ar_count(ar_count), .r_count(r_count), .aw_count(aw_count),
    .w_count(w_count), .b_count(b_count), .idle(memory_idle)
);

always @(posedge clk) if (rst_n) begin
    if (manager_accept !== accept)
        $fatal(1,"B did not acknowledge the manager's final accept");
    if (busy && !owned) $fatal(1,"Active B command lost Back ownership");
    if (owned && command_base !== BACK_BASE) $fatal(1,"Back base changed while owned");
    if (no_axi_expected && (arvalid || awvalid || wvalid))
        $fatal(1,"Rejected command exposed AXI");
end

task announce;
input [8*100-1:0] name;
begin cases=cases+1; $display("CONTRACT %0d: %0s",cases,name); end
endtask

task reset_platform;
begin
    @(negedge clk); rst_n=0; request=0; swap_request=0; boundary_tick=0;
    early_rlast=0; no_axi_expected=0; range_ok=1;
    repeat(4) @(negedge clk);
    rst_n=1; repeat(3) @(negedge clk);
    if (!draw_ready || busy || done || owned || pending || command_count!=0 || error_code!=0)
        $fatal(1,"Platform reset did not clear command/ownership state");
end
endtask

task issue;
input [31:0] operation;
input valid_source;
integer before_count;
begin
    @(negedge clk); op=operation; range_ok=valid_source; request=1;
    before_count=command_count;
    #1; if (!manager_accept || !accept) $fatal(1,"Legal request was not accepted");
    @(negedge clk); request=0;
    if (!owned || command_count!=before_count+1)
        $fatal(1,"Accepted command did not acquire Back/count once");
end
endtask

task await_release;
input [31:0] wanted_error;
integer cycles;
begin
    cycles=0;
    while (!done || busy || owned) begin
        @(negedge clk); cycles=cycles+1;
        if(cycles>1000) $fatal(1,"Command did not release Back: %h",error_code);
    end
    if(error_code!==wanted_error || !memory_idle)
        $fatal(1,"Wrong released result: %h expected %h",error_code,wanted_error);
end
endtask

task request_swap_and_boundary;
begin
    @(negedge clk); swap_request=1;
    @(negedge clk); swap_request=0; boundary_tick=1;
    @(negedge clk); boundary_tick=0;
    repeat(20) @(negedge clk);
    if(!pending || swap_count!=0 || front_base!==FRONT_BASE || back_base!==BACK_BASE)
        $fatal(1,"Error/fault allowed a swap to commit");
end
endtask

integer before_count;
initial begin
    reset_platform();
    announce("invalid source counts, returns 0x21, releases Back without AXI");
    no_axi_expected=1;
    issue(1,0); range_ok=1; await_release(32'h21);
    if(ar_count!=0 || aw_count!=0) $fatal(1,"Source rejection touched memory");
    no_axi_expected=0;

    announce("non-aligned FILL ignores BLIT range restriction and clears 0x21");
    issue(0,0); await_release(0);

    announce("illegal opcode counts, returns sticky 0x26 and releases Back");
    no_axi_expected=1;
    issue(32'hffffffff,0); await_release(32'h26);
    repeat(8) @(negedge clk);
    if(error_code!=32'h26 || !done || busy || owned)
        $fatal(1,"Unaccepted/idle cycles cleared the opcode error");
    no_axi_expected=0;

    announce("a genuinely accepted FILL clears the opcode error");
    issue(0,0); await_release(0);

    announce("pending swap rejects new request without clearing 0x26");
    no_axi_expected=1;
    issue(32'hffffffff,0); await_release(32'h26);
    before_count=command_count; request_swap_and_boundary();
    @(negedge clk); request=1; op=0;
    #1; if(accept || manager_accept) $fatal(1,"Pending swap accepted a request");
    @(negedge clk); request=0;
    if(command_count!=before_count || error_code!=32'h26 || owned)
        $fatal(1,"Rejected request changed the sticky result/count");

    // Fault behavior uses the same manager and a fresh platform reset.
    reset_platform();
    announce("0x25 retains Back, blocks new commands and prevents swap commit");
    early_rlast=1;
    issue(1,1);
    wait(error_code==32'h25);
    @(negedge clk);
    before_count=command_count; request_swap_and_boundary();
    request=1; op=0;
    repeat(4) @(negedge clk);
    request=0;
    if(!busy || !owned || done || command_count!=before_count || error_code!=32'h25)
        $fatal(1,"Protocol fault lost ownership or accepted another command");

    announce("platform reset clears fault and permits FILL again");
    reset_platform(); issue(0,0); await_release(0);
    $display("PASS GRAPHICS CONTRACT: %0d cases; real manager, mocked range/DDR",cases);
    $finish;
end
initial begin #2000000; $fatal(1,"Global graphics contract watchdog"); end
endmodule
