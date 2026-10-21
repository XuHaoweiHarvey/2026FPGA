`timescale 1ns/1ps
module tb_bayer_tpg;
parameter H_ACTIVE = 1920;
parameter V_ACTIVE = 1080;
parameter H_BLANK = 320;
parameter V_BLANK = 170;
reg clk = 0;
always #10 clk = ~clk;
reg rst_n = 0;
wire vs, de, start;
wire [31:0] data, frames, words, last_words;
bayer_tpg #(.H_ACTIVE(H_ACTIVE), .V_ACTIVE(V_ACTIVE),
    .H_BLANK_CYCLES(H_BLANK), .V_BLANK_LINES(V_BLANK)) dut (
    .clk(clk), .rst_n(rst_n), .vs(vs), .de(de), .data(data),
    .frame_start(start), .frame_count(frames),
    .valid_word_count(words), .last_frame_word_count(last_words)
);
localparam LINE = H_ACTIVE/4 + H_BLANK;
localparam PERIOD = LINE * (V_ACTIVE + V_BLANK);
localparam WORDS = H_ACTIVE/4 * V_ACTIVE;
integer frame_cycle = 0, starts = 0, seen = 0;
integer h, y, x, bar;
reg running = 0;
reg [31:0] expected;
always @(posedge clk) if (rst_n) begin
    if (start) begin
        if (running) begin
            if (frame_cycle != PERIOD || seen != WORDS ||
                frames != starts || last_words != WORDS)
                $fatal(1, "frame period/count failure: %0d %0d %0d %0d",
                    frame_cycle, seen, frames, last_words);
        end
        starts = starts + 1;
        if (starts == 5) begin
            $display("PASS TPG: four continuous frames, %0d words/frame, %0d cycles/frame", WORDS, PERIOD);
            $finish;
        end
        frame_cycle = 0; seen = 0; running = 1;
    end
    if (running) begin
        h = frame_cycle % LINE; y = frame_cycle / LINE;
        if (vs !== (y >= V_ACTIVE) ||
            de !== ((y < V_ACTIVE) && (h >= H_BLANK)))
            $fatal(1, "VS/DE mismatch at cycle %0d", frame_cycle);
        if (de) begin
            x = h - H_BLANK; bar = x / (H_ACTIVE/16);
            case (bar)
                0: expected = (y % 2) ? 32'h00FF00FF : 32'h00000000;
                1: expected = (y % 2) ? 32'hFF00FF00 : 32'h00FF00FF;
                2: expected = (y % 2) ? 32'h00000000 : 32'hFF00FF00;
                3: expected = 32'hFFFFFFFF;
                default: expected = 32'hxxxxxxxx;
            endcase
            if (data !== expected || words != seen)
                $fatal(1, "Bayer/count mismatch at y=%0d word=%0d", y, x);
            seen = seen + 1;
        end else if (data !== 0) $fatal(1, "data outside active");
        frame_cycle = frame_cycle + 1;
    end else if (de || !vs) $fatal(1, "startup must be blank");
end
initial begin
    repeat (5) @(negedge clk);
    rst_n = 1;
    repeat (PERIOD*6) @(negedge clk);
    $fatal(1, "TPG timeout");
end
endmodule
