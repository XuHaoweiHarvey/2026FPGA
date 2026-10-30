`timescale 1ns/1ps
// Exercises the BmbUpSizerBridge module in the user's generated SoC netlist.
module tb_sapphire_ddr_lane;
reg clk=0;always #5 clk=~clk;
reg reset=1,cmd_valid=0,cmd_last=1,cmd_opcode=1,rsp_valid=0;
reg [31:0] cmd_addr=0,cmd_data=0;
reg [3:0] cmd_mask=4'hf;
wire cmd_ready,out_valid,rsp_ready,in_rsp_valid,in_rsp_last;
wire [31:0] out_addr,in_rsp_data;
wire [127:0] out_data;
wire [15:0] out_mask;
wire [4:0] out_context;
reg [4:0] rsp_context=0;
integer i;
BmbUpSizerBridge dut (
    .io_input_cmd_valid(cmd_valid),.io_input_cmd_ready(cmd_ready),
    .io_input_cmd_payload_last(cmd_last),.io_input_cmd_payload_fragment_source(1'b0),
    .io_input_cmd_payload_fragment_opcode(cmd_opcode),
    .io_input_cmd_payload_fragment_address(cmd_addr),
    .io_input_cmd_payload_fragment_length(2'b0),
    .io_input_cmd_payload_fragment_data(cmd_data),
    .io_input_cmd_payload_fragment_mask(cmd_mask),
    .io_input_cmd_payload_fragment_context(1'b0),
    .io_input_rsp_valid(in_rsp_valid),.io_input_rsp_ready(1'b1),
    .io_input_rsp_payload_last(in_rsp_last),
    .io_input_rsp_payload_fragment_data(in_rsp_data),
    .io_output_cmd_valid(out_valid),.io_output_cmd_ready(1'b1),
    .io_output_cmd_payload_fragment_address(out_addr),
    .io_output_cmd_payload_fragment_data(out_data),
    .io_output_cmd_payload_fragment_mask(out_mask),
    .io_output_cmd_payload_fragment_context(out_context),
    .io_output_rsp_valid(rsp_valid),.io_output_rsp_ready(rsp_ready),
    .io_output_rsp_payload_last(1'b1),
    .io_output_rsp_payload_fragment_source(1'b0),
    .io_output_rsp_payload_fragment_opcode(1'b0),
    .io_output_rsp_payload_fragment_data(128'h4433221188776655ccbbaa99ffeeddcc),
    .io_output_rsp_payload_fragment_context(rsp_context),
    .io_systemClk(clk),.systemCd_logic_outputReset(reset)
);
initial begin
    repeat(3) @(posedge clk);@(negedge clk);reset=0;
    for(i=0;i<4;i=i+1) begin
        @(negedge clk);cmd_valid=1;cmd_opcode=1;
        cmd_addr=32'h00801000+i*4;cmd_data=32'hca000000+i;
        #1;
        if(!cmd_ready || !out_valid || out_addr!==cmd_addr ||
           out_mask!==(16'h000f << (i*4)) ||
           (out_data >> (i*32) & 128'hffffffff)!=={96'b0,cmd_data})
            $fatal(1,"Generated upsize write lane %0d address=%h mask=%h",i,out_addr,out_mask);
        @(posedge clk);@(negedge clk);cmd_valid=0;
    end
    for(i=0;i<4;i=i+1) begin
        @(negedge clk);cmd_valid=1;cmd_opcode=0;cmd_addr=32'h00001000+i*4;
        #1;if(!out_valid || out_addr!==cmd_addr) $fatal(1,"Generated read address lane %0d",i);
        rsp_context=out_context;
        @(posedge clk);@(negedge clk);cmd_valid=0;rsp_valid=1;
        #1;
        if(!in_rsp_valid || !in_rsp_last ||
           in_rsp_data!==(128'h4433221188776655ccbbaa99ffeeddcc >> (i*32) & 128'hffffffff))
            $fatal(1,"Generated read lane %0d data=%h",i,in_rsp_data);
        @(posedge clk);@(negedge clk);rsp_valid=0;
    end
    $display("PASS generated Sapphire BMB upsizer: unchanged byte address, four 32-bit WSTRB/data and R lanes");
    $finish;
end
endmodule
