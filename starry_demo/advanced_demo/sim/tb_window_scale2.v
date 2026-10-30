`timescale 1ns/1ps
module tb_window_scale2;
reg clk=0,rst_n=0,period=1;
always #5 clk=~clk;
reg [31:0] rng=32'h4523aabb;
always @(posedge clk) rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
reg [127:0] data;
integer issued=0,pairs=0,frame_id=0,done=0,i,j;
wire read,valid,user,last;
wire [63:0] out;
wire ready=rng[0] || rng[1];
wire empty=issued>=6 || !rng[2];
window_scale2_composer #(.FRAME_WIDTH(40),.FRAME_HEIGHT(16),.SOURCE_WIDTH(8),
    .SOURCE_HEIGHT(3),.OUTPUT_X(4),.OUTPUT_Y(4)) dut (
    .clk(clk),.rst_n(rst_n),.frame_period(period),.fifo_data(data),.fifo_empty(empty),
    .fifo_read(read),.m_axis_tdata(out),.m_axis_tvalid(valid),.m_axis_tready(ready),
    .m_axis_tuser(user),.m_axis_tlast(last));
function [31:0] value;
    input integer index;
    begin value=32'h10502030+index+frame_id*256; end
endfunction
integer x,y,index;
reg [31:0] expected;
reg held=0;
reg [65:0] saved;
always @(posedge clk) begin
    if(!rst_n || period) begin issued<=0;pairs<=0;held<=0;end
    else begin
        if(read) begin
            if(empty) $fatal(1,"Read empty source");
            data<={value(issued*4+3),value(issued*4+2),value(issued*4+1),value(issued*4)};
            issued<=issued+1;
        end
        if(held && (!valid || {user,last,out}!==saved)) $fatal(1,"Payload changed while stalled");
        held<=valid && !ready;saved<={user,last,out};
        if(valid && ready) begin
            x=(pairs%20)*2;y=pairs/20;expected=0;
            if(x>=4 && x<20 && y>=4 && y<10) begin
                index=((y-4)/2)*8+(x-4)/2;expected=value(index);
            end
            if(out!=={expected,expected} || user!==(pairs==0) || last!==(x==38))
                $fatal(1,"Scale2 mismatch frame%0d pair%0d: %h vs %h",frame_id,pairs,out,expected);
            pairs<=pairs+1;
            if(pairs==319) begin
                if(issued!=6) $fatal(1,"Source read more than once");
                done<=done+1;
            end
        end
    end
end
initial begin
    repeat(4) @(negedge clk);rst_n=1;
    for(i=0;i<3;i=i+1) begin
        frame_id=i;period=1;repeat(4) @(negedge clk);period=0;
        wait(done==i+1);@(negedge clk);
    end
    // Interrupt a frame with an outstanding fill, then use entirely new pixels.
    period=1;repeat(4) @(negedge clk);period=0;
    wait(pairs>70);wait(dut.pending);@(negedge clk);rst_n=0;period=1;
    repeat(4) @(negedge clk);frame_id=9;rst_n=1;period=0;
    wait(done==4);
    @(negedge clk);period=1;repeat(4) @(negedge clk);period=0;
    wait(pairs>70);wait(dut.pending);@(negedge clk);period=1;
    repeat(4) @(negedge clk);frame_id=10;period=0;
    wait(done==5);
    $display("PASS scale2: every pixel, black edges, random FIFO stalls/backpressure, 3 frames, reset/blank with pending reads, exact read count");
    $finish;
end
initial begin #1000000;$fatal(1,"Scale2 timeout");end
endmodule
