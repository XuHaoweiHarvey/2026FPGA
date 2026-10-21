`timescale 1ns/1ps
// Independent client-handshake scoreboard. No DUT internal state is read.
module tb_ddr_read_arbiter;
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

ddr_read_arbiter dut (
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

reg model_active=0, model_owner=0, model_fault=0, allow_fault=0;
reg [31:0] model_addr=0, model_code=0;
integer model_left=0, model_display_bursts=0, model_blit_bursts=0;
integer model_display_beats=0, model_blit_beats=0;
integer all_bursts=0, all_beats=0, cases=0, request_tag=0;
reg held_ar=0, held_display_r=0, held_blit_r=0;
reg [39:0] held_address=0;
reg [134:0] held_display_payload=0, held_blit_payload=0;
reg af, rf, bad_last;
always @(posedge clk) begin
    if(!rst_n) begin
        model_active=0; model_owner=0; model_fault=0; model_code=0; model_addr=0; model_left=0;
        model_display_bursts=0; model_blit_bursts=0; model_display_beats=0; model_blit_beats=0;
        held_ar=0; held_display_r=0; held_blit_r=0;
    end else begin
        if(held_ar && (!arvalid || {araddr,arlen}!==held_address))
            $fatal(1,"Exposed AR changed under backpressure");
        if(held_display_r && (!display_rvalid ||
            {display_rdata,display_rid,display_rresp,display_rlast}!==held_display_payload))
            $fatal(1,"Display R changed under backpressure");
        if(held_blit_r && (!blit_rvalid ||
            {blit_rdata,blit_rid,blit_rresp,blit_rlast}!==held_blit_payload))
            $fatal(1,"BLIT R changed under backpressure");
        if(display_arready && blit_arready) $fatal(1,"Both clients received ARREADY");
        if(arvalid && {arid,arsize,arburst,arcache,arprot,arlock,arqos}!=={4'd0,3'd4,2'd1,4'd3,3'd2,1'b0,4'd0})
            $fatal(1,"Wrong DDR read sideband");
        af=arvalid && arready; rf=rvalid && rready;
        if(af) begin
            if(model_active) $fatal(1,"More than one global outstanding read");
            if((display_arvalid && display_arready)==(blit_arvalid && blit_arready))
                $fatal(1,"DDR AR did not match exactly one client handshake");
            model_owner=blit_arvalid && blit_arready;
            if(araddr!==(model_owner ? blit_araddr : display_araddr) ||
               arlen!==(model_owner ? blit_arlen : display_arlen))
                $fatal(1,"DDR AR payload differs from accepted client");
            model_active=1; model_left=arlen+1; model_addr=araddr;
            if(model_owner) model_blit_bursts=model_blit_bursts+1;
            else model_display_bursts=model_display_bursts+1;
            all_bursts=all_bursts+1;
        end else if((display_arvalid && display_arready) || (blit_arvalid && blit_arready))
            $fatal(1,"Client AR accepted without DDR handshake");

        if(model_active) begin
            if(display_rvalid!==(rvalid && !model_owner) || blit_rvalid!==(rvalid && model_owner))
                $fatal(1,"Read response routed to wrong master");
            if(rready!==(model_owner ? blit_rready : display_rready))
                $fatal(1,"RREADY came from the wrong client");
            if(model_owner) begin
                if({display_rdata,display_rid,display_rresp,display_rlast}!==135'b0)
                    $fatal(1,"BLIT response payload leaked to display");
                if(rvalid && {blit_rdata,blit_rid,blit_rresp,blit_rlast}!=={rdata,rid,rresp,rlast})
                    $fatal(1,"BLIT response payload changed");
            end else begin
                if({blit_rdata,blit_rid,blit_rresp,blit_rlast}!==135'b0)
                    $fatal(1,"Display response payload leaked to BLIT");
                if(rvalid && {display_rdata,display_rid,display_rresp,display_rlast}!=={rdata,rid,rresp,rlast})
                    $fatal(1,"Display response payload changed");
            end
        end else begin
            if(rready || display_rvalid || blit_rvalid)
                $fatal(1,"Unowned response was accepted or routed");
            if(rvalid && !model_fault) begin
                if(!allow_fault) $fatal(1,"Unexpected unowned R in normal test");
                model_fault=1; model_code=1;
            end
        end
        if(rf) begin
            all_beats=all_beats+1;
            if(model_owner) model_blit_beats=model_blit_beats+1;
            else model_display_beats=model_display_beats+1;
            bad_last=model_left==0 || rlast!=(model_left==1);
            if(bad_last && !model_fault) begin
                if(!allow_fault) $fatal(1,"Malformed RLAST in normal test");
                model_fault=1; model_code=2;
            end
            if(!model_fault && rlast && model_left==1) model_active=0;
            if(model_left>0) model_left=model_left-1;
        end
        held_ar=arvalid && !arready; held_address={araddr,arlen};
        held_display_r=display_rvalid && !display_rready;
        held_blit_r=blit_rvalid && !blit_rready;
        held_display_payload={display_rdata,display_rid,display_rresp,display_rlast};
        held_blit_payload={blit_rdata,blit_rid,blit_rresp,blit_rlast};
    end
end

always @(negedge clk) begin
    #1;
    if(rst_n) begin
    if(fault!==model_fault || fault_code!==model_code || read_active!==model_active)
        $fatal(1,"Fault/ownership status differs from accepted transactions");
    if(model_active && (owner_blit!==model_owner || beats_left!==model_left))
        $fatal(1,"In-flight owner/count changed or wrapped");
    if(display_bursts!==model_display_bursts || blit_bursts!==model_blit_bursts ||
       display_beats!==model_display_beats || blit_beats!==model_blit_beats)
        $fatal(1,"Read service counters disagree with handshakes: AR=%0d/%0d expected=%0d/%0d R=%0d/%0d expected=%0d/%0d",
            display_bursts,blit_bursts,model_display_bursts,model_blit_bursts,
            display_beats,blit_beats,model_display_beats,model_blit_beats);
    end
end

task announce;
input [8*110-1:0] name;
begin cases=cases+1; $display("READ ARBITER %0d: %0s",cases,name); end
endtask

task reset_platform;
begin
    @(negedge clk); rst_n=0;
    display_arvalid=0; blit_arvalid=0; arready=0; rvalid=0; rlast=0;
    display_rready=1; blit_rready=1; enabled=1;
    display_active=1; display_launch=0; display_flush=0; display_fifo_level=512; allow_fault=0;
    repeat(3) @(negedge clk);
    rst_n=1; repeat(3) @(negedge clk);
    if(busy || fault || display_arready || blit_arready || rready)
        $fatal(1,"Platform reset left ownership or a grant");
end
endtask

task requests;
input d, b;
input [7:0] dl, bl;
begin
    @(negedge clk); display_arvalid=d; blit_arvalid=b;
    display_arlen=dl; blit_arlen=bl;
    display_araddr=32'h10000000+request_tag*4096;
    blit_araddr=32'h20000000+request_tag*4096;
    request_tag=request_tag+1;
end
endtask

task wait_address;
input wanted_owner;
integer cycles;
begin
    cycles=0;
    while(!arvalid) begin
        @(negedge clk); cycles=cycles+1;
        if(cycles>20) $fatal(1,"Read requester made no progress");
    end
    if(araddr!==(wanted_owner ? blit_araddr : display_araddr) ||
       arlen!==(wanted_owner ? blit_arlen : display_arlen))
        $fatal(1,"Wrong arbitration priority: expected owner=%b addr=%h",wanted_owner,araddr);
end
endtask

task accept_address;
input wanted_owner;
begin
    wait_address(wanted_owner);
    arready=1;
    @(negedge clk); arready=0;
    if(!read_active || arvalid || owner_blit!==wanted_owner)
        $fatal(1,"AR handshake did not establish the requested owner");
end
endtask

function [127:0] data_word;
input [31:0] address;
input integer beat;
begin data_word={address^32'h12345678,32'h9abcdef0^beat,address+beat*32'd16,32'h55aa33cc+beat}; end
endfunction

task send_beat;
input integer beat;
input last;
input [3:0] response_id;
input [1:0] response_status;
input integer stalls;
begin
    @(negedge clk);
    rdata=data_word(model_addr,beat); rid=response_id; rresp=response_status; rlast=last; rvalid=1;
    if(model_owner) blit_rready=stalls==0; else display_rready=stalls==0;
    repeat(stalls) @(negedge clk);
    if(model_owner) blit_rready=1; else display_rready=1;
    @(negedge clk); rvalid=0;
end
endtask

task send_burst;
input [3:0] response_id;
input [1:0] response_status;
input integer stall_pattern;
integer beat, length;
begin
    length=model_left;
    for(beat=0;beat<length;beat=beat+1) begin
        if(beat%3==1) @(negedge clk); // DDR RVALID gaps, independent of READY.
        send_beat(beat,beat==length-1,response_id,response_status,
            stall_pattern==0 ? 0 : beat%4);
    end
    if(!model_fault && busy) $fatal(1,"Legal final R did not retire the owner");
end
endtask

integer i, j, random_count=0, seed=32'h6343a19b, delay_cycles;
reg [31:0] random_bits;
reg random_display, random_blit, expected_owner, expected_preference, expected_healthy;
reg [7:0] random_display_len, random_blit_len;
initial begin
    if($test$plusargs("VCD")) begin
        $dumpfile("read_arbiter.vcd"); $dumpvars(0,tb_ddr_read_arbiter);
    end
    reset_platform();
    announce("idle and reset have no phantom owner");
    repeat(4) @(negedge clk);

    announce("display 128-beat burst passes every lane and ID0 sideband");
    requests(1,0,127,31); accept_address(0); display_arvalid=0;
    send_burst(0,0,1);

    announce("BLIT 32-beat burst ignores non-owner display RREADY=0");
    display_rready=0;
    requests(0,1,127,31); accept_address(1); blit_arvalid=0;
    send_burst(0,0,1); display_rready=1;

    announce("display R backpressure cannot be overridden by ready BLIT");
    requests(1,0,0,0); accept_address(0); display_arvalid=0;
    send_beat(0,1,0,0,6);

    announce("stalled BLIT AR survives new urgent display, flush, launch and disabled enable");
    requests(0,1,0,3); wait_address(1);
    display_arvalid=1; display_fifo_level=0; display_launch=1; display_flush=1; enabled=0;
    repeat(6) @(negedge clk);
    accept_address(1); display_arvalid=0; blit_arvalid=0;
    send_burst(0,0,1);
    display_launch=0; display_flush=0; enabled=1; display_fifo_level=512;

    announce("enabled blocks only new grants and resumes without resetting service state");
    enabled=0; requests(1,1,0,0);
    repeat(4) @(negedge clk);
    if(arvalid || busy) $fatal(1,"Disabled idle arbiter selected a request");
    enabled=1; accept_address(0); display_arvalid=0; blit_arvalid=0; send_burst(0,0,0);

    announce("low water overrides a previously earned BLIT turn");
    display_fifo_level=384;
    requests(1,1,1,1); accept_address(0); display_arvalid=0; blit_arvalid=0; send_burst(0,0,0);
    announce("between LOW and HIGH retains urgent display priority");
    display_fifo_level=448;
    requests(1,1,1,1); accept_address(0); display_arvalid=0; blit_arvalid=0; send_burst(0,0,0);
    announce("HIGH restores the waiting BLIT turn");
    display_fifo_level=512; repeat(3) @(negedge clk);
    requests(1,1,1,1); accept_address(1); display_arvalid=0; blit_arvalid=0; send_burst(0,0,0);

    announce("between HIGH and LOW keeps healthy rotation after the FIFO falls");
    requests(1,0,0,0); accept_address(0); display_arvalid=0; send_burst(0,0,0);
    display_fifo_level=448;
    requests(1,1,0,0); accept_address(1); display_arvalid=0; blit_arvalid=0; send_burst(0,0,0);

    announce("new frame launch immediately prioritizes display at a healthy FIFO level");
    display_fifo_level=512; repeat(3) @(negedge clk);
    requests(1,0,0,0); accept_address(0); display_arvalid=0; send_burst(0,0,0);
    display_launch=1;
    requests(1,1,0,0); accept_address(0); display_arvalid=0; blit_arvalid=0; send_burst(0,0,0);
    display_launch=0;

    announce("low water without a display request still permits BLIT progress");
    display_fifo_level=0;
    requests(0,1,0,0); accept_address(1); blit_arvalid=0; send_burst(0,0,0);

    announce("continuous healthy competition rotates 128-beat display and 32-beat BLIT");
    reset_platform(); requests(1,1,127,31);
    for(i=0;i<20;i=i+1) begin
        accept_address(i%2); send_burst(0,0,1);
    end
    display_arvalid=0; blit_arvalid=0;

    announce("inactive display does not force urgent priority");
    display_active=0; display_fifo_level=0;
    requests(1,1,0,0); accept_address(0); display_arvalid=0; blit_arvalid=0; send_burst(0,0,0);
    requests(1,1,0,0); accept_address(1); display_arvalid=0; blit_arvalid=0; send_burst(0,0,0);

    announce("full AXI 256-beat length uses a nine-bit remaining counter");
    requests(1,0,255,0); accept_address(0); display_arvalid=0; send_burst(0,0,1);

    announce("RID/RRESP errors reach only their owner and a well-sized burst retires");
    requests(1,0,2,0); accept_address(0); display_arvalid=0; send_burst(4'h5,2'b10,1);
    requests(0,1,0,2); accept_address(1); blit_arvalid=0; send_burst(4'h9,2'b11,1);

    announce("same-cycle AR and final single-beat R, display and BLIT");
    for(i=0;i<2;i=i+1) begin
        requests(i==0,i==1,0,0); wait_address(i);
        arready=1; rvalid=1; rlast=1; rid=0; rresp=0;
        rdata=data_word(i==1 ? blit_araddr : display_araddr,0);
        @(negedge clk); arready=0; rvalid=0; display_arvalid=0; blit_arvalid=0;
        if(busy || fault) $fatal(1,"Same-cycle one-beat response lost completion");
    end

    announce("same-cycle AR and first R of a multi-beat BLIT");
    requests(0,1,0,3); wait_address(1);
    arready=1; rvalid=1; rlast=0; rdata=data_word(blit_araddr,0);
    @(negedge clk); arready=0; rvalid=0; blit_arvalid=0;
    for(i=1;i<4;i=i+1) send_beat(i,i==3,0,0,i%3);

    announce("display frame flush does not cancel an in-flight BLIT read");
    requests(0,1,0,31); accept_address(1); blit_arvalid=0;
    display_flush=1; display_launch=1; enabled=0;
    send_burst(0,0,1);
    display_flush=0; display_launch=0; enabled=1;

    announce("200 deterministic random requests, watermarks, lengths, AR/R waits and response errors");
    reset_platform(); expected_preference=0; expected_healthy=1;
    for(i=0;i<200;i=i+1) begin
        random_bits=$random(seed); random_display=random_bits[0]; random_blit=random_bits[1];
        if(!random_display && !random_blit) random_blit=1;
        random_display_len=random_bits[8:2]; random_blit_len=random_bits[13:9];
        case(i%3)
            0: begin display_fifo_level=384; expected_healthy=0; end
            1: display_fifo_level=448;
            2: begin display_fifo_level=512; expected_healthy=1; end
        endcase
        repeat(3) @(negedge clk);
        expected_owner=random_blit && (!random_display || (expected_healthy && expected_preference));
        requests(random_display,random_blit,random_display_len,random_blit_len);
        wait_address(expected_owner);
        random_bits=$random(seed); delay_cycles=random_bits%5;
        repeat(delay_cycles) @(negedge clk);
        accept_address(expected_owner); display_arvalid=0; blit_arvalid=0;
        send_burst(i%11==0 ? 4'd7 : 4'd0,i%13==0 ? 2'd2 : 2'd0,1);
        expected_preference=!expected_owner; random_count=random_count+1;
    end

    for(j=0;j<2;j=j+1) begin
        announce("early RLAST faults only on handshake and never releases its original owner");
        reset_platform(); allow_fault=1;
        requests(j==0,j==1,3,3); accept_address(j);
        display_arvalid=1; blit_arvalid=1; // waiting requests cannot replace the owner
        send_beat(0,1,0,0,4);
        if(!fault || !busy || fault_code!=2) $fatal(1,"Early RLAST did not retain a faulted owner");
        send_beat(1,0,0,0,0); send_beat(2,0,0,0,0); send_beat(3,1,0,0,0);
        repeat(5) @(negedge clk);
        if(!read_active || arvalid || owner_blit!==j[0]) $fatal(1,"Fault released owner on a later RLAST");

        announce("missing final RLAST and an extra beat cannot wrap or release ownership");
        reset_platform(); allow_fault=1;
        requests(j==0,j==1,0,0); accept_address(j);
        display_arvalid=1; blit_arvalid=1;
        send_beat(0,0,0,0,0); send_beat(1,1,0,0,0);
        display_flush=1; display_launch=1; enabled=0;
        repeat(5) @(negedge clk);
        if(!fault || !read_active || beats_left!=0 || arvalid || owner_blit!==j[0])
            $fatal(1,"Missing RLAST lost owner or wrapped count");
    end

    announce("unowned R faults without creating an owner even with both requests waiting");
    reset_platform(); allow_fault=1;
    requests(1,1,0,0); rvalid=1; rlast=1;
    repeat(4) @(negedge clk);
    if(!fault || busy || address_pending || fault_code!=1 || arvalid)
        $fatal(1,"Unexpected idle R invented an owner");

    announce("unexpected R during stalled AR preserves its VALID, payload and eventual owner");
    reset_platform(); allow_fault=1;
    requests(0,1,0,1); wait_address(1);
    rvalid=1; rlast=1; repeat(3) @(negedge clk); rvalid=0;
    if(!fault || !address_pending || read_active || !arvalid)
        $fatal(1,"Fault canceled an already exposed address");
    accept_address(1); display_arvalid=1; blit_arvalid=1;
    send_burst(0,0,1);
    if(!read_active || !busy || fault_code!=1 || arvalid)
        $fatal(1,"Faulted pending AR did not retain eventual owner");

    announce("platform reset clears faults and both clients can complete again");
    reset_platform();
    requests(1,0,0,0); accept_address(0); display_arvalid=0; send_burst(0,0,0);
    requests(0,1,0,0); accept_address(1); blit_arvalid=0; send_burst(0,0,0);
    $display("PASS READ ARBITER: %0d scenarios, %0d random bursts, %0d total AR, %0d routed R beats; modeled clients/DDR, no real display timing",
        cases,random_count,all_bursts,all_beats);
    $finish;
end
initial begin #20000000; $fatal(1,"Global read arbiter watchdog"); end
endmodule
