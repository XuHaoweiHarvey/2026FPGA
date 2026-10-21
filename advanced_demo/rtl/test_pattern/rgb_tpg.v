// XRGB8888 x4 source; ONE_FRAME stops after one complete active frame.
// No AXI master and no backpressure.
// Pixel P0 at the lowest address occupies data[31:0].
module rgb_tpg #(
    parameter H_ACTIVE = 1920,
    parameter V_ACTIVE = 1080,
    parameter H_BLANK_CYCLES = 320,
    parameter V_BLANK_LINES = 170,
    parameter ONE_FRAME = 0,
    parameter [31:0] BAR_RED   = 32'h00FF0000,
    parameter [31:0] BAR_GREEN = 32'h0000FF00,
    parameter [31:0] BAR_BLUE  = 32'h000000FF,
    parameter [31:0] BAR_WHITE = 32'h00FFFFFF
)(
    input wire clk,
    input wire rst_n,
    output wire vs,
    output wire de,
    output wire [127:0] data,
    output reg frame_start,
    output reg [31:0] frame_count,
    output reg [31:0] valid_word_count,
    output reg [31:0] last_frame_word_count,
    output reg source_done
);
localparam ACTIVE_WORDS = H_ACTIVE / 4;
localparam LINE_CYCLES = ACTIVE_WORDS + H_BLANK_CYCLES;
localparam FRAME_LINES = V_ACTIVE + V_BLANK_LINES;
localparam H_BITS = (LINE_CYCLES > 1) ? $clog2(LINE_CYCLES) : 1;
localparam V_BITS = (FRAME_LINES > 1) ? $clog2(FRAME_LINES) : 1;
reg [H_BITS-1:0] h_count;
reg [V_BITS-1:0] v_count;
wire [H_BITS-1:0] word_x = h_count - H_BLANK_CYCLES;
reg [31:0] color;
always @(*) begin
    if (word_x < ACTIVE_WORDS/4) color = BAR_RED;
    else if (word_x < ACTIVE_WORDS/2) color = BAR_GREEN;
    else if (word_x < ACTIVE_WORDS*3/4) color = BAR_BLUE;
    else color = BAR_WHITE;
end
assign vs = !rst_n || v_count >= V_ACTIVE;
assign de = rst_n && !source_done && v_count < V_ACTIVE && h_count >= H_BLANK_CYCLES;
assign data = de ? {4{color}} : 128'b0;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        h_count <= 0;
        v_count <= V_ACTIVE;
        frame_count <= 0;
        valid_word_count <= 0;
        last_frame_word_count <= 0;
        frame_start <= 0;
        source_done <= 0;
    end else begin
        // This drives a FIFO asynchronous reset: never decode h_count==0 and
        // v_count==0 combinationally. At a line boundary, h clears before v
        // has settled and that decode can pulse even though no frame starts.
        frame_start <= !source_done && h_count == LINE_CYCLES-1 && v_count == FRAME_LINES-1;
        if (!source_done && h_count == LINE_CYCLES-1) begin
            h_count <= 0;
            v_count <= (v_count == FRAME_LINES-1) ? 0 : v_count + 1'b1;
        end else if (!source_done) h_count <= h_count + 1'b1;
        if (frame_start) valid_word_count <= 0;
        else if (de) valid_word_count <= valid_word_count + 1'b1;
        if (!source_done && v_count == V_ACTIVE-1 && h_count == LINE_CYCLES-1) begin
            frame_count <= frame_count + 1'b1;
            last_frame_word_count <= valid_word_count + 1'b1;
            if (ONE_FRAME) source_done <= 1;
        end
    end
end
// synthesis translate_off
initial begin
    if (H_ACTIVE < 16 || H_ACTIVE % 16 != 0 || V_ACTIVE < 1 ||
        H_BLANK_CYCLES < 8 || V_BLANK_LINES < 1)
        $fatal(1, "Unsupported RGB TPG geometry/blanking");
end
// synthesis translate_on
endmodule
