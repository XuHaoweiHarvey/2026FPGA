`timescale 1ns/1ps
module tb_lunaria_perf_regs;
parameter ENABLED=1, READ_AHEAD=0;
localparam WORDS=READ_AHEAD?29:21;
reg clk=0,rst_n=0;
always #5 clk=~clk;
reg [31:0] addr=0,data=0;
reg sel=0,en=0,wr=0;
wire [31:0] rd;
wire ready,err;
reg [511:0] live=0;
integer i;
reg [31:0] value;
accel_regs #(.EXTRA_CAPABILITIES(ENABLED ? (READ_AHEAD ? 32'h60000 : 32'h20000) : 0)) dut(
    .PCLK(clk),.PRESETn(rst_n),.PADDR(addr),.PSEL(sel),.PENABLE(en),.PWRITE(wr),
    .PWDATA(data),.PRDATA(rd),.PREADY(ready),.PSLVERROR(err),
    .read_perf_counters({8{32'd777}}),.alpha_perf_counters(live),.swap_count(32'd101),.reader_data_beats(32'd102),
    .writer_throttle_cycles(32'd103),.display_underflow_count(32'd104),.missed_boundary_count(32'd105));
task access;
input write;input [31:0] a;input want_error;
begin
    @(negedge clk);addr=a;sel=1;en=0;wr=write;data=1;
    @(negedge clk);en=1;
    while(!ready) @(negedge clk);
    if(err!==want_error) $fatal(1,"APB error mismatch %h",a);
    value=rd;
    @(negedge clk);sel=0;en=0;
end endtask
initial begin
    for(i=0;i<16;i=i+1) live[i*32+:32]=i+1;
    repeat(3)@(negedge clk);rst_n=1;
    access(0,'hE8,!ENABLED);
    if(ENABLED && value!=WORDS) $fatal(1,"snapshot length");
    access(1,'hE8,!ENABLED);
    live=0;
    for(i=0;i<WORDS;i=i+1) begin
        access(0,'h100+i*4,!ENABLED);
        if(ENABLED && value!==(i<16?i+1:i<21?i+85:777)) $fatal(1,"non-atomic snapshot %d=%h",i,value);
    end
    access(1,'h100,1); // read-only snapshot
    access(0,'h100+WORDS*4,1);
    access(0,'h101,1);
    access(1,'hE8,!ENABLED);
    access(0,'h100,!ENABLED);
    if(ENABLED && value!=0) $fatal(1,"snapshot refresh");
    @(negedge clk);rst_n=0;
    repeat(3)@(negedge clk);rst_n=1;
    access(0,'h140,!ENABLED);
    if(ENABLED && value!=0) $fatal(1,"snapshot reset");
    $display("PASS PERF APB enabled=%0d: atomic snapshot, refresh/reset/read-only/alignment/legacy guard",ENABLED);
    $finish;
end
endmodule
