`timescale 1ns/1ps
module tb_rgb_slots;
reg clk=0,rst_n=0,wr_sw=0,rd_sw=0;
always #5 clk=~clk;
wire [31:0] wr_addr,rd_addr;
wire [1:0] wr_bank,rd_bank;
bank_switch #(.FB_NUM(3),.MAX_VID_WIDTH(1920),.MAX_VID_HIGHT(1080),
    .START_ADDR(0),.VID_DATA_WIDTH(32),.AXI_DATA_WIDTH(128)) dut (
    .ddr_clk(clk),.rst_n(rst_n),.wr_sw(wr_sw),.rd_sw(rd_sw),
    .wr_start_addr(wr_addr),.rd_start_addr(rd_addr),.wr_bank(wr_bank),.rd_bank(rd_bank));
task pulse_write;
begin @(negedge clk);wr_sw=1;repeat(3) @(negedge clk);wr_sw=0;repeat(3) @(negedge clk);end
endtask
task pulse_read;
begin @(negedge clk);rd_sw=1;repeat(3) @(negedge clk);rd_sw=0;repeat(3) @(negedge clk);end
endtask
initial begin
    repeat(4) @(negedge clk);rst_n=1;
    if(wr_addr!==32'h0 || rd_addr!==32'h007e9200) $fatal(1,"Initial slots");
    pulse_write;
    if(wr_addr!==32'h00fd2400 || wr_bank!=2) $fatal(1,"Third slot");
    pulse_read;
    if(rd_addr!==32'h0 || rd_bank!=0) $fatal(1,"Completed first slot");
    pulse_write;
    if(wr_addr!==32'h007e9200 || wr_bank!=1) $fatal(1,"Second slot");
    pulse_read;
    if(rd_addr!==32'h00fd2400 || rd_bank!=2) $fatal(1,"Read third slot");
    $display("PASS 1080p slots: 00000000 / 007E9200 / 00FD2400, original three-bank policy");$finish;
end
endmodule
