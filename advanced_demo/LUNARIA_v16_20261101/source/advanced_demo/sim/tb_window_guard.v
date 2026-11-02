`timescale 1ns/1ps
module tb_window_guard;
reg clk=0,rst_n=0,launch=0,idle=1,av=0,rv=0,last=0;
reg [31:0] addr=0;
reg [7:0] len=127;
reg [1:0] resp=0;
wire safe;
wire [31:0] error;
localparam BASE=32'h00800000,START=BASE+2306560;
always #5 clk=~clk;
read_frame_guard #(.FRAME_BEATS(76800),.STRIDED(1)) dut (
    .clk(clk),.rst_n(rst_n),.launch(launch),.frame_base(BASE),.reader_idle(idle),
    .araddr(addr),.arlen(len),.arsize(3'd4),.arburst(2'd1),.arvalid(av),.arready(1'b1),
    .rvalid(rv),.rready(1'b1),.rlast(last),.rid(4'b0),.rresp(resp),
    .safe(safe),.error_code(error));
task restart;
begin
    @(negedge clk);rst_n=0;launch=0;idle=1;av=0;rv=0;last=0;resp=0;
    repeat(3) @(negedge clk);rst_n=1;@(negedge clk);
    launch=1;@(negedge clk);launch=0;idle=0;
end endtask
task issue;
input [31:0] address;input [7:0] length;
begin addr=address;len=length;av=1;@(negedge clk);av=0;end
endtask
task returned;
input integer count;
integer i;
begin
    for(i=0;i<count;i=i+1) begin rv=1;last=(i==count-1);@(negedge clk);end
    rv=0;last=0;@(negedge clk);
end endtask
initial begin
    restart;issue(BASE,127);
    if(error!='h2002 || safe) $fatal(1,"Window guard accepted exterior start");
    restart;issue(START,127);returned(128);issue(START+2048,63);
    if(error!='h2002 || safe) $fatal(1,"Window guard accepted cross-row read");
    restart;issue(START,127);returned(128);issue(START+2048,31);returned(32);
    issue(START+2560,127);
    if(error!='h2002 || safe) $fatal(1,"Window guard accepted contiguous exterior after row");
    restart;issue(START,127);returned(128);issue(START+2048,31);returned(32);
    issue(START+7680,127);returned(128);
    if(error!=0 || safe) $fatal(1,"Window guard rejected valid row stride or finished early");
    restart;issue(START,127);rv=1;last=1;@(negedge clk);rv=0;
    if(error!='h2002) $fatal(1,"Window guard accepted premature RLAST");
    restart;issue(START,127);rv=1;resp=2;@(negedge clk);rv=0;
    if(error!='h2003 || safe) $fatal(1,"Window guard accepted RRESP fault");
    repeat(4) @(negedge clk);
    if(error!='h2003) $fatal(1,"Window guard lost sticky fault");
    $display("PASS window guard: exterior/cross-row/contiguous-row/RLAST/RRESP rejection and valid row stride");
    $finish;
end
initial begin #100000;$fatal(1,"Window guard timeout");end
endmodule
