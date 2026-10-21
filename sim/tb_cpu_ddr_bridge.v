`timescale 1ns/1ps
module tb_cpu_ddr_bridge;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,cpu_reset=0,session_active=1,clear_error=0;
reg asset_loading=0,asset_ready=0;
reg [31:0] front_base=0,back_base=32'h00800000;
wire busy;wire [31:0] error_code;
reg [31:0] s_awaddr=0,s_araddr=0;
reg [7:0] s_awid=0,s_arid=0,s_awlen=0,s_arlen=0;
reg [2:0] s_awsize=4,s_arsize=4;
reg [1:0] s_awburst=1,s_arburst=1;
reg s_awlock=0,s_arlock=0,s_awvalid=0,s_wlast=1,s_wvalid=0,s_arvalid=0;
wire s_awready,s_wready,s_bvalid,s_arready,s_rvalid,s_rlast;
reg s_bready=0,s_rready=0;
reg [127:0] s_wdata=0;reg [15:0] s_wstrb=0;
wire [7:0] s_bid,s_rid;wire [1:0] s_bresp,s_rresp;wire [127:0] s_rdata;
wire [31:0] m_awaddr,m_araddr;wire m_awvalid,m_wvalid,m_wlast,m_bready,m_arvalid,m_rready;
reg m_awready=0,m_wready=0,m_bvalid=0,m_arready=0,m_rvalid=0,m_rlast=1;
reg [3:0] m_bid=0,m_rid=0;reg [1:0] m_bresp=0,m_rresp=0;
reg [127:0] m_rdata=128'h00112233445566778899aabbccddeeff;
wire [127:0] m_wdata;wire [15:0] m_wstrb;
integer i;
cpu_ddr_bridge dut(.*);
initial begin #200000;$fatal(1,"CPU DDR bridge timeout");end
task write_case;
    input [31:0] addr;
    input [15:0] mask;
    input [1:0] expected_resp;
    input [31:0] expected_addr;
    input [7:0] id;
    begin
        @(negedge clk);s_wdata=128'hfedcba98765432100123456789abcdef;
        s_wstrb=mask;s_wvalid=1;s_awid=id;s_awaddr=addr;
        if(!s_wready) $fatal(1,"W not ready before AW");
        @(posedge clk);@(negedge clk);s_wvalid=0;s_awvalid=1;
        if(!s_awready) $fatal(1,"AW not ready after W");
        @(posedge clk);@(negedge clk);s_awvalid=0;
        if(expected_addr!=0) begin
            wait(m_awvalid);if(m_awaddr!==expected_addr) $fatal(1,"AW address %h != %h",m_awaddr,expected_addr);
            // The admission gate can hold AW independently of W.
            repeat(3) begin @(posedge clk);if(m_wvalid) $fatal(1,"W escaped before AW");end
            @(negedge clk);m_awready=1;
            @(posedge clk);@(negedge clk);m_awready=0;
            wait(m_wvalid);if(m_wstrb!==mask || m_wdata!==s_wdata || !m_wlast)
                $fatal(1,"W lane or data mismatch");
            @(negedge clk);m_wready=1;
            @(posedge clk);@(negedge clk);m_wready=0;m_bvalid=1;
            if(!m_bready) $fatal(1,"B not accepted");
            @(posedge clk);@(negedge clk);m_bvalid=0;
        end else begin
            repeat(3) begin @(posedge clk);if(m_awvalid || m_wvalid) $fatal(1,"Denied write escaped");end
            @(negedge clk);
        end
        if(!s_bvalid || s_bid!==id || s_bresp!==expected_resp)
            $fatal(1,"B response mismatch ID=%h RESP=%h",s_bid,s_bresp);
        s_bready=1;@(posedge clk);@(negedge clk);s_bready=0;
        if(busy) $fatal(1,"Bridge did not drain after B");
    end
endtask
task read_case;
    input [31:0] addr;
    input [1:0] expected_resp;
    input [31:0] expected_addr;
    input [7:0] id;
    begin
        @(negedge clk);s_araddr=addr;s_arid=id;s_arvalid=1;
        if(!s_arready) $fatal(1,"AR not ready");
        @(posedge clk);@(negedge clk);s_arvalid=0;
        if(expected_resp==0) begin
            wait(m_arvalid);if(m_araddr!==expected_addr) $fatal(1,"AR address %h != %h",m_araddr,expected_addr);
            @(negedge clk);m_arready=1;
            @(posedge clk);@(negedge clk);m_arready=0;m_rvalid=1;
            if(!m_rready) $fatal(1,"R not accepted");
            @(posedge clk);@(negedge clk);m_rvalid=0;
        end else begin
            repeat(3) begin @(posedge clk);if(m_arvalid) $fatal(1,"Denied read escaped");end
            @(negedge clk);
        end
        if(!s_rvalid || s_rid!==id || s_rresp!==expected_resp || !s_rlast)
            $fatal(1,"R response mismatch");
        if(expected_resp==0 && s_rdata!==m_rdata) $fatal(1,"R data lane changed");
        s_rready=1;@(posedge clk);@(negedge clk);s_rready=0;
        if(busy) $fatal(1,"Bridge did not drain after R");
    end
endtask
initial begin
    repeat(3) @(posedge clk);@(negedge clk);rst_n=1;
    for(i=0;i<4;i=i+1)
        write_case(32'h00801000+i*4,16'h000f << (i*4),0,32'h00800000,8'h81+i);
    write_case(32'h00001000,16'h000f,3,0,8'h91); // Front write
    write_case(32'h00801000+32'h007e9000,16'h000f,3,0,8'h92); // padding
    write_case(32'h00801004,16'h000f,3,0,8'h93); // wrong lane
    read_case(32'h00001000,0,0,8'ha1);
    read_case(32'h0080100c,0,32'h00800000,8'ha2);
    read_case(32'h01001000,3,0,8'ha3);
    asset_loading=1;
    write_case(32'h01001000,16'h000f,0,32'h01000000,8'ha4);
    write_case(32'h01384ffc,16'hf000,0,32'h01383ff0,8'ha5);
    write_case(32'h01385000,16'h000f,3,0,8'ha6);
    read_case(32'h01384ffc,0,32'h01383ff0,8'ha7);
    asset_loading=0;asset_ready=1;
    write_case(32'h01001000,16'h000f,3,0,8'ha8);
    read_case(32'h01001000,0,32'h01000000,8'ha9);
    asset_ready=0;
    session_active=0;
    write_case(32'h00801000,16'h000f,3,0,8'hb1);
    read_case(32'h00001000,3,0,8'hb2);
    session_active=1;
    @(negedge clk);clear_error=1;@(posedge clk);@(negedge clk);clear_error=0;
    m_bid=4'h3;
    write_case(32'h00801000,16'h000f,2,32'h00800000,8'hc1);
    if(error_code!=3) $fatal(1,"Wrong downstream BID not reported");
    m_bid=0;
    @(negedge clk);clear_error=1;@(posedge clk);@(negedge clk);clear_error=0;
    @(negedge clk);s_araddr=32'h00001000;s_arid=8'hc2;s_arvalid=1;
    @(posedge clk);@(negedge clk);s_arvalid=0;
    wait(m_arvalid);@(negedge clk);m_arready=1;
    @(posedge clk);@(negedge clk);m_arready=0;m_rlast=0;m_rvalid=1;
    @(posedge clk);@(negedge clk);m_rvalid=0;
    if(!busy || s_rvalid || error_code!=5) $fatal(1,"Early RLAST fault not held");
    m_rlast=1;m_rvalid=1;
    @(posedge clk);@(negedge clk);m_rvalid=0;
    if(!s_rvalid || s_rresp!=2 || s_rid!=8'hc2) $fatal(1,"RLAST error response");
    s_rready=1;@(posedge clk);@(negedge clk);s_rready=0;
    @(negedge clk);clear_error=1;@(posedge clk);@(negedge clk);clear_error=0;
    // CPU reset after a DDR AW must still send W and drain B; no CPU response.
    @(negedge clk);s_awaddr=32'h00801000;s_awid=8'hde;s_awvalid=1;
    s_wdata=128'h1234;s_wstrb=16'h000f;s_wvalid=1;
    @(posedge clk);@(negedge clk);s_awvalid=0;s_wvalid=0;
    wait(m_awvalid);@(negedge clk);m_awready=1;
    @(posedge clk);@(negedge clk);m_awready=0;cpu_reset=1;
    wait(m_wvalid);@(negedge clk);m_wready=1;
    @(posedge clk);@(negedge clk);m_wready=0;m_bvalid=1;
    @(posedge clk);@(negedge clk);m_bvalid=0;cpu_reset=0;
    repeat(2) @(posedge clk);@(negedge clk);
    if(s_bvalid || busy || error_code!=6)
        $fatal(1,"Reset drain failed: bvalid=%b busy=%b error=%h state=%d",
               s_bvalid,busy,error_code,dut.state);
    $display("PASS CPU DDR bridge: 4 lanes, AW/W independence, address offset, front/padding guard, ID/RLAST faults, backpressure, reset drain");
    $finish;
end
endmodule
