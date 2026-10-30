// The existing USER_PLL supplies phase-related pair_clk and 2x pixel_clk.
// At the coincident rising edge, pair_toggle is still its previous value.
// The following pixel edge captures the stable pair and emits P0; the next
// emits saved P1. This is a related-clock transfer, not an asynchronous CDC.
module rgb_to_hdmi (
    input wire pair_clk, input wire pixel_clk, input wire rst_n,
    input wire [63:0] pair_data,
    input wire pair_vs, input wire pair_hs, input wire pair_de,
    output reg [7:0] red, output reg [7:0] green, output reg [7:0] blue,
    output reg vs, output reg hs, output reg de
);
reg pair_toggle;
reg seen_toggle, second_pending;
reg [23:0] second_rgb;
reg saved_vs, saved_hs, saved_de;
always @(posedge pair_clk or negedge rst_n)
    if (!rst_n) pair_toggle <= 0;
    else pair_toggle <= ~pair_toggle;
always @(posedge pixel_clk or negedge rst_n) begin
    if (!rst_n) begin
        seen_toggle <= 0; second_pending <= 0;
        second_rgb <= 0; saved_vs <= 0; saved_hs <= 0; saved_de <= 0;
        red <= 0; green <= 0; blue <= 0; vs <= 0; hs <= 0; de <= 0;
    end else if (pair_toggle != seen_toggle) begin
        seen_toggle <= pair_toggle;
        {red,green,blue} <= pair_data[23:0];
        second_rgb <= pair_data[55:32];
        saved_vs <= pair_vs; saved_hs <= pair_hs; saved_de <= pair_de;
        vs <= pair_vs; hs <= pair_hs; de <= pair_de;
        second_pending <= 1;
    end else begin
        {red,green,blue} <= second_rgb;
        vs <= saved_vs; hs <= saved_hs;
        de <= saved_de && second_pending;
        second_pending <= 0;
    end
end
endmodule
