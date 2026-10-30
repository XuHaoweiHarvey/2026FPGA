// Platform-owned state: CPU/APB debug reset must not reset this module.
module buffer_manager #(
    parameter [31:0] BUFFER0_BASE=32'h00000000,BUFFER1_BASE=32'h00800000,
    parameter FLUSH_CYCLES=8
)(
    input wire clk,rst_n,init_done,
    input wire cmd_request,writer_busy,writer_done,input wire [31:0] writer_error,
    input wire swap_request,clear_done,boundary_tick,blank_active,reader_safe,reader_fifo_empty,
    output wire command_accept,draw_ready,
    output reg writer_owned,front_index,back_index,front_valid,swap_pending,swap_done,
    output wire [31:0] front_base,back_base,
    output reg [31:0] command_base,reader_base,
    output wire reader_flush,output reg reader_launch,
    output reg [31:0] boundary_count,swap_count,missed_boundary_count
);
localparam IDLE=0,FLUSH=1,RELEASE=2;
reg [1:0] state;
reg [7:0] flush_left;
reg commit_swap;
assign front_base=front_index?BUFFER1_BASE:BUFFER0_BASE;
assign back_base=back_index?BUFFER1_BASE:BUFFER0_BASE;
assign draw_ready=front_valid && !swap_pending && !swap_request && !writer_busy && !writer_owned;
assign command_accept=cmd_request && draw_ready;
assign reader_flush=state==FLUSH;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        writer_owned<=0;front_index<=0;back_index<=1;front_valid<=0;
        swap_pending<=0;swap_done<=0;command_base<=BUFFER1_BASE;reader_base<=BUFFER0_BASE;
        reader_launch<=0;state<=IDLE;flush_left<=0;commit_swap<=0;
        boundary_count<=0;swap_count<=0;missed_boundary_count<=0;
    end else begin
        reader_launch<=0;
        if(init_done) front_valid<=1;
        if(clear_done) swap_done<=0;
        if(swap_request && front_valid) swap_pending<=1;
        if(command_accept) begin command_base<=back_base;writer_owned<=1;end
        else if(writer_owned && writer_done && !writer_busy) writer_owned<=0;
        if(boundary_tick) begin
            boundary_count<=boundary_count+1;
            if(front_valid && !reader_safe) missed_boundary_count<=missed_boundary_count+1;
        end
        case(state)
        IDLE: if(boundary_tick && blank_active && front_valid && reader_safe && !reader_launch) begin
            // Snapshot the swap decision only at the boundary. A writer that
            // finishes later in this VS must wait for the next boundary.
            commit_swap<=swap_pending && !writer_busy && !writer_owned && !cmd_request && writer_error==0;
            flush_left<=FLUSH_CYCLES-1;state<=FLUSH;
        end
        FLUSH: if(flush_left==0) state<=RELEASE;else flush_left<=flush_left-1'b1;
        RELEASE: begin
            if(!blank_active) begin
                // Missed the blanking window: never launch mid-frame or swap late.
                state<=IDLE;commit_swap<=0;missed_boundary_count<=missed_boundary_count+1;
            end else if(reader_fifo_empty && reader_safe) begin
                if(commit_swap) begin
                    front_index<=back_index;back_index<=front_index;
                    reader_base<=back_base;
                    swap_pending<=0;swap_done<=1;swap_count<=swap_count+1;
                end else reader_base<=front_base;
                reader_launch<=1;state<=IDLE;
            end
        end
        default:state<=IDLE;
        endcase
    end
end
// synthesis translate_off
initial if(BUFFER0_BASE==BUFFER1_BASE || BUFFER0_BASE[11:0]!=0 || BUFFER1_BASE[11:0]!=0 ||
           FLUSH_CYCLES<4 || FLUSH_CYCLES>255) $fatal(1,"Invalid double buffer parameters");
always @(posedge clk) if(rst_n && front_index==back_index) $fatal(1,"Front equals Back");
// synthesis translate_on
endmodule
