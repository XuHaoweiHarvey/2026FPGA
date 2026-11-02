`timescale 1ns/1ps
// Two read clients, ID0, one GLOBAL outstanding burst. Platform reset only.
// No FIFO flush, launch or enable change can cancel an exposed AR or its R.
module ddr_read_arbiter #(
    parameter FIFO_LOW=384, FIFO_HIGH=512, OUTSTANDING=1
)(
    input wire clk, rst_n, enabled,
    input wire display_active, display_launch, display_flush,
    input wire [31:0] display_fifo_level,

    input wire [31:0] display_araddr,
    input wire [7:0] display_arlen,
    input wire display_arvalid,
    output wire display_arready,
    output wire [127:0] display_rdata,
    output wire [3:0] display_rid,
    output wire [1:0] display_rresp,
    output wire display_rlast, display_rvalid,
    input wire display_rready,

    input wire [31:0] blit_araddr,
    input wire [7:0] blit_arlen,
    input wire blit_arvalid,
    output wire blit_arready,
    output wire [127:0] blit_rdata,
    output wire [3:0] blit_rid,
    output wire [1:0] blit_rresp,
    output wire blit_rlast, blit_rvalid,
    input wire blit_rready,

    output wire [31:0] araddr,
    output wire [7:0] arlen,
    output wire [3:0] arid, arcache, arqos,
    output wire [2:0] arsize, arprot,
    output wire [1:0] arburst,
    output wire arlock, arvalid,
    input wire arready,
    input wire [127:0] rdata,
    input wire [3:0] rid,
    input wire [1:0] rresp,
    input wire rlast, rvalid,
    output wire rready,

    output reg address_pending, read_active, owner_blit,
    output wire busy, display_urgent,
    output reg fault,
    output reg [31:0] fault_code,
    output reg [8:0] beats_left,
    output reg [31:0] display_bursts, blit_bursts, display_beats, blit_beats
);
generate if(OUTSTANDING==1) begin: serial
// Local diagnostics, not new APB ERROR_CODE assignments.
localparam [31:0] FAULT_UNEXPECTED_R=1, FAULT_RLAST=2;
reg healthy, prefer_blit;
reg [31:0] saved_addr;
reg [7:0] saved_len;
wire af=arvalid && arready;
// AXI permits a first R on the same edge as its AR handshake. The pending
// address already has a fixed owner; bypass only on that actual handshake.
wire response_owned=rst_n && (read_active || af);
wire [8:0] response_left=read_active ? beats_left : {1'b0,saved_len}+9'd1;
wire rf=rvalid && rready;
wire unexpected_r=rvalid && !response_owned;
wire bad_last=rf && (response_left==0 || rlast!=(response_left==1));
wire choose_blit=blit_arvalid &&
    (!display_arvalid || (!display_urgent && prefer_blit));

assign busy=address_pending || read_active;
// Immediate low-water/launch/flush priority; HIGH re-enables normal rotation.
assign display_urgent=display_active &&
    (!healthy || display_fifo_level<=FIFO_LOW || display_launch || display_flush);
assign araddr=saved_addr;
assign arlen=saved_len;
assign arvalid=rst_n && address_pending;
assign arid=0; assign arsize=4; assign arburst=1;
assign arcache=3; assign arprot=2; assign arlock=0; assign arqos=0;
// Upstream AR is accepted only when DDR accepts that same saved request.
assign display_arready=arvalid && !owner_blit && arready;
assign blit_arready=arvalid && owner_blit && arready;
assign display_rvalid=response_owned && !owner_blit && rvalid;
assign blit_rvalid=response_owned && owner_blit && rvalid;
assign display_rdata=response_owned && !owner_blit ? rdata : 128'b0;
assign blit_rdata=response_owned && owner_blit ? rdata : 128'b0;
assign display_rid=response_owned && !owner_blit ? rid : 4'b0;
assign blit_rid=response_owned && owner_blit ? rid : 4'b0;
assign display_rresp=response_owned && !owner_blit ? rresp : 2'b0;
assign blit_rresp=response_owned && owner_blit ? rresp : 2'b0;
assign display_rlast=response_owned && !owner_blit && rlast;
assign blit_rlast=response_owned && owner_blit && rlast;
assign rready=response_owned && (owner_blit ? blit_rready : display_rready);

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        address_pending<=0; read_active<=0; owner_blit<=0;
        healthy<=0; prefer_blit<=0; saved_addr<=0; saved_len<=0;
        fault<=0; fault_code<=0; beats_left<=0;
        display_bursts<=0; blit_bursts<=0; display_beats<=0; blit_beats<=0;
    end else begin
        if(!display_active || display_launch || display_flush || display_fifo_level<=FIFO_LOW)
            healthy<=0;
        else if(display_fifo_level>=FIFO_HIGH) healthy<=1;

        // Register a grant BEFORE exposing ARVALID. Priority can change while
        // waiting for READY, but this owner/address/length must not change.
        // A stray R while idle faults without inventing a new transaction.
        if(!busy && !fault && enabled && !rvalid && (display_arvalid || blit_arvalid)) begin
            address_pending<=1; owner_blit<=choose_blit;
            saved_addr<=choose_blit ? blit_araddr : display_araddr;
            saved_len<=choose_blit ? blit_arlen : display_arlen;
        end
        if(af) begin
            address_pending<=0; read_active<=1;
            beats_left<={1'b0,saved_len}+9'd1;
            if(owner_blit) blit_bursts<=blit_bursts+1'b1;
            else display_bursts<=display_bursts+1'b1;
        end
        if(rf) begin
            // Saturate after malformed missing/extra RLAST instead of wrapping.
            beats_left<=response_left==0 ? 9'd0 : response_left-9'd1;
            if(owner_blit) blit_beats<=blit_beats+1'b1;
            else display_beats<=display_beats+1'b1;
            if(!fault && !bad_last && rlast && response_left==1) begin
                read_active<=0;
                prefer_blit<=!owner_blit;
            end
        end
        // Fault wins over normal release. Keep routing any in-flight R to the
        // original owner; never clear ownership on a malformed RLAST. A fault
        // during stalled AR must also preserve ARVALID until DDR accepts it.
        if(!fault && (unexpected_r || bad_last)) begin
            fault<=1;
            fault_code<=bad_last ? FAULT_RLAST : FAULT_UNEXPECTED_R;
        end
    end
end

end else begin: queued
    // All reads keep ID0: AXI preserves response order for this ID.
    // Reserve space before exposing AR; retain exposed requests on fault.
    localparam PTR=$clog2(OUTSTANDING);
    reg [PTR-1:0] head,tail;
    reg [PTR:0] count;
    reg owners[0:OUTSTANDING-1];
    reg [8:0] remaining[0:OUTSTANDING-1];
    reg pending_owner,healthy,prefer_blit;
    reg [31:0] saved_addr;
    reg [7:0] saved_len;
    wire af=arvalid && arready;
    wire response_owned=count!=0 || af;
    wire response_owner=count!=0 ? owners[head] : pending_owner;
    wire [8:0] response_left=count!=0 ? remaining[head] : {1'b0,saved_len}+9'd1;
    wire rf=rvalid && rready;
    wire bad_last=rf && (response_left==0 || rlast!=(response_left==1));
    wire retire=rf && rlast && response_left==1 && !fault && !bad_last;
    wire choose_blit=blit_arvalid && (!display_arvalid || (!display_urgent && prefer_blit));
    assign busy=address_pending || count!=0;
    assign display_urgent=display_active && (!healthy || display_fifo_level<=FIFO_LOW || display_launch || display_flush);
    assign araddr=saved_addr;assign arlen=saved_len;assign arvalid=rst_n && address_pending;
    assign arid=0;assign arsize=4;assign arburst=1;assign arcache=3;assign arprot=2;assign arlock=0;assign arqos=0;
    assign display_arready=arvalid && !pending_owner && arready;
    assign blit_arready=arvalid && pending_owner && arready;
    assign display_rvalid=rst_n && response_owned && !response_owner && rvalid;
    assign blit_rvalid=rst_n && response_owned && response_owner && rvalid;
    assign display_rdata=display_rvalid ? rdata : 128'b0;
    assign blit_rdata=blit_rvalid ? rdata : 128'b0;
    assign display_rid=display_rvalid ? rid : 4'b0;assign blit_rid=blit_rvalid ? rid : 4'b0;
    assign display_rresp=display_rvalid ? rresp : 2'b0;assign blit_rresp=blit_rvalid ? rresp : 2'b0;
    assign display_rlast=display_rvalid && rlast;assign blit_rlast=blit_rvalid && rlast;
    assign rready=rst_n && response_owned && (response_owner ? blit_rready : display_rready);
    always @* begin read_active=count!=0;owner_blit=response_owner;beats_left=count!=0 ? remaining[head] : 0;end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            head<=0;tail<=0;count<=0;address_pending<=0;pending_owner<=0;
            healthy<=0;prefer_blit<=0;saved_addr<=0;saved_len<=0;fault<=0;fault_code<=0;
            display_bursts<=0;blit_bursts<=0;display_beats<=0;blit_beats<=0;
        end else begin
            if(!display_active || display_launch || display_flush || display_fifo_level<=FIFO_LOW) healthy<=0;
            else if(display_fifo_level>=FIFO_HIGH) healthy<=1;
            if(!address_pending && count<OUTSTANDING && !fault && enabled &&
               !(rvalid && count==0) && (display_arvalid || blit_arvalid)) begin
                address_pending<=1;pending_owner<=choose_blit;
                saved_addr<=choose_blit ? blit_araddr : display_araddr;
                saved_len<=choose_blit ? blit_arlen : display_arlen;
            end
            if(af) begin
                address_pending<=0;owners[tail]<=pending_owner;
                remaining[tail]<={1'b0,saved_len}+9'd1;
                tail<=tail==OUTSTANDING-1 ? 0 : tail+1'b1;
                prefer_blit<=!pending_owner;
                if(pending_owner)blit_bursts<=blit_bursts+1'b1;else display_bursts<=display_bursts+1'b1;
            end
            case({af,retire})
                2'b10:count<=count+1'b1;
                2'b01:count<=count-1'b1;
                default:count<=count;
            endcase
            if(rf) begin
                remaining[head]<=response_left==0 ? 0 : response_left-1'b1;
                if(response_owner)blit_beats<=blit_beats+1'b1;else display_beats<=display_beats+1'b1;
                if(retire)head<=head==OUTSTANDING-1 ? 0 : head+1'b1;
            end
            // Fail-stop on malformed boundaries: never misroute a subsequent
            // response to another owner; platform reset is required.
            if(!fault && ((rvalid && !response_owned) || bad_last)) begin
                fault<=1;fault_code<=bad_last ? 2 : 1;
            end
        end
    end
end endgenerate

// RRESP/RID pass through to the owning master (including errors); a correctly
// sized burst can drain and retire. There is no timeout that cancels a DMA.
// synthesis translate_off
initial if(FIFO_LOW<1 || FIFO_HIGH<=FIFO_LOW || OUTSTANDING<1 || OUTSTANDING>8)
    $fatal(1,"Invalid read arbiter watermarks");
// synthesis translate_on
endmodule
