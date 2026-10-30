`timescale 1ns/1ps
module tb_window_admission;
reg clk=0,rst_n=0,raw=1,ready=0,b=0,active=1,safe=0,launch=0,flush=0;
reg [31:0] level=0,error=0;
wire admit;wire [31:0] status;
always #5 clk=~clk;
ddr_write_admission #(.WINDOW_MODE(1)) dut (
    .clk(clk),.rst_n(rst_n),.enabled(1'b1),.raw_awvalid(raw),.ddr_awready(ready),
    .bvalid(b),.bready(1'b1),.reader_active(active),.reader_safe(safe),
    .reader_launch(launch),.fifo_flush(flush),.fifo_level(level),.reader_error(error),
    .arvalid(1'b0),.arready(1'b0),.rvalid(1'b0),.rready(1'b0),.reader_outstanding(32'b0),
    .admit_aw(admit),.service_status(status));
task response;
begin ready=1;@(negedge clk);raw=0;ready=0;b=1;@(negedge clk);b=0;end
endtask
initial begin
    repeat(5) @(negedge clk);rst_n=1;
    level=450;repeat(5) @(negedge clk);
    if(admit) $fatal(1,"Window writer ignored startup hysteresis");
    level=512;repeat(5) @(negedge clk);
    if(!admit || !status[6]) $fatal(1,"Prefilled viewport deadlocked without new reads");
    level=0;launch=1;repeat(5) @(negedge clk);launch=0;
    if(!admit) $fatal(1,"Stalled window AW was withdrawn");
    response;
    raw=1;repeat(5) @(negedge clk);
    if(admit) $fatal(1,"New window write at low water");
    level=450;repeat(5) @(negedge clk);
    if(admit) $fatal(1,"Window high-water hysteresis bypass");
    level=512;repeat(5) @(negedge clk);
    if(!admit) $fatal(1,"Window high-water progress");
    response;
    raw=1;level=512;error=32'h2003;repeat(5) @(negedge clk);
    if(admit) $fatal(1,"Window fault bypass");
    error=0;launch=1;repeat(5) @(negedge clk);
    if(admit) $fatal(1,"Window grant during launch");
    launch=0;flush=1;repeat(5) @(negedge clk);
    if(admit) $fatal(1,"Window grant during flush");
    flush=0;safe=1;active=0;level=0;repeat(5) @(negedge clk);
    if(!admit) $fatal(1,"Window end-of-frame slack deadlock");
    $display("PASS window admission: prefilled-FIFO progress, low/high protection, held AW, fault/launch/flush guard and safe slack");
    $finish;
end
endmodule
