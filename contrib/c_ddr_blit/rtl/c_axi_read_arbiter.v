`timescale 1ns/1ps
// One global outstanding read; no CPU reset or display flush input by design.
// d = display, b = BLIT, m = physical DDR. All ports in the core clock domain.
module c_axi_read_arbiter(
    input wire clk,rst_n,display_urgent,external_fault,
    input wire [31:0] d_araddr,b_araddr,
    input wire [7:0] d_arlen,b_arlen,
    input wire d_arvalid,b_arvalid,
    output wire d_arready,b_arready,
    output wire [127:0] d_rdata,b_rdata,
    output wire [3:0] d_rid,b_rid,
    output wire [1:0] d_rresp,b_rresp,
    output wire d_rlast,b_rlast,d_rvalid,b_rvalid,
    input wire d_rready,b_rready,
    output reg [31:0] m_araddr,
    output reg [7:0] m_arlen,
    output wire m_arvalid,
    input wire m_arready,
    input wire [127:0] m_rdata,
    input wire [3:0] m_rid,
    input wire [1:0] m_rresp,
    input wire m_rlast,m_rvalid,
    output wire m_rready,
    output reg fault,
    output wire outstanding,owner_valid,owner_blit,
    output reg [31:0] display_bursts,blit_bursts,blit_wait_cycles
);
localparam IDLE=0,ADDR=1,DATA=2;
reg [1:0] state;
reg selected,last_served;
reg [8:0] beats_left;
wire choose_blit=b_arvalid && (!d_arvalid || (!display_urgent && !last_served));
wire af=m_arvalid && m_arready;
wire rf=m_rvalid && m_rready;
// An exposed AR may NEVER be cancelled, including external FAULT.
assign m_arvalid=state==ADDR;
assign d_arready=state==ADDR && !selected && m_arready;
assign b_arready=state==ADDR && selected && m_arready;
assign d_rvalid=state==DATA && !selected && m_rvalid;
assign b_rvalid=state==DATA && selected && m_rvalid;
assign m_rready=state==DATA && (selected?b_rready:d_rready);
assign d_rdata=d_rvalid?m_rdata:128'b0;
assign b_rdata=b_rvalid?m_rdata:128'b0;
assign d_rid=d_rvalid?m_rid:4'b0;
assign b_rid=b_rvalid?m_rid:4'b0;
assign d_rresp=d_rvalid?m_rresp:2'b0;
assign b_rresp=b_rvalid?m_rresp:2'b0;
assign d_rlast=d_rvalid && m_rlast;
assign b_rlast=b_rvalid && m_rlast;
assign outstanding=state==DATA;
assign owner_valid=state!=IDLE;
assign owner_blit=selected;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state<=IDLE;selected<=0;last_served<=0;beats_left<=0;
        m_araddr<=0;m_arlen<=0;fault<=0;
        display_bursts<=0;blit_bursts<=0;blit_wait_cycles<=0;
    end else begin
        if(b_arvalid && !b_arready && blit_wait_cycles!=32'hffffffff)
            blit_wait_cycles<=blit_wait_cycles+1'b1;
        if(external_fault) fault<=1;
        case(state)
        IDLE: if(!fault && !external_fault) begin
            // Unsolicited R is a protocol fault, not a new request opportunity.
            if(m_rvalid) fault<=1;
            else if(d_arvalid || b_arvalid) begin
                selected<=choose_blit;
                m_araddr<=choose_blit?b_araddr:d_araddr;
                m_arlen<=choose_blit?b_arlen:d_arlen;
                state<=ADDR;
            end
        end
        ADDR: begin
            if(m_rvalid && !af) fault<=1;
            if(af) begin
                state<=DATA;beats_left<={1'b0,m_arlen}+9'd1;
                if(selected) blit_bursts<=blit_bursts+1'b1;
                else display_bursts<=display_bursts+1'b1;
            end
        end
        DATA: if(rf && !fault && !external_fault) begin
            // Malformed RLAST wins over normal completion. Keep state/owner.
            if(m_rlast!=(beats_left==1)) fault<=1;
            else if(beats_left==1) begin
                state<=IDLE;beats_left<=0;last_served<=selected;
            end else beats_left<=beats_left-1'b1;
        end
        default: fault<=1;
        endcase
    end
end
endmodule
