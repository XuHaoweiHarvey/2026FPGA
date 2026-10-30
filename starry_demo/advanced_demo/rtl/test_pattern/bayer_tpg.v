// Continuous Bayer8 x4 source for the existing framebuffer write interface.
// No ready/backpressure and no DDR master. Blank precedes active pixels.
module bayer_tpg #(
    parameter H_ACTIVE = 1920,
    parameter V_ACTIVE = 1080,
    parameter H_BLANK_CYCLES = 320,
    parameter V_BLANK_LINES = 170,
    parameter BAYER_PATTERN = 1, // 0 RGGB, 1 BGGR, 2 GRBG, 3 GBRG
    parameter [23:0] BAR_RED   = 24'hFF0000,
    parameter [23:0] BAR_GREEN = 24'h00FF00,
    parameter [23:0] BAR_BLUE  = 24'h0000FF,
    parameter [23:0] BAR_WHITE = 24'hFFFFFF
)(
    input wire clk,
    input wire rst_n,
    output wire vs,
    output wire de,
    output wire [31:0] data,
    output wire frame_start,
    output reg [31:0] frame_count,
    output reg [31:0] valid_word_count,
    output reg [31:0] last_frame_word_count
);
localparam ACTIVE_WORDS = H_ACTIVE / 4;
localparam LINE_CYCLES = ACTIVE_WORDS + H_BLANK_CYCLES;
localparam FRAME_LINES = V_ACTIVE + V_BLANK_LINES;
localparam H_BITS = (LINE_CYCLES > 1) ? $clog2(LINE_CYCLES) : 1;
localparam V_BITS = (FRAME_LINES > 1) ? $clog2(FRAME_LINES) : 1;
reg [H_BITS-1:0] h_count;
reg [V_BITS-1:0] v_count;
wire [H_BITS-1:0] word_x = h_count - H_BLANK_CYCLES;
reg [23:0] bar_rgb;

// MSB is x=4*word_x, followed by x+1, x+2, x+3.
function [7:0] bayer_sample;
    input [23:0] rgb;
    input odd_y;
    input odd_x;
    reg [1:0] phase;
    begin
        case (BAYER_PATTERN)
            0: phase = {odd_y, odd_x};             // R G / G B
            1: phase = {~odd_y, ~odd_x};           // B G / G R
            2: phase = {odd_y, ~odd_x};            // G R / B G
            3: phase = {~odd_y, odd_x};            // G B / R G
            default: phase = {~odd_y, ~odd_x};
        endcase
        case (phase)
            2'b00: bayer_sample = rgb[23:16];
            2'b11: bayer_sample = rgb[7:0];
            default: bayer_sample = rgb[15:8];
        endcase
    end
endfunction

always @(*) begin
    if (word_x < ACTIVE_WORDS/4)
        bar_rgb = BAR_RED;
    else if (word_x < ACTIVE_WORDS/2)
        bar_rgb = BAR_GREEN;
    else if (word_x < ACTIVE_WORDS*3/4)
        bar_rgb = BAR_BLUE;
    else
        bar_rgb = BAR_WHITE;
end

assign vs = !rst_n || (v_count >= V_ACTIVE);
assign de = rst_n && (v_count < V_ACTIVE) &&
                    (h_count >= H_BLANK_CYCLES);
assign frame_start = rst_n && (v_count == 0) && (h_count == 0);
assign data = de ? {bayer_sample(bar_rgb, v_count[0], 1'b0),
                   bayer_sample(bar_rgb, v_count[0], 1'b1),
                   bayer_sample(bar_rgb, v_count[0], 1'b0),
                   bayer_sample(bar_rgb, v_count[0], 1'b1)} : 32'b0;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        h_count <= 0;
        // Start in blank so the first frame has a real VS falling edge.
        v_count <= V_ACTIVE;
        frame_count <= 0;
        valid_word_count <= 0;
        last_frame_word_count <= 0;
    end else begin
        if (h_count == LINE_CYCLES-1) begin
            h_count <= 0;
            if (v_count == FRAME_LINES-1)
                v_count <= 0;
            else
                v_count <= v_count + 1'b1;
        end else
            h_count <= h_count + 1'b1;

        if (frame_start)
            valid_word_count <= 0;
        else if (de)
            valid_word_count <= valid_word_count + 1'b1;

        if ((v_count == V_ACTIVE-1) && (h_count == LINE_CYCLES-1)) begin
            frame_count <= frame_count + 1'b1;
            last_frame_word_count <= valid_word_count + 1'b1;
        end
    end
end

// Simulation-only checks; the supported interface always has four samples.
// synthesis translate_off
initial begin
    if (H_ACTIVE < 16 || H_ACTIVE % 16 != 0 || V_ACTIVE < 2 ||
        V_ACTIVE % 2 != 0 || H_BLANK_CYCLES < 8 || V_BLANK_LINES < 1 ||
        BAYER_PATTERN < 0 || BAYER_PATTERN > 3) begin
        $display("ERROR: unsupported Bayer TPG parameters");
        $finish;
    end
end
// synthesis translate_on
endmodule
