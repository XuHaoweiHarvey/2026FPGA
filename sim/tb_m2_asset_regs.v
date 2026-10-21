`timescale 1ns/1ps
module tb_m2_asset_regs;
parameter WAIT_CYCLES=0;
reg clk=0,rst_n=0,sel=0,enable=0,wr=0;
always #5 clk=~clk;
reg [31:0] addr=0,data=0,cpu_status=32'h10,cpu_error=0,reader_error=0;
reg loading=0,sealed=0,busy=0,engine_busy=0;
wire [31:0] rdata;
wire ready,error,begin_load,seal;
wire [31:0] asset_status={1'b1,28'b0,1'b0,sealed,loading};
accel_regs #(.WAIT_CYCLES(WAIT_CYCLES),.ENGINE_ENABLE(1),.DOUBLE_BUFFER(1),
             .BLIT_ENABLE(1),.COLOR_KEY_ENABLE(1),.CPU_DDR_ENABLE(1)) dut (
    .PCLK(clk),.PRESETn(rst_n),.PADDR(addr),.PSEL(sel),.PENABLE(enable),
    .PWRITE(wr),.PWDATA(data),.PRDATA(rdata),.PREADY(ready),.PSLVERROR(error),
    .init_done(1'b1),.engine_busy(engine_busy),.draw_ready(1'b1),
    .buffer_status(32'h10),.reader_error(reader_error),
    .cpu_ddr_status(cpu_status),.cpu_ddr_busy(busy),.cpu_ddr_error(cpu_error),
    .asset_status(asset_status),.asset_begin(begin_load),.asset_seal(seal));
always @(posedge clk) begin
    if(begin_load) loading<=1;
    if(seal) begin loading<=0;sealed<=1;end
end
task tx;
input writing;
input [31:0] offset,value,want;
input bad;
integer waits;
begin
    @(negedge clk);sel=1;enable=0;wr=writing;addr=offset;data=value;
    @(negedge clk);enable=1;#1;waits=0;
    while(!ready) begin @(negedge clk);#1;waits=waits+1;
        if(waits>WAIT_CYCLES+2) $fatal(1,"asset APB wait timeout");
    end
    if(error!==bad) $fatal(1,"asset APB error offset=%h got=%b want=%b",offset,error,bad);
    if(!writing && rdata!==want) $fatal(1,"asset APB read offset=%h got=%h want=%h",offset,rdata,want);
    @(posedge clk);@(negedge clk);sel=0;enable=0;
    repeat(2) @(negedge clk);
end
endtask
initial begin
    repeat(3) @(negedge clk);rst_n=1;
    tx(0,'h04,0,'h50000,0);tx(0,'h40,0,'hfb,0);
    tx(0,'hDC,0,'h80000000,0);
    tx(1,'hD8,2,0,1);tx(1,8,2,0,0); // seal before load
    tx(1,'hD8,1,0,0);tx(0,'hDC,0,'h80000001,0);
    tx(1,'hD8,1,0,1);tx(1,8,2,0,0); // duplicate begin
    cpu_status=32'h11;tx(1,'hD8,2,0,1);tx(1,8,2,0,0);
    cpu_status=32'h10;busy=1;tx(1,'hD8,2,0,1);tx(1,8,2,0,0);
    busy=0;cpu_error='h3001;tx(1,'hD8,2,0,1);tx(1,8,2,0,0);
    cpu_error=0;reader_error='h2004;tx(1,'hD8,2,0,1);tx(1,8,2,0,0);
    reader_error=0;tx(1,'hD8,3,0,1);tx(1,8,2,0,0);
    tx(1,'hD8,2,0,0);tx(0,'hDC,0,'h80000002,0);
    tx(1,'hD8,1,0,1);
    @(negedge clk);rst_n=0;@(negedge clk);rst_n=1;
    tx(0,'hDC,0,'h80000002,0); // control reset cannot unseal platform DDR
    $display("PASS M2 APB asset begin/seal/error/legacy version/CPU reset, WAIT=%0d",WAIT_CYCLES);
    $finish;
end
initial begin #200000;$fatal(1,"M2 asset APB timeout");end
endmodule
