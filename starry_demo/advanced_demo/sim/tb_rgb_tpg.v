`timescale 1ns/1ps
module tb_rgb_tpg;
parameter H_ACTIVE=1920, V_ACTIVE=1080, H_BLANK=320, V_BLANK=170;
reg clk=0, rst_n=0;
always #10 clk=~clk;
wire vs,de,start;
wire [127:0] data;
wire [31:0] frames,words,last_words;
rgb_tpg #(.H_ACTIVE(H_ACTIVE),.V_ACTIVE(V_ACTIVE),
    .H_BLANK_CYCLES(H_BLANK),.V_BLANK_LINES(V_BLANK)) dut (
    .clk(clk),.rst_n(rst_n),.vs(vs),.de(de),.data(data),.frame_start(start),
    .frame_count(frames),.valid_word_count(words),.last_frame_word_count(last_words));
localparam LINE=H_ACTIVE/4+H_BLANK;
localparam PERIOD=LINE*(V_ACTIVE+V_BLANK);
integer cycle=0, starts=0, seen=0, h,y,bar;
reg running=0;
reg [31:0] color;
always @(posedge clk) if(rst_n) begin
    if(start) begin
        if(running && (cycle!=PERIOD || seen!=H_ACTIVE/4*V_ACTIVE ||
            frames!=starts || last_words!=seen)) $fatal(1,"RGB frame length/count");
        starts=starts+1;
        if(starts==4) begin
            $display("PASS RGB TPG: three continuous frames, %0d beats/frame, %0d cycles/frame",seen,PERIOD);
            $finish;
        end
        cycle=0; seen=0; running=1;
    end
    if(running) begin
        h=cycle%LINE; y=cycle/LINE;
        if(vs!==(y>=V_ACTIVE) || de!==((y<V_ACTIVE)&&(h>=H_BLANK)))
            $fatal(1,"RGB VS/DE");
        if(de) begin
            bar=(h-H_BLANK)/(H_ACTIVE/16);
            case(bar)
                0:color=32'h00ff0000; 1:color=32'h0000ff00;
                2:color=32'h000000ff; default:color=32'h00ffffff;
            endcase
            if(data!=={4{color}} || words!=seen) $fatal(1,"RGB TPG pixel/count");
            seen=seen+1;
        end else if(data!==0) $fatal(1,"RGB blank data");
        cycle=cycle+1;
    end else if(de || !vs) $fatal(1,"RGB startup blank");
end
initial begin
    repeat(5) @(negedge clk); rst_n=1;
    repeat(PERIOD*5) @(negedge clk); $fatal(1,"RGB TPG timeout");
end
endmodule
