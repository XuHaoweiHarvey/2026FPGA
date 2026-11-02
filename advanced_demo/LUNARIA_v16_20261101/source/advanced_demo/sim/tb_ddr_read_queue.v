`timescale 1ns/1ps
// Independent client-handshake scoreboard. No DUT internal state is read.
module tb_ddr_read_queue;
parameter DEPTH=2;
reg clk=0, rst_n=0, enabled=1;
always #5 clk=~clk;
reg display_active=1, display_launch=0, display_flush=0;
reg [31:0] display_fifo_level=512;
reg [31:0] display_araddr=32'h10000000, blit_araddr=32'h20000000;
reg [7:0] display_arlen=0, blit_arlen=0;
reg display_arvalid=0, blit_arvalid=0, display_rready=1, blit_rready=1;
wire display_arready, blit_arready, display_rlast, blit_rlast;
wire raw_display_rvalid, raw_blit_rvalid;
wire [127:0] display_rdata, blit_rdata;
wire [3:0] display_rid, blit_rid;
wire [1:0] display_rresp, blit_rresp;
wire [31:0] araddr;
wire [7:0] arlen;
wire [3:0] arid, arcache, arqos;
wire [2:0] arsize, arprot;
wire [1:0] arburst;
wire arlock, arvalid, rready;
reg arready=0, rvalid=0, rlast=0;
reg [127:0] rdata=0;
reg [3:0] rid=0;
reg [1:0] rresp=0;
wire address_pending, read_active, owner_blit, busy, display_urgent, fault;
wire [31:0] fault_code, display_bursts, blit_bursts, display_beats, blit_beats;
wire [8:0] beats_left;
reg swap_responses;
initial swap_responses=$test$plusargs("SWAP_RESPONSES");
// Negative control corrupts the client-facing VALID routing only in this TB.
wire display_rvalid=swap_responses ? raw_blit_rvalid : raw_display_rvalid;
wire blit_rvalid=swap_responses ? raw_display_rvalid : raw_blit_rvalid;

ddr_read_arbiter #(.OUTSTANDING(DEPTH)) dut (
    .clk(clk), .rst_n(rst_n), .enabled(enabled),
    .display_active(display_active), .display_launch(display_launch),
    .display_flush(display_flush), .display_fifo_level(display_fifo_level),
    .display_araddr(display_araddr), .display_arlen(display_arlen),
    .display_arvalid(display_arvalid), .display_arready(display_arready),
    .display_rdata(display_rdata), .display_rid(display_rid), .display_rresp(display_rresp),
    .display_rlast(display_rlast), .display_rvalid(raw_display_rvalid), .display_rready(display_rready),
    .blit_araddr(blit_araddr), .blit_arlen(blit_arlen),
    .blit_arvalid(blit_arvalid), .blit_arready(blit_arready),
    .blit_rdata(blit_rdata), .blit_rid(blit_rid), .blit_rresp(blit_rresp),
    .blit_rlast(blit_rlast), .blit_rvalid(raw_blit_rvalid), .blit_rready(blit_rready),
    .araddr(araddr), .arlen(arlen), .arid(arid), .arsize(arsize), .arburst(arburst),
    .arcache(arcache), .arprot(arprot), .arlock(arlock), .arqos(arqos),
    .arvalid(arvalid), .arready(arready), .rdata(rdata), .rid(rid),
    .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready),
    .address_pending(address_pending), .read_active(read_active), .owner_blit(owner_blit),
    .busy(busy), .display_urgent(display_urgent), .fault(fault), .fault_code(fault_code),
    .beats_left(beats_left), .display_bursts(display_bursts), .blit_bursts(blit_bursts),
    .display_beats(display_beats), .blit_beats(blit_beats)
);

reg scoreboard=1;
reg model_active=0, model_owner=0, model_fault=0, allow_fault=0;
reg [31:0] model_addr=0, model_code=0;

integer qhead=0,qtail=0,cycle=0,max_inflight=0,returned=0;
integer lengths[0:2047];
reg own[0:2047];reg [31:0] addresses[0:2047];
reg [39:0] held_ar_payload;
reg held_ar=0, consumed=0,display_taken=0,blit_taken=0;
integer j,turn,expected_owner;
always @(posedge clk) begin
 cycle=cycle+1;consumed=rvalid&&rready;display_taken=display_arvalid&&display_arready;blit_taken=blit_arvalid&&blit_arready;
 if(rst_n && scoreboard) begin
  if(held_ar && (!arvalid || {araddr,arlen}!==held_ar_payload))$fatal(1,"stalled AR changed");
  held_ar=arvalid&&!arready;held_ar_payload={araddr,arlen};
  if(arvalid&&arready) begin
   if(qtail-qhead>=DEPTH)$fatal(1,"queue capacity exceeded");
   if(display_arready==blit_arready)$fatal(1,"ambiguous client handshake");
   own[qtail]=blit_arready;addresses[qtail]=araddr;lengths[qtail]=arlen+1;qtail=qtail+1;
   if(qtail-qhead>max_inflight)max_inflight=qtail-qhead;
  end
  if(rvalid) begin
   if(qhead==qtail)$fatal(1,"test unowned R");
   if(display_rvalid!==!own[qhead] || blit_rvalid!==own[qhead])$fatal(1,"response owner");
   if(rready!==(own[qhead]?blit_rready:display_rready))$fatal(1,"response backpressure");
   if((own[qhead]?blit_rdata:display_rdata)!==rdata)$fatal(1,"response data");
   if((own[qhead]?blit_rid:display_rid)!==rid || (own[qhead]?blit_rresp:display_rresp)!==rresp)$fatal(1,"response errors");
   if(rready) begin
    lengths[qhead]=lengths[qhead]-1;returned=returned+1;
    if(rlast)begin if(lengths[qhead]!=0)$fatal(1,"test length");qhead=qhead+1;end
   end
  end
 end else held_ar=0;
end
initial begin
 repeat(3)@(negedge clk);rst_n=1;arready=1;
 // Fill with both clients, no R at all. Display wins low-water priority.
 display_fifo_level=0;display_arvalid=1;blit_arvalid=1;
 for(j=0;j<DEPTH;j=j+1) begin
  display_arlen=j;blit_arlen=j;
  while(!arvalid)@(negedge clk);
  if(blit_arready)$fatal(1,"low-water priority lost");
  @(negedge clk);display_araddr=display_araddr+256;
 end
 repeat(5)@(negedge clk);if(arvalid)$fatal(1,"overbooked full queue");
 display_arvalid=0;blit_arvalid=0;display_fifo_level=700;
 while(qhead<qtail)begin
  rvalid=1;rlast=lengths[qhead]==1;rdata=addresses[qhead];
  @(negedge clk);
 end
 rvalid=0;repeat(3)@(negedge clk);
 // Independent accepted request scoreboard; random stalls and R errors.
 for(turn=0;turn<3000;turn=turn+1)begin
  if(!display_arvalid || display_taken)display_arvalid=turn<2700 && turn%5!=0;
  if(!blit_arvalid || blit_taken)blit_arvalid=turn<2700 && turn%7!=0;
  // Keep producer addresses constant so a held request is never mutated.
  display_arlen=3;blit_arlen=7;
  arready=turn%6!=0;
  display_rready=turn%7!=0;blit_rready=turn%11!=0;
  if(!rvalid || consumed)begin
   rvalid=qhead<qtail && turn%4!=0;
   if(rvalid)begin rlast=lengths[qhead]==1;rdata=addresses[qhead];rid=turn%19==0?3:0;rresp=turn%17==0?2:0;end
  end
  @(negedge clk);
 end
 display_arvalid=0;blit_arvalid=0;arready=1;display_rready=1;blit_rready=1;
 while(busy || qhead<qtail)begin
  rvalid=qhead<qtail;
  if(rvalid)begin rlast=lengths[qhead]==1;rdata=addresses[qhead];end
  @(negedge clk);
 end
 rvalid=0;
 if(fault || max_inflight!=DEPTH)$fatal(1,"unexpected fault or no concurrency");
 if(display_bursts+blit_bursts!=qtail || display_beats+blit_beats!=returned)$fatal(1,"counters");
 // Same-cycle first response is covered by legacy tests; queued mode also
 // checks the bypass directly after a platform reset.
 rst_n=0;@(negedge clk);qhead=0;qtail=0;rst_n=1;display_arlen=0;display_arvalid=1;
 while(!arvalid)@(negedge clk);
 rvalid=1;rlast=1;rdata=display_araddr;rid=0;rresp=0;
 @(negedge clk);display_arvalid=0;rvalid=0;
 if(busy || fault)$fatal(1,"same-cycle completion");
 scoreboard=0;
 // Fault paths are checked independently: ownership must remain pinned.
 for(turn=0;turn<2;turn=turn+1)begin
  rst_n=0;rvalid=0;display_arvalid=0;blit_arvalid=0;
  @(negedge clk);rst_n=1;display_arvalid=1;display_arlen=turn==0?3:0;
  while(!display_arready)@(negedge clk);
  @(negedge clk);display_arvalid=0;rvalid=1;rlast=turn==0;
  @(negedge clk);rvalid=0;
  if(!fault || fault_code!=2 || !busy)$fatal(1,"malformed RLAST did not fail stop");
  blit_arvalid=1;rvalid=1;rlast=1;
  repeat(4)begin
   @(negedge clk);
   if(arvalid || !display_rvalid || blit_rvalid)$fatal(1,"fault rerouted owner");
  end
 end
 // Exposed AR cannot be cancelled by disable/flush or an unexpected R.
 rst_n=0;rvalid=0;blit_arvalid=0;display_arvalid=0;arready=0;
 @(negedge clk);rst_n=1;blit_arvalid=1;blit_arlen=0;
 while(!arvalid)@(negedge clk);
 held_ar_payload={araddr,arlen};enabled=0;display_flush=1;display_launch=1;rvalid=1;
 @(negedge clk);rvalid=0;
 if(!fault || fault_code!=1 || rready)$fatal(1,"unexpected R handling");
 repeat(4)begin
  @(negedge clk);
  if(!arvalid || {araddr,arlen}!==held_ar_payload)$fatal(1,"fault cancelled AR");
 end
 arready=1;@(negedge clk);blit_arvalid=0;rvalid=1;rlast=1;
 #1;if(!blit_rvalid || !rready)$fatal(1,"accepted fault request lost owner");
 @(negedge clk);rvalid=0;rst_n=0;
 @(negedge clk);rst_n=1;enabled=1;display_flush=0;display_launch=0;
 if(busy || fault)$fatal(1,"reset did not clear fault");
 $display("PASS READ QUEUE depth=%0d: full queue, priority, concurrent owners, 3000 stalled cycles, RID/RRESP routing, counters, reset, immediate response",DEPTH);
 $finish;
end
initial begin #1000000;$fatal(1,"timeout");end
endmodule
