`timescale 1ns/1ps
// Simulation-only AXI128 memory. Both physical slots are readable/writable;
// swapping changes roles in the manager, never the stored pixels here.
module graphics_double_buffer_memory #(
    parameter FRAME_WORDS = 64*48,
    parameter [31:0] BUFFER0_BASE = 32'h00000000,
    parameter [31:0] BUFFER1_BASE = 32'h00800000
)(
    input wire clk, rst_n,
    input wire stall_ar, stall_b,
    input wire [31:0] araddr, awaddr,
    input wire [7:0] arlen, awlen,
    input wire arvalid, awvalid,
    output wire arready, awready,
    output reg [127:0] rdata,
    output wire [3:0] rid,
    output wire [1:0] rresp,
    output reg rlast, rvalid,
    input wire rready,
    input wire [127:0] wdata,
    input wire [15:0] wstrb,
    input wire wlast, wvalid,
    output wire wready,
    output wire [3:0] bid,
    output wire [1:0] bresp,
    output reg bvalid,
    input wire bready,
    output reg [31:0] ar_count, r_count, aw_count, w_count, b_count,
    output wire idle
);
reg [31:0] pixels [0:2*FRAME_WORDS-1];
reg read_active, write_active;
integer tick, read_index, write_index, read_left, write_left, b_delay, lane;
reg held_r_stall, held_b_stall;
reg [128:0] held_r;

// Resolve physical addresses without allocating the 8 MiB hole between slots.
function integer pixel_index;
input [31:0] address;
begin
    if ({32'b0,address} >= {32'b0,BUFFER0_BASE} &&
        {32'b0,address} < {32'b0,BUFFER0_BASE}+FRAME_WORDS*4)
        pixel_index = (address-BUFFER0_BASE)/4;
    else if ({32'b0,address} >= {32'b0,BUFFER1_BASE} &&
             {32'b0,address} < {32'b0,BUFFER1_BASE}+FRAME_WORDS*4)
        pixel_index = FRAME_WORDS+(address-BUFFER1_BASE)/4;
    else pixel_index = -1;
end
endfunction

task check_burst;
input [31:0] address;
input [7:0] length;
integer first_pixel, last_pixel;
reg [63:0] end_address;
begin
    end_address = {32'b0,address}+(length+1)*16;
    first_pixel = pixel_index(address);
    last_pixel = pixel_index(end_address[31:0]-4);
    if (address[3:0] != 0 || length >= 32 || end_address > 64'h100000000 ||
        {1'b0,address[11:0]}+(length+1)*16 > 4096 || first_pixel < 0 ||
        last_pixel != first_pixel+(length+1)*4-1 ||
        first_pixel/FRAME_WORDS != last_pixel/FRAME_WORDS)
        $fatal(1,"Illegal two-slot burst addr=%h len=%0d",address,length);
end
endtask

assign rid = 0;
assign rresp = 0;
assign bid = 0;
assign bresp = 0;
assign idle = !read_active && !rvalid && !write_active && !bvalid && b_delay == 0;
assign arready = idle && !stall_ar && tick%5 != 0;
assign awready = idle && tick%7 != 0;
assign wready = write_active && tick%3 != 0;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        read_active <= 0; write_active <= 0;
        rdata <= 0; rlast <= 0; rvalid <= 0; bvalid <= 0;
        tick <= 0; read_index <= 0; write_index <= 0;
        read_left <= 0; write_left <= 0; b_delay <= 0;
        ar_count <= 0; r_count <= 0; aw_count <= 0; w_count <= 0; b_count <= 0;
        held_r_stall <= 0; held_b_stall <= 0; held_r <= 0;
    end else begin
        tick <= tick+1;
        if (held_r_stall && (!rvalid || {rdata,rlast} !== held_r))
            $fatal(1,"Two-slot memory changed stalled R");
        if (held_b_stall && !bvalid) $fatal(1,"Two-slot memory withdrew stalled B");
        held_r_stall <= rvalid && !rready; held_r <= {rdata,rlast};
        held_b_stall <= bvalid && !bready;

        if (arvalid && arready) begin
            check_burst(araddr,arlen);
            if (!idle || awvalid) $fatal(1,"Overlapping two-slot transactions");
            read_active <= 1; read_index <= pixel_index(araddr); read_left <= arlen+1;
            ar_count <= ar_count+1;
        end
        if (read_active && !rvalid && tick%4 != 0) begin
            for (lane=0; lane<4; lane=lane+1)
                rdata[lane*32+:32] <= pixels[read_index+lane];
            rlast <= read_left == 1; rvalid <= 1;
        end
        if (rvalid && rready) begin
            rvalid <= 0; read_index <= read_index+4; read_left <= read_left-1;
            r_count <= r_count+1;
            if (read_left == 1) read_active <= 0;
        end
        if (awvalid && awready) begin
            check_burst(awaddr,awlen);
            if (!idle || arvalid) $fatal(1,"AW before prior transaction drained");
            write_active <= 1; write_index <= pixel_index(awaddr); write_left <= awlen+1;
            aw_count <= aw_count+1;
        end
        if (wvalid && wready) begin
            if (wlast !== (write_left == 1)) $fatal(1,"Two-slot WLAST mismatch");
            for (lane=0; lane<16; lane=lane+1)
                if (wstrb[lane])
                    pixels[write_index+lane/4][(lane%4)*8+:8] <= wdata[lane*8+:8];
            write_index <= write_index+4; write_left <= write_left-1;
            w_count <= w_count+1;
            if (write_left == 1) begin write_active <= 0; b_delay <= 9; end
        end
        // stall_b delays publication of B, and never retracts an exposed VALID.
        if (b_delay != 0 && !stall_b) begin
            b_delay <= b_delay-1;
            if (b_delay == 1) bvalid <= 1;
        end
        if (bvalid && bready) begin bvalid <= 0; b_count <= b_count+1; end
    end
end
endmodule
