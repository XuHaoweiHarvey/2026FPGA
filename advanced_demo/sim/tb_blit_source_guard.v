`timescale 1ns/1ps
// Full-size/non-power-of-two-stride coverage without allocating a framebuffer.
// The reference checks the byte interval of EVERY copied row, independently
// of the DUT's source_x/source_y addition method.
module tb_blit_source_guard;
parameter FRAME_WIDTH=1920, FRAME_HEIGHT=1080, FRAME_STRIDE=FRAME_WIDTH*4;
parameter ALPHA_ENABLE=0;
localparam [31:0] BASE0=32'h00000000, BASE1=32'h00800000;
localparam [63:0] FRAME_BYTES=64'd1*FRAME_STRIDE*FRAME_HEIGHT;
reg clk=0, rst_n=0, command_accept=0;
always #5 clk=~clk;
reg [31:0] front_base=BASE0, back_base=BASE1;
reg [31:0] src_addr=0, src_stride=FRAME_STRIDE, width=32, height=32,op=1;
reg asset_ready=0;
reg sprite_ready=0;
wire src_range_valid;
integer cases=0, random_cases=0, seed=32'h51a7c0de;
integer i, xx, yy, ww, hh, mode;
reg [31:0] random_bits, saved_front, saved_back, saved_source;
reg expected;

blit_source_guard #(.FRAME_WIDTH(FRAME_WIDTH), .FRAME_HEIGHT(FRAME_HEIGHT),
    .FRAME_STRIDE(FRAME_STRIDE),.ALPHA_ENABLE(ALPHA_ENABLE)) dut (
    .clk(clk), .rst_n(rst_n), .command_accept(command_accept),
    .front_base(front_base), .back_base(back_base), .src_addr(src_addr),
    .src_stride(src_stride), .width(width), .height(height),
    .op(op),.asset_ready(asset_ready),.sprite_ready(sprite_ready),
    .src_range_valid(src_range_valid)
);

function reference_ok;
input [31:0] front, back, source, stride, w, h;
reg [63:0] frame_end, row_start, row_end, row_number, row_low, row_high;
integer row;
begin
    frame_end={32'b0,front}+FRAME_BYTES;
    reference_ok=front!=back && front[1:0]==0 && frame_end<=64'h100000000 &&
        stride==FRAME_STRIDE && source[1:0]==0 && w>0 && h>0 &&
        w<=FRAME_WIDTH && h<=FRAME_HEIGHT;
    if (reference_ok) begin
        for (row=0; row<h; row=row+1) begin
            row_start={32'b0,source}+row*{32'b0,stride};
            row_end=row_start+({32'b0,w}<<2);
            if (row_start<{32'b0,front} || row_end>frame_end) reference_ok=0;
            else begin
                row_number=(row_start-{32'b0,front})/FRAME_STRIDE;
                row_low={32'b0,front}+row_number*FRAME_STRIDE;
                row_high=row_low+FRAME_WIDTH*4;
                if (row_end>row_high) reference_ok=0;
            end
        end
    end
end
endfunction

task check;
input [8*100-1:0] name;
input [31:0] front, back, source, stride, w, h;
input wanted;
begin
    cases=cases+1;
    if (reference_ok(front,back,source,stride,w,h)!==wanted)
        $fatal(1,"Incorrect reference expectation: %0s",name);
    @(negedge clk);
    front_base=front; back_base=back; src_addr=source;
    src_stride=stride; width=w; height=h; command_accept=1;
    @(negedge clk); command_accept=0;
    if (src_range_valid!==wanted)
        $fatal(1,"Source guard mismatch %0s: front=%h src=%h stride=%0d w=%0d h=%0d got=%b expected=%b",
            name,front,source,stride,w,h,src_range_valid,wanted);
end
endtask

task asset_check;
input [31:0] source,stride,w,h,operation;
input ready,wanted;
begin
    @(negedge clk);
    front_base=BASE0;back_base=BASE1;src_addr=source;src_stride=stride;
    width=w;height=h;op=operation;asset_ready=ready;command_accept=1;
    @(negedge clk);command_accept=0;
    if(src_range_valid!==wanted)
        $fatal(1,"Asset guard source=%h op=%h ready=%b got=%b wanted=%b",
               source,operation,ready,src_range_valid,wanted);
end
endtask

task sprite_check;
input [31:0] source,stride,w,h,operation;
input ready,wanted;
begin
    @(negedge clk);
    front_base=BASE0;back_base=BASE1;src_addr=source;src_stride=stride;
    width=w;height=h;op=operation;sprite_ready=ready;command_accept=1;
    @(negedge clk);command_accept=0;
    if(src_range_valid!==wanted)
        $fatal(1,"Sprite guard source=%h op=%h ready=%b got=%b wanted=%b",
               source,operation,ready,src_range_valid,wanted);
end
endtask

task check_hold;
input wanted;
begin
    // Change every live field without accepting: the old decision must hold.
    @(negedge clk); front_base=32'hfffffff0; back_base=front_base;
    src_addr=32'hdeadbeef; src_stride=1; width=0; height=0;
    repeat(3) begin
        @(negedge clk);
        if(src_range_valid!==wanted) $fatal(1,"Source result changed without ACCEPT");
    end
end
endtask

initial begin
    if ($test$plusargs("VCD")) begin
        $dumpfile("graphics.vcd"); $dumpvars(0,tb_blit_source_guard);
    end
    repeat(3) @(negedge clk);
    if (src_range_valid!==0) $fatal(1,"Source guard reset did not clear result");
    rst_n=1;
    check("whole valid image",BASE0,BASE1,BASE0,FRAME_STRIDE,FRAME_WIDTH,FRAME_HEIGHT,1);
    check_hold(1);
    check("right/bottom exact boundary",BASE0,BASE1,
        (FRAME_HEIGHT-1)*FRAME_STRIDE+(FRAME_WIDTH-1)*4,FRAME_STRIDE,1,1,1);
    check("right edge crossed even while still inside frame",BASE0,BASE1,
        (FRAME_WIDTH-1)*4,FRAME_STRIDE,2,1,0);
    check_hold(0);
    check("bottom edge crossed",BASE0,BASE1,(FRAME_HEIGHT-1)*FRAME_STRIDE,FRAME_STRIDE,4,2,0);
    check("first byte beyond visible image",BASE0,BASE1,FRAME_BYTES[31:0],FRAME_STRIDE,4,1,0);
    check("reserved slot tail is not image",BASE0,BASE1,32'h007ffff0,FRAME_STRIDE,4,1,0);
    check("Back is not a source",BASE0,BASE1,BASE1,FRAME_STRIDE,4,1,0);
    check("before Front",BASE1,BASE0,BASE1-16,FRAME_STRIDE,4,1,0);
    check("same Front and Back",BASE0,BASE0,BASE0,FRAME_STRIDE,4,1,0);
    check("zero width",BASE0,BASE1,BASE0,FRAME_STRIDE,0,1,0);
    check("zero height",BASE0,BASE1,BASE0,FRAME_STRIDE,4,0,0);
    check("huge width cannot wrap",BASE0,BASE1,4,FRAME_STRIDE,32'hffffffff,1,0);
    check("huge height cannot wrap",BASE0,BASE1,FRAME_STRIDE,FRAME_STRIDE,4,32'hffffffff,0);
    check("wrong stride",BASE0,BASE1,BASE0,FRAME_STRIDE+16,4,1,0);
    check("zero stride",BASE0,BASE1,BASE0,0,4,1,0);
    check("byte address alignment",BASE0,BASE1,1,FRAME_STRIDE,4,1,0);
    check("pixel aligned only: B handles stricter burst alignment",BASE0,BASE1,4,FRAME_STRIDE,4,1,1);
    check("large rectangle at nonzero origin",BASE0,BASE1,FRAME_STRIDE+4,FRAME_STRIDE,
        FRAME_WIDTH-1,FRAME_HEIGHT-1,1);
    check("swapped Front1 is valid",BASE1,BASE0,BASE1,FRAME_STRIDE,32,32,1);
    check("old Front0 after swap is invalid",BASE1,BASE0,BASE0,FRAME_STRIDE,32,32,0);
    check("Front outside nominal slots is relocatable",32'h10000000,BASE0,
        32'h10000000+FRAME_STRIDE+16,FRAME_STRIDE,4,1,1);
    check("frame ending at 2^32 is valid",32'hffffffff-FRAME_BYTES[31:0]+1,BASE0,
        32'hfffffff0,FRAME_STRIDE,4,1,1);
    check("Front window wraps address space",32'hfffff000,BASE0,32'hfffff000,FRAME_STRIDE,4,1,0);
    check("address cannot wrap below Front",32'hfffff000,BASE0,0,FRAME_STRIDE,4,1,0);
    check("unaligned Front",1,BASE1,4,FRAME_STRIDE,4,1,0);
    asset_check(32'h01000000,2560,640,480,1,0,0);
    asset_check(32'h01000000,2560,640,480,1,1,1);
    asset_check(32'h0112c000,2560,640,480,1,1,1);
    asset_check(32'h01258000,2560,640,480,1,1,1);
    asset_check(32'h01384000,2560,640,480,1,1,0);
    asset_check(32'h01000010,2560,640,480,1,1,0);
    asset_check(32'h01000000,7680,640,480,1,1,0);
    asset_check(32'h01000000,2560,636,480,1,1,0);
    asset_check(32'h01000000,2560,640,480,2,1,0);
    asset_ready=0;op=1;
    if(ALPHA_ENABLE) begin
        sprite_check(32'h01384000,2560,128,128,3,0,0);
        sprite_check(32'h01384000,2560,128,128,3,1,1);
        sprite_check(32'h01384000+479*2560+636*4,2560,4,1,3,1,1);
        sprite_check(32'h01384000+479*2560+636*4,2560,8,1,3,1,0);
        sprite_check(32'h01384000+479*2560,2560,4,2,3,1,0);
        sprite_check(32'h01384000+128*4,2560,4,1,3,1,1);
        sprite_check(32'h01384000+128*4,2560,4,1,1,1,0);
        sprite_check(32'h014b0000,2560,4,1,3,1,0);
    end
    sprite_ready=0;op=1;

    // Deterministic random geometries: both roles, interior/edge/outside,
    // rejected stride/alignment and extreme unsigned dimensions.
    for(i=0;i<400;i=i+1) begin
        random_bits=$random(seed); saved_front=random_bits[0] ? BASE0 : BASE1;
        saved_back=saved_front==BASE0 ? BASE1 : BASE0;
        random_bits=$random(seed); xx=random_bits%(FRAME_WIDTH+8);
        random_bits=$random(seed); yy=random_bits%(FRAME_HEIGHT+8);
        random_bits=$random(seed); ww=1+random_bits%FRAME_WIDTH;
        random_bits=$random(seed); hh=1+random_bits%FRAME_HEIGHT;
        saved_source=saved_front+yy*FRAME_STRIDE+xx*4;
        mode=i%8;
        src_stride=FRAME_STRIDE;
        case(mode)
            0: begin xx=0; yy=0; saved_source=saved_front; end
            1: saved_source=saved_source+1;
            2: src_stride=FRAME_STRIDE+16;
            3: ww=0;
            4: hh=32'hffffffff;
            5: saved_source=saved_back;
            6: begin ww=1; hh=1; end
        endcase
        expected=reference_ok(saved_front,saved_back,saved_source,src_stride,ww,hh);
        check("random",saved_front,saved_back,saved_source,src_stride,ww,hh,expected);
        random_cases=random_cases+1;
    end
    // Reset may clear a previously valid result without accepting a new command.
    check("valid before reset",BASE0,BASE1,BASE0,FRAME_STRIDE,4,1,1);
    @(negedge clk); rst_n=0;
    #1; if(src_range_valid!==0) $fatal(1,"Asynchronous reset left stale valid result");
    $display("PASS SOURCE GUARD: %0d rectangles (%0d random), %0dx%0d stride=%0d; accept/hold/reset checked",
        cases,random_cases,FRAME_WIDTH,FRAME_HEIGHT,FRAME_STRIDE);
    $finish;
end
initial begin #2000000; $fatal(1,"Global source guard watchdog"); end
endmodule
