`timescale 1ns/1ps
module tb_accel_regs;
parameter WAIT_CYCLES = 1;
reg clk=0, reset_n=0;
always #5 clk=~clk;
reg [31:0] addr=0, data=0;
reg sel=0, enable=0, wr=0;
wire [31:0] rdata;
wire ready, error, start;
reg [31:0] display_base=32'h007e9200, write_base=0;
integer starts=0, accesses=0;
accel_regs #(.WAIT_CYCLES(WAIT_CYCLES)) dut (
    .PCLK(clk),.PRESETn(reset_n),.PADDR(addr),.PSEL(sel),.PENABLE(enable),
    .PWRITE(wr),.PWDATA(data),.PRDATA(rdata),.PREADY(ready),.PSLVERROR(error),
    .display_buffer_base(display_base),.tpg_write_buffer_base(write_base),.start_pulse(start));
always @(posedge clk) begin
    #1;
    if(start) starts=starts+1;
end
// Keep PSEL asserted across transactions: access -> setup -> access.
task transaction;
input write_enable;
input [31:0] address, value, expected;
input expected_error;
integer waits, before_starts;
begin
    before_starts=starts;
    @(negedge clk); sel=1;enable=0;wr=write_enable;addr=address;data=value;
    @(posedge clk); #2;
    if(ready || error || starts!=before_starts) $fatal(1,"Side effect in setup");
    @(negedge clk); enable=1; #1;
    waits=0;
    while(!ready) begin
        if(error) $fatal(1,"PSLVERROR asserted before completion");
        @(posedge clk); #2;
        if(starts!=before_starts) $fatal(1,"START occurred during wait");
        waits=waits+1;
        @(negedge clk);
        if(waits>WAIT_CYCLES+2) $fatal(1,"APB timeout");
    end
    if(waits!=WAIT_CYCLES) $fatal(1,"Wrong wait count %0d",waits);
    if(error!==expected_error) $fatal(1,"PSLVERROR addr=%h",address);
    if(!write_enable && rdata!==expected) $fatal(1,"Read %h got %h expected %h",address,rdata,expected);
    @(posedge clk); #2; accesses=accesses+1;
    // No next access edge occurs until the next task supplies a setup.
end
endtask
task read_word;
input [31:0] address, expected;
begin transaction(0,address,0,expected,0);end
endtask
task write_word;
input [31:0] address, value;
begin transaction(1,address,value,0,0);end
endtask
task idle;
begin @(negedge clk);sel=0;enable=0;wr=0;end
endtask
integer i;
initial begin
    repeat(4) @(negedge clk);reset_n=1;
    read_word('h00,32'h4143434c);read_word('h04,32'h00010000);
    write_word('h10,123);read_word('h10,123);
    write_word('h14,456);read_word('h14,456);
    write_word('h18,640);read_word('h18,640);
    write_word('h1c,480);read_word('h1c,480);
    write_word('h20,32'h00ff0000);read_word('h20,32'h00ff0000);
    write_word('h28,32'h12345678);read_word('h28,32'h12345678);
    for(i=0;i<32;i=i+1) begin
        write_word('h28,32'b1<<i);read_word('h28,32'b1<<i);
    end
    write_word('h08,32'h20);read_word('h08,32'h20);
    read_word('h0c,0);read_word('h24,0);
    write_word('h08,32'h21);read_word('h08,32'h20);read_word('h0c,2);
    if(starts!=1) $fatal(1,"START must occur exactly once");
    write_word('h08,32'h21);read_word('h0c,2);
    if(starts!=2) $fatal(1,"Second START lost or repeated");
    transaction(1,'h00,0,0,1);read_word('h00,32'h4143434c);read_word('h24,3);
    transaction(0,'h44,0,0,1);read_word('h24,2);
    transaction(1,'h10028,32'hfeedface,0,1);read_word('h28,32'h80000000);
    transaction(1,'h11,999,0,1);read_word('h10,123);read_word('h24,1);
    transaction(0,'h06,0,0,1);
    read_word('h2c,display_base);read_word('h30,write_base);
    read_word('h34,7680);read_word('h38,1920);read_word('h3c,1080);read_word('h40,7);
    idle();display_base=32'h00fd2400;write_base=32'h007e9200;
    read_word('h2c,display_base);read_word('h30,write_base);
    transaction(1,'h2c,0,0,1);read_word('h2c,display_base);
    // Abort setup: no access edge, therefore no write or START.
    @(negedge clk);sel=1;enable=0;wr=1;addr='h08;data=1;
    repeat(3) @(posedge clk);
    idle();repeat(3) @(posedge clk);
    if(starts!=2) $fatal(1,"Aborted setup triggered START");
    // Reset during an access/wait cancels the transaction and all state.
    @(negedge clk);sel=1;enable=0;addr='h08;data=1;wr=1;
    @(posedge clk);@(negedge clk);enable=1;reset_n=0;
    #1;if(ready || error || start) $fatal(1,"Outputs active during reset");
    idle();repeat(2) @(negedge clk);reset_n=1;
    read_word('h10,0);read_word('h28,0);read_word('h08,0);read_word('h0c,0);read_word('h24,0);
    idle();#20;
    if(starts!=2) $fatal(1,"Reset access triggered START");
    $display("PASS accel_regs APB3: WAIT_CYCLES=%0d, %0d accesses, read/write/errors/back-to-back/reset, two START pulses",WAIT_CYCLES,accesses);
    $finish;
end
initial begin #200000;$fatal(1,"Watchdog timeout");end
endmodule
