// APB registers; ENGINE_ENABLE selects the Checkpoint C command/status map.
// Default 0 retains the Checkpoint B standalone test contract.
// PADDR is a byte offset within the Sapphire APB slave window, zero-extended
// by the integration wrapper if the generated bus is narrower than 32 bits.
module accel_regs #(
    parameter WAIT_CYCLES = 1,
    parameter ENGINE_ENABLE = 0,
    parameter DOUBLE_BUFFER = 0,
    parameter BLIT_ENABLE = 0,
    parameter [31:0] FRAME_WIDTH = 1920,
    parameter [31:0] FRAME_HEIGHT = 1080,
    parameter [31:0] FRAME_STRIDE = 7680,
    parameter COLOR_KEY_ENABLE = 0,
    parameter CPU_DDR_ENABLE = 0,
    parameter ALPHA_ENABLE = 0
)(
    input wire PCLK,
    input wire PRESETn,
    input wire [31:0] PADDR,
    input wire PSEL,
    input wire PENABLE,
    input wire PWRITE,
    input wire [31:0] PWDATA,
    output reg [31:0] PRDATA,
    output wire PREADY,
    output wire PSLVERROR,
    input wire [31:0] display_buffer_base,
    input wire [31:0] tpg_write_buffer_base,
    input wire init_done,input wire [31:0] init_error,
    input wire engine_busy,engine_done,input wire [31:0] engine_error,command_count,
    input wire [31:0] init_data_beats,init_aw_bursts,init_wlast_bursts,init_b_responses,init_aw_beats,
    output reg [31:0] cmd_x,cmd_y,cmd_width,cmd_height,cmd_color,
    output reg [31:0] cmd_op,cmd_src_addr,cmd_src_stride,
    input wire draw_ready,input wire [31:0] buffer_status,
    input wire [31:0] reader_frame_base,reader_outstanding,reader_data_beats,reader_reserved_beats,reader_error,
    input wire [31:0] boundary_count,swap_count,missed_boundary_count,
    input wire [31:0] service_status,writer_throttle_cycles,writer_bursts,
    input wire [31:0] reader_ar_stall_cycles,reader_ar_max_stall,reader_r_stall_cycles,
    input wire [31:0] reader_r_max_stall,display_underflow_count,reader_frame_completions,
    input wire [31:0] reader_fifo_level,writer_max_cycles,service_read_quota,
    input wire [31:0] service_watermarks,
    output reg swap_request,clear_swap_done,
    output reg start_pulse,
    input wire [31:0] cpu_ddr_status,
    input wire cpu_ddr_busy,
    input wire [31:0] cpu_ddr_error,
    output reg cpu_ddr_acquire,cpu_ddr_release,cpu_ddr_clear_error,
    input wire [31:0] asset_status,
    output reg asset_begin,asset_seal,
    input wire [31:0] sprite_status,
    output reg sprite_begin,sprite_seal
);
localparam [31:0] ID = 32'h4143434C; // "ACCL"
localparam [31:0] VERSION = 32'h00010000;
localparam WAIT_BITS = (WAIT_CYCLES > 0) ? $clog2(WAIT_CYCLES+1) : 1;
reg [WAIT_BITS-1:0] wait_remaining;
reg [31:1] control;
reg [31:0] rect_x, rect_y, rect_width, rect_height, rect_color, scratch;
reg [31:0] command_op,source_addr,source_stride;
reg start_seen;
reg [31:0] error_code;
reg mapped, writable;
reg [31:0] transaction_error;
wire accept = PSEL && PENABLE && PREADY;

always @(*) begin
    PRDATA = 0;
    mapped = 1;
    writable = 0;
    case (PADDR)
        32'h00: PRDATA = ID;
        32'h04: PRDATA = ALPHA_ENABLE ? 32'h00060000 : COLOR_KEY_ENABLE ? 32'h00050000 : BLIT_ENABLE ? 32'h00040000 : DOUBLE_BUFFER ? 32'h00030000 : ENGINE_ENABLE ? 32'h00020000 : VERSION;
        32'h08: begin PRDATA = {control,1'b0}; writable = 1; end
        32'h0C: PRDATA = ENGINE_ENABLE ?
            {27'b0,init_done,init_done,(init_error!=0 || engine_error!=0 || error_code!=0 || (DOUBLE_BUFFER && reader_error!=0)),engine_done,engine_busy} :
            {30'b0,start_seen,1'b0};
        32'h10: begin PRDATA = rect_x; writable = 1; end
        32'h14: begin PRDATA = rect_y; writable = 1; end
        32'h18: begin PRDATA = rect_width; writable = 1; end
        32'h1C: begin PRDATA = rect_height; writable = 1; end
        32'h20: begin PRDATA = rect_color; writable = 1; end
        32'h24: PRDATA = ENGINE_ENABLE && init_error!=0 ? init_error :
            ENGINE_ENABLE && engine_error!=0 ? engine_error : DOUBLE_BUFFER && reader_error!=0 ? reader_error : error_code;
        32'h28: begin PRDATA = scratch; writable = 1; end
        32'h2C: PRDATA = display_buffer_base;
        32'h30: PRDATA = tpg_write_buffer_base;
        32'h34: PRDATA = FRAME_STRIDE;
        32'h38: PRDATA = FRAME_WIDTH;
        32'h3C: PRDATA = FRAME_HEIGHT;
        32'h40: PRDATA = ALPHA_ENABLE ? 32'h000001FB : COLOR_KEY_ENABLE ? 32'h000000FB : BLIT_ENABLE ? 32'h0000007B : DOUBLE_BUFFER ? 32'h0000003B : ENGINE_ENABLE ? 32'h0000001B : 32'h00000007;
        32'h44: begin PRDATA=init_data_beats;if(!ENGINE_ENABLE) mapped=0;end
        32'h48: begin PRDATA=init_aw_bursts;if(!ENGINE_ENABLE) mapped=0;end
        32'h4C: begin PRDATA=init_wlast_bursts;if(!ENGINE_ENABLE) mapped=0;end
        32'h50: begin PRDATA=init_b_responses;if(!ENGINE_ENABLE) mapped=0;end
        32'h54: begin PRDATA=init_aw_beats;if(!ENGINE_ENABLE) mapped=0;end
        32'h58: begin PRDATA={31'b0,init_done};if(!ENGINE_ENABLE) mapped=0;end
        32'h5C: begin PRDATA=command_count;if(!ENGINE_ENABLE) mapped=0;end
        32'h60: begin PRDATA=0;writable=1;if(!DOUBLE_BUFFER) mapped=0;end
        32'h64: begin PRDATA=buffer_status;if(!DOUBLE_BUFFER) mapped=0;end
        32'h68: begin PRDATA=reader_frame_base;if(!DOUBLE_BUFFER) mapped=0;end
        32'h6C: begin PRDATA=reader_outstanding;if(!DOUBLE_BUFFER) mapped=0;end
        32'h70: begin PRDATA=reader_data_beats;if(!DOUBLE_BUFFER) mapped=0;end
        32'h74: begin PRDATA=reader_reserved_beats;if(!DOUBLE_BUFFER) mapped=0;end
        32'h78: begin PRDATA=reader_error;if(!DOUBLE_BUFFER) mapped=0;end
        32'h7C: begin PRDATA=boundary_count;if(!DOUBLE_BUFFER) mapped=0;end
        32'h80: begin PRDATA=swap_count;if(!DOUBLE_BUFFER) mapped=0;end
        32'h84: begin PRDATA=missed_boundary_count;if(!DOUBLE_BUFFER) mapped=0;end
        32'h88: begin PRDATA=service_status;if(!DOUBLE_BUFFER) mapped=0;end
        32'h8C: begin PRDATA=writer_throttle_cycles;if(!DOUBLE_BUFFER) mapped=0;end
        32'h90: begin PRDATA=writer_bursts;if(!DOUBLE_BUFFER) mapped=0;end
        32'h94: begin PRDATA=reader_ar_stall_cycles;if(!DOUBLE_BUFFER) mapped=0;end
        32'h98: begin PRDATA=reader_ar_max_stall;if(!DOUBLE_BUFFER) mapped=0;end
        32'h9C: begin PRDATA=reader_r_stall_cycles;if(!DOUBLE_BUFFER) mapped=0;end
        32'hA0: begin PRDATA=reader_r_max_stall;if(!DOUBLE_BUFFER) mapped=0;end
        32'hA4: begin PRDATA=display_underflow_count;if(!DOUBLE_BUFFER) mapped=0;end
        32'hA8: begin PRDATA=reader_frame_completions;if(!DOUBLE_BUFFER) mapped=0;end
        32'hAC: begin PRDATA=reader_fifo_level;if(!DOUBLE_BUFFER) mapped=0;end
        32'hB0: begin PRDATA=writer_max_cycles;if(!DOUBLE_BUFFER) mapped=0;end
        32'hB4: begin PRDATA=service_read_quota;if(!DOUBLE_BUFFER) mapped=0;end
        32'hB8: begin PRDATA=service_watermarks;if(!DOUBLE_BUFFER) mapped=0;end
        32'hBC: begin PRDATA=command_op;writable=1;if(!BLIT_ENABLE) mapped=0;end
        32'hC0: begin PRDATA=source_addr;writable=1;if(!BLIT_ENABLE) mapped=0;end
        32'hC4: begin PRDATA=source_stride;writable=1;if(!BLIT_ENABLE) mapped=0;end
        32'hCC: begin PRDATA=0;writable=1;if(!CPU_DDR_ENABLE) mapped=0;end
        32'hD0: begin PRDATA=cpu_ddr_status | {30'b0,cpu_ddr_busy,1'b0};if(!CPU_DDR_ENABLE) mapped=0;end
        32'hD4: begin PRDATA=cpu_ddr_error;if(!CPU_DDR_ENABLE) mapped=0;end
        32'hD8: begin PRDATA=0;writable=1;if(!CPU_DDR_ENABLE) mapped=0;end
        32'hDC: begin PRDATA=asset_status;if(!CPU_DDR_ENABLE) mapped=0;end
        32'hE0: begin PRDATA=0;writable=1;if(!ALPHA_ENABLE) mapped=0;end
        32'hE4: begin PRDATA=sprite_status;if(!ALPHA_ENABLE) mapped=0;end
        default: mapped = 0;
    endcase
    if (|PADDR[1:0]) transaction_error = 1;
    else if (!mapped) transaction_error = 2;
    else if (PWRITE && !writable) transaction_error = 3;
    else if(ENGINE_ENABLE && PWRITE && PADDR==8 && PWDATA[0] && !init_done) transaction_error=4;
    else if(ENGINE_ENABLE && PWRITE && PADDR==8 && PWDATA[0] && (engine_busy || start_pulse)) transaction_error=5;
    else if(DOUBLE_BUFFER && PWRITE && PADDR==8 && PWDATA[0] && !draw_ready) transaction_error=6;
    else if(DOUBLE_BUFFER && PWRITE && PADDR=='h60 && PWDATA[0] && !buffer_status[4]) transaction_error=4;
    else if(DOUBLE_BUFFER && PWRITE && PADDR=='h60 && PWDATA[0] && (buffer_status[2] || swap_request)) transaction_error=6;
    else if(BLIT_ENABLE && PWRITE && PADDR=='h60 && PWDATA[0] && reader_error!=0) transaction_error=6;
    else if(CPU_DDR_ENABLE && PWRITE && PADDR==8 && PWDATA[0] &&
            (cpu_ddr_status[0] || cpu_ddr_acquire)) transaction_error=6;
    else if(CPU_DDR_ENABLE && PWRITE && PADDR=='h60 && PWDATA[0] &&
            (cpu_ddr_status[0] || cpu_ddr_acquire)) transaction_error=6;
    else if(CPU_DDR_ENABLE && PWRITE && PADDR=='h60 && PWDATA[0] &&
            (cpu_ddr_error!=0 || cpu_ddr_status[2])) transaction_error=6;
    else if(CPU_DDR_ENABLE && PWRITE && PADDR=='hCC && PWDATA[0] &&
            (!draw_ready || cpu_ddr_status[0] || cpu_ddr_acquire)) transaction_error=6;
    else if(CPU_DDR_ENABLE && PWRITE && PADDR=='hCC && PWDATA[1:0]==2'b11) transaction_error=3;
    else if(CPU_DDR_ENABLE && PWRITE && PADDR=='hD8 &&
            (PWDATA[31:2]!=0 || PWDATA[1:0]==0 || PWDATA[1:0]==2'b11)) transaction_error=3;
    else if(CPU_DDR_ENABLE && PWRITE && PADDR=='hD8 && PWDATA[0] &&
            (asset_status[0] || asset_status[1] || cpu_ddr_status[0] || cpu_ddr_busy ||
             engine_busy || buffer_status[2] || !init_done || cpu_ddr_error!=0 ||
             cpu_ddr_status[2] || reader_error!=0)) transaction_error=6;
    else if(CPU_DDR_ENABLE && PWRITE && PADDR=='hD8 && PWDATA[1] &&
            (!asset_status[0] || asset_status[1] || cpu_ddr_status[0] || cpu_ddr_busy ||
             engine_busy || buffer_status[2] || cpu_ddr_error!=0 ||
             cpu_ddr_status[2] || reader_error!=0)) transaction_error=6;
    else if(ALPHA_ENABLE && PWRITE && PADDR=='hE0 &&
            (PWDATA[31:2]!=0 || PWDATA[1:0]==0 || PWDATA[1:0]==2'b11)) transaction_error=3;
    else if(ALPHA_ENABLE && PWRITE && PADDR=='hE0 &&
            (cpu_ddr_status[0] || cpu_ddr_busy || cpu_ddr_acquire ||
             engine_busy || buffer_status[2] || !init_done || cpu_ddr_error!=0 ||
             cpu_ddr_status[2] || reader_error!=0 || asset_status[0] || !asset_status[1])) transaction_error=6;
    else if(ALPHA_ENABLE && PWRITE && PADDR=='hE0 && PWDATA[0] &&
            (sprite_status[0] || sprite_status[1])) transaction_error=6;
    else if(ALPHA_ENABLE && PWRITE && PADDR=='hE0 && PWDATA[1] &&
            (!sprite_status[0] || sprite_status[1])) transaction_error=6;
    else if(ALPHA_ENABLE && PWRITE && PADDR=='hD8 && sprite_status[0]) transaction_error=6;
    else transaction_error = 0;
    if (transaction_error != 0) PRDATA = 0;
end

assign PREADY = PRESETn && PSEL && PENABLE && (wait_remaining == 0);
assign PSLVERROR = accept && (transaction_error != 0);
always @(posedge PCLK or negedge PRESETn) begin
    if (!PRESETn) begin
        wait_remaining <= 0;
        control <= 0;
        rect_x <= 0;
        rect_y <= 0;
        rect_width <= 0;
        rect_height <= 0;
        rect_color <= 0;
        scratch <= 0;
        start_seen <= 0;
        start_pulse <= 0;swap_request<=0;clear_swap_done<=0;
        cpu_ddr_acquire<=0;cpu_ddr_release<=0;cpu_ddr_clear_error<=0;
        asset_begin<=0;asset_seal<=0;
        sprite_begin<=0;sprite_seal<=0;
        error_code <= 0;
        cmd_x<=0;cmd_y<=0;cmd_width<=0;cmd_height<=0;cmd_color<=0;
        command_op<=0;source_addr<=0;source_stride<=0;
        cmd_op<=0;cmd_src_addr<=0;cmd_src_stride<=0;
    end else begin
        start_pulse <= 0;swap_request<=0;clear_swap_done<=0;
        cpu_ddr_acquire<=0;cpu_ddr_release<=0;cpu_ddr_clear_error<=0;
        asset_begin<=0;asset_seal<=0;
        sprite_begin<=0;sprite_seal<=0;
        // Setup loads the wait count; each access wait consumes one cycle.
        // Side effects occur only on the final access edge, never in setup.
        if (PSEL && !PENABLE) wait_remaining <= WAIT_CYCLES;
        else if (PSEL && PENABLE && wait_remaining != 0)
            wait_remaining <= wait_remaining - 1'b1;
        if (accept) begin
            if (transaction_error != 0) error_code <= transaction_error;
            else if (PWRITE) begin
                case (PADDR)
                    32'h08: begin
                        control <= PWDATA[31:1];
                        if(ENGINE_ENABLE && PWDATA[1]) error_code<=0;
                        if (PWDATA[0]) begin
                            if(ENGINE_ENABLE) error_code<=0;
                            cmd_x<=rect_x;cmd_y<=rect_y;cmd_width<=rect_width;cmd_height<=rect_height;cmd_color<=rect_color;
                            cmd_op<=command_op;cmd_src_addr<=source_addr;cmd_src_stride<=source_stride;
                            start_pulse <= 1;
                            start_seen <= 1;
                        end
                    end
                    32'h60: if(DOUBLE_BUFFER) begin swap_request<=PWDATA[0];clear_swap_done<=PWDATA[1];end
                    32'h10: rect_x <= PWDATA;
                    32'h14: rect_y <= PWDATA;
                    32'h18: rect_width <= PWDATA;
                    32'h1C: rect_height <= PWDATA;
                    32'h20: rect_color <= PWDATA;
                    32'h28: scratch <= PWDATA;
                    32'hBC: command_op <= PWDATA;
                    32'hC0: source_addr <= PWDATA;
                    32'hC4: source_stride <= PWDATA;
                    32'hCC: begin
                        cpu_ddr_acquire<=PWDATA[0];
                        cpu_ddr_release<=PWDATA[1];
                        cpu_ddr_clear_error<=PWDATA[2];
                    end
                    32'hD8: begin asset_begin<=PWDATA[0];asset_seal<=PWDATA[1];end
                    32'hE0: begin sprite_begin<=PWDATA[0];sprite_seal<=PWDATA[1];end
                    default: begin end
                endcase
            end
        end
    end
end
// synthesis translate_off
initial if (WAIT_CYCLES < 0) $fatal(1,"WAIT_CYCLES must be nonnegative");
initial if (BLIT_ENABLE && (!ENGINE_ENABLE || !DOUBLE_BUFFER))
    $fatal(1,"BLIT registers require the double-buffered graphics engine");
initial if (COLOR_KEY_ENABLE && !BLIT_ENABLE)
    $fatal(1,"Color-key registers require BLIT support");
initial if (ALPHA_ENABLE && (!COLOR_KEY_ENABLE || !CPU_DDR_ENABLE))
    $fatal(1,"Alpha registers require color key and CPU DDR support");
// synthesis translate_on
endmodule
