// Back writer admission only. Never revoke an exposed AW, interrupt W, or
// withhold B. Reader AR/R have no gate and no dependency on this state machine.
module ddr_write_admission #(
    parameter ENABLE=1, READ_QUOTA=128, FIFO_LOW=384, FIFO_HIGH=512
)(
    input wire clk,rst_n,enabled,
    input wire raw_awvalid,ddr_awready,bvalid,bready,
    input wire reader_active,reader_safe,reader_launch,fifo_flush,
    input wire [31:0] fifo_level,reader_error,
    input wire arvalid,arready,rvalid,rready,
    input wire [31:0] reader_outstanding,
    output wire admit_aw,
    output wire [31:0] service_status,
    output reg [31:0] throttle_cycles,writer_bursts,ar_stall_cycles,ar_max_stall,
    output reg [31:0] r_stall_cycles,r_max_stall,frame_completions,max_write_cycles
);
reg grant,healthy,transaction_active,active_d;
reg [31:0] read_credit,ar_run,r_run,write_run;
wire rf=rvalid && rready;
wire af=raw_awvalid && admit_aw && ddr_awready;
wire bf=enabled && bvalid && bready;
wire ar_wait=arvalid && !arready;
wire r_wait=(reader_outstanding!=0) && !rf;
wire new_grant=enabled && !reader_launch && !fifo_flush && reader_error==0 &&
    (reader_safe || (reader_active && healthy && fifo_level>FIFO_LOW && read_credit>=READ_QUOTA));
assign admit_aw=ENABLE ? grant : 1'b1;
// bit0 admission held, bit1 low-water hold, bit2 waiting AW, bit3 AW..B active,
// bit4 quota earned, bit5 policy enabled. Raw counters reset only with video.
assign service_status={26'b0,(ENABLE!=0),(read_credit>=READ_QUOTA),transaction_active,
                       (raw_awvalid && !admit_aw),!healthy,admit_aw};
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        grant<=0;healthy<=0;transaction_active<=0;active_d<=0;read_credit<=0;
        throttle_cycles<=0;writer_bursts<=0;ar_stall_cycles<=0;ar_max_stall<=0;
        r_stall_cycles<=0;r_max_stall<=0;frame_completions<=0;max_write_cycles<=0;
        ar_run<=0;r_run<=0;write_run<=0;
    end else begin
        // Once visible to DDR, AWVALID is held until READY even if water drops.
        // A grant covers exactly one whole transaction, including its B.
        if(bf) grant<=0;
        else if(!grant && raw_awvalid && new_grant) grant<=1;
        if(reader_launch || fifo_flush) healthy<=0;
        else if(fifo_level<=FIFO_LOW) healthy<=0;
        else if(fifo_level>=FIFO_HIGH) healthy<=1;
        // Only real returned data after the previous B earns service credit.
        // At most one 32-beat write between READ_QUOTA returned read beats.
        if(bf || reader_launch || fifo_flush) read_credit<=0;
        else if(!grant && rf && read_credit<READ_QUOTA) read_credit<=read_credit+1'b1;
        if(enabled && raw_awvalid && !admit_aw) throttle_cycles<=throttle_cycles+1'b1;
        if(af && enabled) begin writer_bursts<=writer_bursts+1'b1;transaction_active<=1;end
        if(bf) transaction_active<=0;
        if(enabled && ((raw_awvalid && admit_aw) || transaction_active)) begin
            write_run<=write_run+1'b1;
            if(write_run+1>max_write_cycles) max_write_cycles<=write_run+1'b1;
        end else write_run<=0;
        if(ar_wait) begin
            ar_stall_cycles<=ar_stall_cycles+1'b1;ar_run<=ar_run+1'b1;
            if(ar_run+1>ar_max_stall) ar_max_stall<=ar_run+1'b1;
        end else ar_run<=0;
        if(r_wait) begin
            r_stall_cycles<=r_stall_cycles+1'b1;r_run<=r_run+1'b1;
            if(r_run+1>r_max_stall) r_max_stall<=r_run+1'b1;
        end else r_run<=0;
        active_d<=reader_active;
        if(active_d && !reader_active && reader_safe) frame_completions<=frame_completions+1'b1;
    end
end
// synthesis translate_off
initial if(READ_QUOTA<1 || FIFO_LOW<1 || FIFO_HIGH<=FIFO_LOW)
    $fatal(1,"Invalid read-service admission parameters");
// synthesis translate_on
endmodule
