`timescale 1ns/1ps
// APB v4 contract independent of DDR: waits, snapshots, rejection and CPU reset.
module tb_graphics_regs;
parameter WAIT_CYCLES=1;
reg clk=0,reset_n=0;
always #5 clk=~clk;
reg [31:0] addr=0,data=0,reader_error=0;
reg sel=0,enable=0,wr=0,busy=0,draw_ready=1;
wire [31:0] rdata,x,y,width,height,color,op,source,stride;
wire ready,error,start,swap;
integer starts=0,accesses=0;
wire [255:0] snapshot={op,source,stride,x,y,width,height,color};
reg [255:0] saved;
accel_regs #(.WAIT_CYCLES(WAIT_CYCLES),.ENGINE_ENABLE(1),.DOUBLE_BUFFER(1),.BLIT_ENABLE(1)) dut (
 .PCLK(clk),.PRESETn(reset_n),.PADDR(addr),.PSEL(sel),.PENABLE(enable),.PWRITE(wr),.PWDATA(data),
 .PRDATA(rdata),.PREADY(ready),.PSLVERROR(error),.init_done(1'b1),.init_error(32'b0),
 .engine_busy(busy),.engine_done(1'b0),.engine_error(32'b0),.command_count(32'b0),
 .draw_ready(draw_ready),.buffer_status(32'h10),.reader_error(reader_error),
 .cmd_op(op),.cmd_src_addr(source),.cmd_src_stride(stride),.cmd_x(x),.cmd_y(y),
 .cmd_width(width),.cmd_height(height),.cmd_color(color),.start_pulse(start),.swap_request(swap));
always @(posedge clk) begin #1;if(start) starts=starts+1;end
task tx;
input write_enable;
input [31:0] address,value,expected;
input expected_error;
integer waits,old_starts;
begin
 old_starts=starts;
 @(negedge clk);sel=1;enable=0;wr=write_enable;addr=address;data=value;
 @(posedge clk);#2;
 if(ready || error || starts!=old_starts) $fatal(1,"v4 setup side effect");
 @(negedge clk);enable=1;#1;waits=0;
 while(!ready) begin
  if(error) $fatal(1,"v4 error before completion");
  @(posedge clk);#2;
  if(starts!=old_starts) $fatal(1,"v4 START during wait");
  waits=waits+1;@(negedge clk);
  if(waits>WAIT_CYCLES+2) $fatal(1,"v4 APB timeout");
 end
 if(waits!=WAIT_CYCLES || error!==expected_error) $fatal(1,"v4 waits/error address=%h",address);
 if(!write_enable && rdata!==expected) $fatal(1,"v4 read %h got=%h expected=%h",address,rdata,expected);
 @(posedge clk);#2;accesses=accesses+1;
end endtask
task idle;
begin @(negedge clk);sel=0;enable=0;wr=0;end endtask
initial begin
 repeat(4)@(negedge clk);reset_n=1;
 tx(0,4,0,'h40000,0);tx(0,'h40,0,'h7b,0);
 tx(0,'hBC,0,0,0);tx(0,'hC0,0,0,0);tx(0,'hC4,0,0,0);
 tx(1,'hBC,1,0,0);tx(1,'hC0,'h801000,0,0);tx(1,'hC4,7680,0,0);
 tx(1,'h10,64,0,0);tx(1,'h14,32,0,0);tx(1,'h18,32,0,0);tx(1,'h1C,16,0,0);tx(1,'h20,'h12345678,0,0);
 tx(0,'hBC,0,1,0);tx(0,'hC0,0,'h801000,0);tx(0,'hC4,0,7680,0);
 if(snapshot!==0) $fatal(1,"Parameter write changed snapshot");
 tx(1,8,1,0,0);idle;
 saved={32'd1,32'h801000,32'd7680,32'd64,32'd32,32'd32,32'd16,32'h12345678};
 if(starts!=1 || snapshot!==saved) $fatal(1,"Missing full BLIT snapshot");
 tx(1,'hBC,'hffffffff,0,0);tx(1,'hC0,'hfedcba98,0,0);tx(1,'hC4,'h87654321,0,0);
 tx(0,'hBC,0,'hffffffff,0);tx(0,'hC0,0,'hfedcba98,0);tx(0,'hC4,0,'h87654321,0);
 idle;busy=1;tx(1,8,1,0,1);tx(0,'h24,0,5,0);idle;
 busy=0;draw_ready=0;tx(1,8,1,0,1);tx(0,'h24,0,6,0);idle;
 if(starts!=1 || snapshot!==saved) $fatal(1,"Rejected START changed snapshot");
 draw_ready=1;tx(1,8,1,0,0);idle;
 if(starts!=2 || op!='hffffffff || source!='hfedcba98 || stride!='h87654321)
  $fatal(1,"Opcode/source data truncated");
 tx(0,'hC1,0,0,1);tx(0,'h24,0,1,0);tx(0,'hC8,0,0,1);tx(0,'h24,0,2,0);
 idle;reader_error='h2004;draw_ready=0;
 tx(1,'h60,1,0,1);idle;
 if(swap) $fatal(1,"Swap accepted during shared read fault");
 tx(1,'h60,2,0,0);tx(0,'h78,0,'h2004,0);
 // Reset during setup/access must clear all RW and command snapshots.
 @(negedge clk);sel=1;enable=0;wr=1;addr=8;data=1;
 @(posedge clk);@(negedge clk);enable=1;reset_n=0;
 #1;if(ready || error || start || swap || snapshot!==0) $fatal(1,"Reset did not clear control island");
 idle;repeat(2)@(negedge clk);reset_n=1;
 tx(0,'hBC,0,0,0);tx(0,'hC0,0,0,0);tx(0,'hC4,0,0,0);tx(0,'h78,0,'h2004,0);idle;
 if(starts!=2) $fatal(1,"Reset triggered another START");
 $display("PASS graphics regs: WAIT=%0d %0d accesses, v4/RW/8-field snapshot/rejected START/CPU reset/shared fault",WAIT_CYCLES,accesses);
 $finish;
end
initial begin #200000;$fatal(1,"Graphics regs watchdog");end
endmodule
