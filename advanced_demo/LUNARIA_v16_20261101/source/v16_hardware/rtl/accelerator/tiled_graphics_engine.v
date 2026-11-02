`timescale 1ns/1ps
// B-side command dispatcher; enabled in the formal double-buffered platform.
// START is the manager's final command_accept; ACCEPT reports local acceptance.
// C registers src_range_valid on that edge; CHECK_SOURCE samples it next cycle.
// Source addresses are absolute bytes; destination AW is relative to Back.
module tiled_graphics_engine #(
    parameter BATCH_SIZE=1024, IDLE_FLUSH_CYCLES=4096, MIN_TILE_COMMANDS=8,
    parameter TILE_WIDTH=128,TILE_HEIGHT=48,
    parameter FRAME_WIDTH = 1920, FRAME_HEIGHT = 1080, FRAME_STRIDE = 7680,
    parameter MAX_BURST_BEATS = 32, WATCHDOG_BITS = 27,
    parameter [31:0] OP_FILL = 32'd0, OP_BLIT = 32'd1,
    parameter [31:0] ERR_OPCODE = 32'h26,
    // Formal v5 enables opcode 2. Default off retains the v4 contract.
    // The key uses the accepted color[23:0]; X is ignored.
    parameter COLOR_KEY_ENABLE = 0,
    parameter [31:0] OP_COLOR_KEY = 32'd2,
    parameter ALPHA_ENABLE = 0,
    parameter ALPHA_STREAM_ENABLE = 0, ALPHA_SPRITE_CACHE_ENABLE = 0,
    parameter ALPHA_WIDE_CACHE_ENABLE = 0,
    parameter BEAM_ENABLE = 0,
    parameter ALPHA_OVERLAP_ENABLE = 0,
    parameter ALPHA_READ_AHEAD_ENABLE = 0,
    parameter [31:0] OP_ALPHA_BLEND = 32'd3
)(
    input wire clk, rst_n, enabled, start,
    input wire [31:0] op, x, y, width, height, color,
    input wire [31:0] src_addr, src_stride,
    input wire [31:0] back_base,
    input wire src_range_valid,
    input wire flush_request,
    output wire pending,
    output wire accept,
    output wire busy,
    output reg done,
    output reg [31:0] error_code, command_count,
    output wire [511:0] alpha_perf_counters,
    output wire [255:0] read_perf_counters,

    output wire [31:0] araddr,
    output wire [7:0] arlen,
    output wire arvalid,
    input wire arready,
    input wire [127:0] rdata,
    input wire [3:0] rid,
    input wire [1:0] rresp,
    input wire rlast, rvalid,
    output wire rready,

    output wire [31:0] awaddr,
    output wire [7:0] awlen,
    output wire awvalid,
    input wire awready,
    output wire [127:0] wdata,
    output wire [15:0] wstrb,
    output wire wlast, wvalid,
    input wire wready,
    input wire [3:0] bid,
    input wire [1:0] bresp,
    input wire bvalid,
    output wire bready
);
// Deferred commands never become externally idle until every tile B drains.
// The platform may dispatch more commands while pending, but must prohibit
// CPU ownership / swap until pending clears. Reset is platform reset only.
localparam IDLE=0,CHECK=1,SETUP=2,SCAN=3,FETCH=4,INTERSECT=5,
 LOAD_AR=6,LOAD_R=7,LAUNCH=8,RUN=9,STORE_AW=10,STORE_LOAD=11,
 STORE_W=12,STORE_B=13,NEXT_TILE=14,DIRECT_START=15,DIRECT_RUN=16,FAULT=17,DRAIN_TILE=18,
 REPLAY_FETCH=19,REPLAY_START=20,REPLAY_RUN=21;
reg [4:0] state;
// Alpha-only descriptors: geometry is validated before narrowing.
reg [95:0] commands[0:BATCH_SIZE-1];
reg [95:0] command_read;
reg [255:0] held;
wire [255:0] desc={32'd3,21'b0,command_read[84:74],21'b0,command_read[73:63],
 21'b0,command_read[62:52],21'b0,command_read[51:41],24'b0,command_read[40:33],
 (32'h01384000+{11'b0,command_read[20:0]}),20'b0,command_read[32:21]};
wire [20:0] held_source_offset=held[63:32]-32'h01384000;
reg [31:0] held_back,batch_back;
reg [31:0] min_x,min_y,max_x,max_y,tile_x,tile_y,tile_w,tile_h;
reg [31:0] cx,cy,cw,ch,cs,css,cc;
reg [15:0] count,index;
reg [15:0] idle_cycles;
reg direct_pending,tile_loaded;
reg held_source_valid;
reg [5:0] row;
reg [5:0] beat;
reg [31:0] row_address;
reg [127:0] tile_mem[0:TILE_WIDTH*TILE_HEIGHT/4-1];
reg [127:0] tile_ram_read;
wire [31:0] tile_ra,tile_wa;wire [127:0] tile_wd;wire tile_we;
wire [31:0] tra=tile_ra-tile_origin,twa=tile_wa-tile_origin;
reg [$clog2(TILE_WIDTH*TILE_HEIGHT/4)-1:0] tile_ri,tile_wi;
generate if(FRAME_STRIDE==7680)begin: physical_row_decode
 // 7680=15*512; 47 is the inverse of 15 modulo 64. Tiles are
 // 128 pixels wide and <=48 rows, so low bits decode without division.
 wire [5:0] rr=tra[14:9]*6'd47,wr=twa[14:9]*6'd47;
 always @*begin tile_ri={rr,tra[8:4]};tile_wi={wr,twa[8:4]};end
end else begin: generic_row_decode
 integer decode_row;
 always @*begin
  tile_ri=0;tile_wi=0;
  for(decode_row=0;decode_row<TILE_HEIGHT;decode_row=decode_row+1)begin
   if(tra>=decode_row*FRAME_STRIDE && tra<decode_row*FRAME_STRIDE+TILE_WIDTH*4)
    tile_ri=decode_row*(TILE_WIDTH/4)+((tra-decode_row*FRAME_STRIDE)>>4);
   if(twa>=decode_row*FRAME_STRIDE && twa<decode_row*FRAME_STRIDE+TILE_WIDTH*4)
    tile_wi=decode_row*(TILE_WIDTH/4)+((twa-decode_row*FRAME_STRIDE)>>4);
  end
 end
end endgenerate
reg [WATCHDOG_BITS-1:0] timeout_count;
wire stalled_bus=state==LOAD_AR || state==LOAD_R || state==STORE_AW || state==STORE_W || state==STORE_B;
wire progress=(arvalid&&arready)||(rvalid&&rready)||(awvalid&&awready)||(wvalid&&wready)||(bvalid&&bready);
wire [31:0] dop=desc[255:224],dx=desc[223:192],dy=desc[191:160],
 dw=desc[159:128],dh=desc[127:96],dc=desc[95:64],ds=desc[63:32],dss=desc[31:0];
wire [31:0] left=dx>tile_x?dx:tile_x, top=dy>tile_y?dy:tile_y;
wire [31:0] right=dx+dw<tile_x+tile_w?dx+dw:tile_x+tile_w;
wire [31:0] bottom=dy+dh<tile_y+tile_h?dy+dh:tile_y+tile_h;
wire [31:0] tile_origin=tile_y*FRAME_STRIDE+tile_x*4;
wire replay=state==REPLAY_START || state==REPLAY_RUN;
wire is_direct=state==DIRECT_START || state==DIRECT_RUN || replay;
wire [255:0] direct_desc=replay?desc:held;
wire core_start=state==LAUNCH || state==DIRECT_START || state==REPLAY_START;
wire core_busy,core_done;wire [31:0] core_error;
wire [31:0] ca,wa;wire [7:0] cl,wl;wire cav,crr,wav,wv,wlast_i,br;
wire [127:0] wd;wire [15:0] ws;
wire active_core=state==RUN || state==DIRECT_RUN || state==REPLAY_RUN;
wire [511:0] core_perf;
wire [255:0] core_read_perf;
reg [31:0] tile_perf[0:15],tile_read_perf[0:7];
reg tile_first_pending,tile_seen;
wire [15:0] tile_events={3'b0,
 (state==STORE_B && !bvalid),(state==STORE_W && !wready),
 (state==STORE_AW && !awready),(state==LOAD_R && !rvalid),
 (state==LOAD_AR && !arready),2'b0,(state==STORE_W && wready),
 ((state==LOAD_R || state==DRAIN_TILE) && rvalid),1'b0,
 (busy && !active_core && state!=IDLE && state!=CHECK),2'b0};
wire [7:0] tile_read_events={(state==LOAD_AR && arready),1'b0,
 (state==LOAD_R && tile_seen && !rvalid),1'b0,
 (tile_first_pending && !(state==LOAD_R && rvalid)),1'b0,
 (state==LOAD_AR && !arready),1'b0};
genvar p;
generate for(p=0;p<16;p=p+1)begin: tile_counters
 assign alpha_perf_counters[p*32+:32]=core_perf[p*32+:32]+tile_perf[p];
 always @(posedge clk or negedge rst_n)
  if(!rst_n)tile_perf[p]<=0;
  else if(tile_events[p])tile_perf[p]<=tile_perf[p]+1'b1;
end
for(p=0;p<8;p=p+1)begin: tile_read_counters
 assign read_perf_counters[p*32+:32]=core_read_perf[p*32+:32]+tile_read_perf[p];
 always @(posedge clk or negedge rst_n)
  if(!rst_n)tile_read_perf[p]<=0;
  else if(tile_read_events[p])tile_read_perf[p]<=tile_read_perf[p]+1'b1;
end endgenerate
always @(posedge clk or negedge rst_n)
 if(!rst_n)begin tile_first_pending<=0;tile_seen<=0;end
 else begin
  if(state==LOAD_AR && arready)begin tile_first_pending<=1;tile_seen<=0;end
  if(state==LOAD_R && rvalid)begin tile_first_pending<=0;tile_seen<=1;end
 end
assign pending=count!=0 || direct_pending;
assign busy=state!=IDLE;
assign accept=rst_n && enabled && start && state==IDLE;
assign araddr=state==LOAD_AR?batch_back+row_address:ca;
assign arlen=state==LOAD_AR?(tile_w>>2)-1:cl;
assign arvalid=state==LOAD_AR || (active_core && cav);
assign rready=state==LOAD_R || state==DRAIN_TILE || (active_core && crr);
assign awaddr=state==STORE_AW?row_address:wa;
assign awlen=state==STORE_AW?(tile_w>>2)-1:wl;
assign awvalid=state==STORE_AW || (is_direct && active_core && wav);
assign wdata=is_direct?wd:tile_ram_read;
assign wstrb=is_direct?ws:16'hffff;
assign wvalid=state==STORE_W || (is_direct && active_core && wv);
assign wlast=is_direct?wlast_i:beat==(tile_w>>2)-1;
assign bready=state==STORE_B || (is_direct && active_core && br);
graphics_engine #(.FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT),.FRAME_STRIDE(FRAME_STRIDE),
 .MAX_BURST_BEATS(MAX_BURST_BEATS),.WATCHDOG_BITS(WATCHDOG_BITS),.COLOR_KEY_ENABLE(COLOR_KEY_ENABLE),
 .ALPHA_ENABLE(ALPHA_ENABLE),.ALPHA_STREAM_ENABLE(ALPHA_STREAM_ENABLE),.ALPHA_SPRITE_CACHE_ENABLE(ALPHA_SPRITE_CACHE_ENABLE),
 .ALPHA_WIDE_CACHE_ENABLE(ALPHA_WIDE_CACHE_ENABLE),.BEAM_ENABLE(BEAM_ENABLE),
 .ALPHA_OVERLAP_ENABLE(ALPHA_OVERLAP_ENABLE),.ALPHA_READ_AHEAD_ENABLE(ALPHA_READ_AHEAD_ENABLE),.TILE_PORT_ENABLE(1)) core(
 .clk(clk),.rst_n(rst_n),.enabled(1'b1),.start(core_start),
 .tile_local(!is_direct),.tile_read_data(tile_ram_read),.tile_read_address(tile_ra),
 .tile_write_address(tile_wa),.tile_write_data(tile_wd),.tile_write_enable(tile_we),
 .op(is_direct?direct_desc[255:224]:32'd3),.x(is_direct?direct_desc[223:192]:cx),.y(is_direct?direct_desc[191:160]:cy),
 .width(is_direct?direct_desc[159:128]:cw),.height(is_direct?direct_desc[127:96]:ch),.color(is_direct?direct_desc[95:64]:cc),
 .src_addr(is_direct?direct_desc[63:32]:cs),.src_stride(is_direct?direct_desc[31:0]:css),
 .back_base(is_direct&&!replay?held_back:batch_back),.src_range_valid(is_direct&&!replay?held_source_valid:1'b1),.busy(core_busy),.done(core_done),.error_code(core_error),
 .alpha_perf_counters(core_perf),.read_perf_counters(core_read_perf),
 .araddr(ca),.arlen(cl),.arvalid(cav),.arready(active_core&&arready),
 .rdata(rdata),.rid(rid),.rresp(rresp),.rlast(rlast),.rvalid(active_core&&rvalid),.rready(crr),
 .awaddr(wa),.awlen(wl),.awvalid(wav),.awready(active_core&&is_direct&&awready),
 .wdata(wd),.wstrb(ws),.wlast(wlast_i),.wvalid(wv),.wready(active_core&&is_direct&&wready),
 .bid(bid),.bresp(bresp),.bvalid(active_core&&is_direct&&bvalid),.bready(br));
// One synchronous read and one synchronous write port, with explicit muxes.
// The mutually exclusive tile load/render/store phases share physical BRAM.
wire storing=state==STORE_LOAD || state==STORE_W;
wire [$clog2(TILE_WIDTH*TILE_HEIGHT/4)-1:0] ram_read_address=storing ?
 (row*(TILE_WIDTH/4)+(state==STORE_W && wready && !wlast ? beat+1:beat)) : tile_ri;
wire load_store=state==LOAD_R && rvalid && rready;
wire [$clog2(TILE_WIDTH*TILE_HEIGHT/4)-1:0] ram_write_address=load_store ? row*(TILE_WIDTH/4)+beat : tile_wi;
wire [127:0] ram_write_data=load_store?rdata:tile_wd;
always @(posedge clk)begin
 command_read<=commands[index[$clog2(BATCH_SIZE)-1:0]];
 tile_ram_read<=tile_mem[ram_read_address];
 if(load_store || tile_we)tile_mem[ram_write_address]<=ram_write_data;
end
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  state<=IDLE;count<=0;index<=0;done<=0;error_code<=0;command_count<=0;idle_cycles<=0;
  direct_pending<=0;held<=0;held_back<=0;batch_back<=0;held_source_valid<=0;
  min_x<=0;min_y<=0;max_x<=0;max_y<=0;tile_x<=0;tile_y<=0;tile_w<=0;tile_h<=0;tile_loaded<=0;
  cx<=0;cy<=0;cw<=0;ch<=0;cs<=0;css<=0;cc<=0;row<=0;beat<=0;row_address<=0;timeout_count<=0;

 end else begin
  if(!stalled_bus || progress)timeout_count<=0;
  else if(!(&timeout_count))timeout_count<=timeout_count+1'b1;
  if(stalled_bus && (&timeout_count) && error_code==0)error_code<=32'h24;
  case(state)
  IDLE:begin
   if(accept)begin
    held<={op,x,y,width,height,color,src_addr,src_stride};held_back<=back_base;
    done<=0;error_code<=0;command_count<=command_count+1;idle_cycles<=0;state<=CHECK;
   end else if(count!=0)begin
    if(flush_request || idle_cycles==IDLE_FLUSH_CYCLES-1 || count==BATCH_SIZE)state<=SETUP;
    else idle_cycles<=idle_cycles+1;
   end
  end
  CHECK:begin
   held_source_valid<=src_range_valid;
   // Only immutable-atlas straight Alpha rectangles are deferred. Other
   // operations are barriers, executed unchanged after the batch is drained.
   if(ALPHA_ENABLE && held[255:224]==3 && src_range_valid && held[159:128]!=0 && held[127:96]!=0 &&
      {1'b0,held[223:192]}+{1'b0,held[159:128]}<=FRAME_WIDTH &&
      {1'b0,held[191:160]}+{1'b0,held[127:96]}<=FRAME_HEIGHT &&
      held[193:192]==0 && held[129:128]==0 && held[35:32]==0 && held[3:0]==0 &&
      held[63:32]>=32'h01384000 &&
      held[63:32]<32'h014b0000 && held[31:0]==2560 && held_back[11:0]==0 &&
      (count==0 || held_back==batch_back) && count<BATCH_SIZE)begin
    commands[count]<={11'b0,held[202:192],held[170:160],held[138:128],held[106:96],held[71:64],held[11:0],held_source_offset};count<=count+1;done<=1;state<=IDLE;
    if(count==0)begin min_x<=held[223:192]& ~(TILE_WIDTH-1);min_y<=held[191:160];max_x<=held[223:192]+held[159:128];max_y<=held[191:160]+held[127:96];batch_back<=held_back;end
    else begin
     if(held[223:192]<min_x)min_x<=held[223:192]& ~(TILE_WIDTH-1);
     if(held[191:160]<min_y)min_y<=held[191:160];
     if(held[223:192]+held[159:128]>max_x)max_x<=held[223:192]+held[159:128];
     if(held[191:160]+held[127:96]>max_y)max_y<=held[191:160]+held[127:96];
    end
   end else begin direct_pending<=1;state<=count!=0?SETUP:DIRECT_START;end
  end
  SETUP:begin
   tile_x<=min_x;tile_y<=min_y;index<=0;
   state<=count<MIN_TILE_COMMANDS?REPLAY_FETCH:SCAN;
  end
  SCAN:begin
   tile_w<=max_x-tile_x<TILE_WIDTH?max_x-tile_x:TILE_WIDTH;tile_h<=max_y-tile_y<TILE_HEIGHT?max_y-tile_y:TILE_HEIGHT;
   index<=0;tile_loaded<=0;state<=FETCH;
  end
  FETCH:state<=INTERSECT;
  INTERSECT:begin
   if(left<right && top<bottom)begin
    cx<=left;cy<=top;cw<=right-left;ch<=bottom-top;cc<=dc;css<=2560;
    cs<=ds+(top-dy)*2560+(left-dx)*4;
    if(!tile_loaded)begin row<=0;beat<=0;row_address<=tile_origin;state<=LOAD_AR;end
    else state<=LAUNCH;
   end else if(index+1<count)begin index<=index+1;state<=FETCH;end
   else if(tile_loaded)begin row<=0;beat<=0;row_address<=tile_origin;state<=STORE_AW;end
   else state<=NEXT_TILE;
  end
  LOAD_AR:if(arready)begin beat<=0;state<=LOAD_R;end
  LOAD_R:if(rvalid)begin
   if(rid!=0 || rresp!=0 || rlast!=(beat==(tile_w>>2)-1) || error_code!=0)begin
    if(error_code==0)error_code<=32'h22;state<=rlast?FAULT:DRAIN_TILE;end
   else if(rlast)begin
    if(row+1==tile_h)begin tile_loaded<=1;state<=LAUNCH;end
    else begin row<=row+1;row_address<=row_address+FRAME_STRIDE;state<=LOAD_AR;end
   end else beat<=beat+1;
  end
  LAUNCH:state<=RUN;
  RUN:begin
   if(core_error!=0)begin error_code<=core_error;if(!core_busy)state<=FAULT;end
   else if(core_done&&!core_busy)begin
    if(index+1<count)begin index<=index+1;state<=FETCH;end
    else begin row<=0;beat<=0;row_address<=tile_origin;state<=STORE_AW;end
   end
  end
  STORE_AW:if(awready)begin beat<=0;state<=STORE_LOAD;end
  STORE_LOAD:state<=STORE_W;
  STORE_W:if(wready)begin if(wlast)state<=STORE_B;else beat<=beat+1;end
  STORE_B:if(bvalid)begin
   if(bid!=0 || bresp!=0 || error_code!=0)begin if(error_code==0)error_code<=32'h23;state<=FAULT;end
   else if(row+1==tile_h)state<=NEXT_TILE;
   else begin row<=row+1;row_address<=row_address+FRAME_STRIDE;state<=STORE_AW;end
  end
  NEXT_TILE:begin
   if(tile_x+tile_w<max_x)begin tile_x<=tile_x+TILE_WIDTH;state<=SCAN;end
   else if(tile_y+tile_h<max_y)begin tile_x<=min_x;tile_y<=tile_y+TILE_HEIGHT;state<=SCAN;end
   else begin count<=0;state<=direct_pending?DIRECT_START:IDLE;done<=!direct_pending;end
  end
  DIRECT_START:state<=DIRECT_RUN;
  // Small batches retain the ordinary sprite path: loading a mostly empty
  // tile would otherwise cost more DDR traffic than the sprites themselves.
  REPLAY_FETCH:state<=REPLAY_START;
  REPLAY_START:state<=REPLAY_RUN;
  REPLAY_RUN:begin
   if(core_error!=0)begin error_code<=core_error;if(!core_busy)state<=FAULT;end
   else if(core_done&&!core_busy)begin
    if(index+1<count)begin index<=index+1;state<=REPLAY_FETCH;end
    else begin count<=0;state<=direct_pending?DIRECT_START:IDLE;done<=!direct_pending;end
   end
  end
  DIRECT_RUN:begin
   // Preserve the immediate executor's contract, including validation errors
   // that retire without issuing AXI. It retains ownership while draining.
   if(core_error!=0)error_code<=core_error;
   if(core_done&&!core_busy)begin direct_pending<=0;done<=1;state<=IDLE;end
  end
  DRAIN_TILE:if(rvalid&&rlast)state<=FAULT;
  FAULT:state<=FAULT;
  default:begin state<=FAULT;error_code<=32'h25;end
  endcase
 end
end
// synthesis translate_off
initial begin
 if(TILE_WIDTH!=128 || TILE_HEIGHT>48 || TILE_HEIGHT<1 || FRAME_WIDTH>2047 || FRAME_HEIGHT>2047 || FRAME_STRIDE%512!=0 || BATCH_SIZE>1024)
  $fatal(1,"Unsupported tile geometry/capacity");
end
always @(posedge clk)if(rst_n && tile_we && (twa>=TILE_HEIGHT*FRAME_STRIDE || (twa%FRAME_STRIDE)>=TILE_WIDTH*4))
 $fatal(1,"tile write escaped local RAM");
// synthesis translate_on
endmodule
