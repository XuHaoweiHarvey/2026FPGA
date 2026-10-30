`timescale 1ns/1ps
module tb_alpha_pixel_pipeline;
reg clk=0,rst_n=0,in_valid=0;
reg [127:0] fg=0,bg=0;
reg [7:0] global_alpha=0;
wire out_valid;
wire [127:0] result;
integer cases=0,i,j,lane,ch,pa,ga,sv,dv,ae,want;
reg [31:0] rng=32'h5eeda11;
always #5 clk=~clk;
alpha_pixel_pipeline dut(.clk(clk),.rst_n(rst_n),.in_valid(in_valid),
    .foreground(fg),.background(bg),.global_alpha(global_alpha),
    .out_valid(out_valid),.result(result));

function integer div255_ref;
input integer n;
begin div255_ref=n/255;end
endfunction
function integer endpoint;
input integer index;
begin
    case(index) 0:endpoint=0;1:endpoint=1;2:endpoint=128;
        3:endpoint=254;default:endpoint=255;endcase
end
endfunction

task run_case;
input integer pixel_alpha,overall_alpha,src_seed,dst_seed;
begin
    @(negedge clk);in_valid=1;global_alpha=overall_alpha;
    for(lane=0;lane<4;lane=lane+1) begin
        fg[lane*32+24+:8]=pixel_alpha[7:0];
        fg[lane*32+16+:8]=(src_seed+lane*31)&255;
        fg[lane*32+8+:8]=(src_seed+lane*17+1)&255;
        fg[lane*32+:8]=(src_seed+lane*9+3)&255;
        bg[lane*32+24+:8]=(dst_seed+lane*13)&255;
        bg[lane*32+16+:8]=(dst_seed+lane*7)&255;
        bg[lane*32+8+:8]=(dst_seed+lane*19+5)&255;
        bg[lane*32+:8]=(dst_seed+lane*29+9)&255;
    end
    @(negedge clk);in_valid=0;
    repeat(3) @(negedge clk);
    #1;if(!out_valid)$fatal(1,"Pipeline valid missing");
    ae=div255_ref(pixel_alpha*overall_alpha+127);
    for(lane=0;lane<4;lane=lane+1) begin
        if(result[lane*32+24+:8]!==bg[lane*32+24+:8])
            $fatal(1,"destination X byte changed");
        for(ch=0;ch<3;ch=ch+1) begin
            sv=fg[lane*32+ch*8+:8];dv=bg[lane*32+ch*8+:8];
            want=div255_ref(sv*ae+dv*(255-ae)+127);
            if(result[lane*32+ch*8+:8]!==want[7:0])
                $fatal(1,"pixel mismatch pa=%0d ga=%0d lane=%0d ch=%0d got=%0d want=%0d",
                    pixel_alpha,overall_alpha,lane,ch,result[lane*32+ch*8+:8],want);
        end
    end
    @(negedge clk);cases=cases+1;
end
endtask

initial begin
    repeat(3)@(negedge clk);rst_n=1;
    for(i=0;i<5;i=i+1) for(j=0;j<5;j=j+1)
        run_case(endpoint(i),endpoint(j),19+i*41,251-j*27);
    for(i=0;i<512;i=i+1) begin
        rng=rng*32'd1664525+32'd1013904223;pa=rng[7:0];
        rng=rng*32'd1664525+32'd1013904223;ga=rng[7:0];
        rng=rng*32'd1664525+32'd1013904223;sv=rng[7:0];
        rng=rng*32'd1664525+32'd1013904223;dv=rng[7:0];
        run_case(pa,ga,sv,dv);
    end
    for(i=0;i<=65152;i=i+1)
        if(dut.div255(i)!==(i/255))$fatal(1,"div255 mismatch n=%0d",i);
    $display("PASS ALPHA PIXELS: %0d beat vectors plus all 65,153 div255 inputs",cases);
    $finish;
end
initial begin #1000000;$fatal(1,"Alpha pixel watchdog");end
endmodule
