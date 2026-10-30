// Small in-order descriptor FIFO between the APB command registers and the
// single graphics DMA engine. Push acknowledges queue admission; pop transfers
// the head descriptor to the engine. A downstream error flushes pending work.
module graphics_command_queue #(
    parameter DEPTH=8,
    parameter WIDTH=256
)(
    input wire clk,rst_n,enable,
    input wire push,input wire [WIDTH-1:0] push_data,output wire ready,
    input wire pop,output wire valid,output wire [WIDTH-1:0] head_data,
    input wire flush,output reg [$clog2(DEPTH+1)-1:0] count,
    output reg [31:0] accepted_count
);
localparam PTR_BITS=(DEPTH>1)?$clog2(DEPTH):1;
reg [WIDTH-1:0] entries [0:DEPTH-1];
reg [PTR_BITS-1:0] read_ptr,write_ptr;
reg [WIDTH-1:0] head_reg;
assign ready=enable && count<DEPTH;
assign valid=enable && count!=0;
assign head_data=head_reg;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        read_ptr<=0;write_ptr<=0;count<=0;accepted_count<=0;head_reg<=0;
    end else if(enable) begin
        if(flush) begin
            read_ptr<=write_ptr;
            count<=0;
            head_reg<=0;
        end else begin
            if(push && ready) begin
                entries[write_ptr]<=push_data;
                write_ptr<=write_ptr==DEPTH-1 ? 0 : write_ptr+1'b1;
                accepted_count<=accepted_count+1'b1;
                if(count==0 && !(pop && valid)) head_reg<=push_data;
            end
            if(pop && valid) begin
                read_ptr<=read_ptr==DEPTH-1 ? 0 : read_ptr+1'b1;
                if(count>1) head_reg<=entries[read_ptr==DEPTH-1 ? 0 : read_ptr+1'b1];
                else if(push && ready) head_reg<=push_data;
                else head_reg<=0;
            end
            case({push && ready,pop && valid})
                2'b10: count<=count+1'b1;
                2'b01: count<=count-1'b1;
                default: count<=count;
            endcase
        end
    end
end
// synthesis translate_off
initial if(DEPTH<2 || DEPTH>256) $fatal(1,"Command queue depth must be 2..256");
// synthesis translate_on
endmodule
