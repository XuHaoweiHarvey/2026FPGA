`timescale 1ns/1ps
// Straight ARGB source over XRGB destination, four pixels per beat.
// Four registered stages; valid is a pulse and the consumer must capture it.
// The destination X byte is preserved, including at both alpha endpoints.
module alpha_pixel_pipeline (
    input wire clk, rst_n, in_valid,
    input wire [127:0] foreground, background,
    input wire [7:0] global_alpha,
    output wire out_valid,
    output wire [127:0] result
);
reg [3:0] valid;
always @(posedge clk or negedge rst_n)
    if (!rst_n) valid <= 0;
    else valid <= {valid[2:0],in_valid};
assign out_valid = valid[3];

// Exact floor(n/255) for 0 <= n <= 65152. Both rounded numerators below
// satisfy this bound. Use addition/shifts instead of a divider in the DSP path.
function [7:0] div255;
    input [15:0] n;
    reg [16:0] t;
    begin t={1'b0,n}+17'd1+{9'b0,n[15:8]};div255=t[15:8];end
endfunction
genvar p,c;
generate for(p=0;p<4;p=p+1) begin: pixels
    reg [31:0] src0,dst0,src1,dst1;
    reg [15:0] alpha_product;
    reg [7:0] effective_alpha;
    reg [7:0] saved_x;
    wire [7:0] inverse_alpha=8'd255-effective_alpha;
    always @(posedge clk) begin
        if(in_valid) begin
            src0<=foreground[p*32+:32];dst0<=background[p*32+:32];
            alpha_product<={8'b0,foreground[p*32+24+:8]}*{8'b0,global_alpha}+16'd127;
        end
        if(valid[0]) begin
            src1<=src0;dst1<=dst0;effective_alpha<=div255(alpha_product);
        end
        if(valid[1]) saved_x<=dst1[31:24];
    end
    reg [7:0] output_x;
    always @(posedge clk) if(valid[2]) output_x<=saved_x;
    assign result[p*32+24+:8]=output_x;
    for(c=0;c<3;c=c+1) begin: channels
        reg [15:0] numerator;
        reg [7:0] output_channel;
        always @(posedge clk) begin
            if(valid[1]) numerator<={8'b0,src1[c*8+:8]}*{8'b0,effective_alpha}+
                {8'b0,dst1[c*8+:8]}*{8'b0,inverse_alpha}+16'd127;
            if(valid[2]) output_channel<=div255(numerator);
        end
        assign result[p*32+c*8+:8]=output_channel;
    end
end endgenerate
endmodule
