`timescale 1ns/1ps
// Real, unmodified v7 gain + line_buffer + raw_to_rgb. Checks bar interiors.
module tb_debayer_colors;
reg clk = 0;
always #5 clk = ~clk;
reg rst_n = 0, vs = 1, de = 0;
reg [15:0] raw = 0;
wire out_de;
wire [47:0] rgb;
integer y, x, bar, checked = 0;
integer checks[0:3];
reg [23:0] expected;
reg [23:0] hdmi_lo, hdmi_hi;
debayer_top_2to1 dut (
    .in_pclk(clk), .in_rstn(rst_n), .raw_vs_i(vs), .raw_hs_i(de),
    .raw_de_i(de), .raw_valid_i(de), .raw_datax4_i(raw),
    .r_gain(16'h0100), .g_gain(16'h0100), .b_gain(16'h0100),
    .rgb_de_o(out_de), .rgb_datax2_o(rgb)
);
// Existing top feeds internal B to encoder R and internal R to encoder B.
always @(negedge clk) if (rst_n && out_de && dut.w_debayer_y >= 3 &&
    dut.w_debayer_y < 8 && dut.w_debayer_x % 8 >= 3 &&
    dut.w_debayer_x % 8 <= 5) begin
    bar = dut.w_debayer_x / 8;
    case (bar)
        0: expected = 24'hFF0000;
        1: expected = 24'h00FF00;
        2: expected = 24'h0000FF;
        3: expected = 24'hFFFFFF;
        default: expected = 24'hxxxxxx;
    endcase
    hdmi_hi = {rgb[47:40],rgb[39:32],rgb[31:24]};
    hdmi_lo = {rgb[23:16],rgb[15:8],rgb[7:0]};
    if (hdmi_hi !== expected || hdmi_lo !== expected)
        $fatal(1, "v7 mapped color mismatch y=%0d x=%0d: %h %h expected %h",
            dut.w_debayer_y, dut.w_debayer_x, hdmi_hi, hdmi_lo, expected);
    checked = checked + 2; checks[bar] = checks[bar] + 2;
end
initial begin
    for (bar=0; bar<4; bar=bar+1) checks[bar] = 0;
    repeat (6) @(negedge clk);
    rst_n = 1;
    repeat (8) @(negedge clk);
    vs = 0;
    for (y=0; y<8; y=y+1) begin
        repeat (12) @(negedge clk);
        for (x=0; x<32; x=x+1) begin
            de = 1;
            case (x/8)
                0: raw = (y%2) ? 16'h00FF : 16'h0000;
                1: raw = (y%2) ? 16'hFF00 : 16'h00FF;
                2: raw = (y%2) ? 16'h0000 : 16'hFF00;
                3: raw = 16'hFFFF;
            endcase
            @(negedge clk);
        end
        de = 0; raw = 0;
    end
    repeat (20) @(negedge clk);
    for (bar=0; bar<4; bar=bar+1)
        if (checks[bar] == 0) $fatal(1, "no samples for bar %0d", bar);
    $display("PASS v7 Debayer + existing R/B mapping: %0d interior pixels", checked);
    $finish;
end
endmodule
