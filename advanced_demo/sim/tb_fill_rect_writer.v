`timescale 1ns/1ps
module tb_fill_rect_writer;
localparam WIDTH=1088,HEIGHT=8,WORDS=WIDTH*HEIGHT;
reg clk=0,rst_n=0,enabled=0,start=0;
always #5 clk=~clk;
reg [31:0] x=0,y=0,w=0,h=0,color=0;
wire busy,done,av,wv,wl,br;
wire [31:0] error,commands,addr;
wire [7:0] len;
wire [127:0] data;
wire [15:0] strb;
integer tick=0,aw_count=0,b_count=0,index=0,left=0,delay_b=0;
reg active=0,bv=0,stall_aw=0,stall_w=0,inject_b=0;
wire ar=!active&&!bv&&delay_b==0&&!stall_aw&&tick%5!=0;
wire wr=active&&!stall_w&&tick%3!=0;
reg [31:0] mem[0:WORDS-1],expected[0:WORDS-1];
fill_rect_writer #(.FRAME_WIDTH(WIDTH),.FRAME_HEIGHT(HEIGHT),.FRAME_STRIDE(WIDTH*4),
 .WATCHDOG_BITS(8)) dut (
 .clk(clk),.rst_n(rst_n),.enabled(enabled),.start(start),
 .rect_x(x),.rect_y(y),.rect_width(w),.rect_height(h),.rect_color(color),
 .display_frame_tick(tick%100==0),.busy(busy),.done(done),.error_code(error),.command_count(commands),
 .awaddr(addr),.awlen(len),.awvalid(av),.awready(ar),.wdata(data),.wstrb(strb),
 .wvalid(wv),.wlast(wl),.wready(wr),.bid(4'b0),.bresp(inject_b?2'b10:2'b0),.bvalid(bv),.bready(br));
integer lane;
reg as=0,ws=0;
reg [31:0] held_addr;
reg [7:0] held_len;
reg [144:0] held_w;
always @(posedge clk) if(rst_n) begin
 tick<=tick+1;
 if(as && (!av || addr!==held_addr || len!==held_len)) $fatal(1,"AW changed under stall");
 if(ws && (!wv || {data,strb,wl}!==held_w)) $fatal(1,"W changed under stall");
 as<=av&&!ar;ws<=wv&&!wr;held_addr<=addr;held_len<=len;held_w<={data,strb,wl};
 if(av&&ar) begin
  if(addr[3:0]!=0 || addr[11:0]+(len+1)*16>4096 || len>=32 || addr/4>=WORDS) $fatal(1,"Invalid fill burst");
  active<=1;index<=addr/4;left<=len+1;aw_count<=aw_count+1;
 end
 if(wv&&wr) begin
  if(wl!==(left==1) || strb==0) $fatal(1,"Wrong WLAST/strobe");
  for(lane=0;lane<4;lane=lane+1) begin
   if(strb[lane*4+:4]!=0 && strb[lane*4+:4]!=15) $fatal(1,"Split pixel strobe");
   if(strb[lane*4]) mem[index+lane]<=data[lane*32+:32];
  end
  index<=index+4;left<=left-1;
  if(left==1) begin active<=0;delay_b<=20;end
 end
 if(delay_b!=0) begin delay_b<=delay_b-1;if(delay_b==1) bv<=1;end
 if(bv&&br) begin bv<=0;b_count<=b_count+1;end
 if(done && b_count!=aw_count) $fatal(1,"DONE before all B");
end
task launch;
input [31:0] xx,yy,ww,hh,cc;
begin
 @(negedge clk);x=xx;y=yy;w=ww;h=hh;color=cc;start=1;
 @(negedge clk);start=0;
end
endtask
task wait_done;
integer n;
begin n=0;while(!done) begin @(negedge clk);n=n+1;if(n>10000)$fatal(1,"Fill timeout");end end
endtask
integer i,j,k,old_aw;
task rectangle;
input integer xx,yy,ww,hh;
input [31:0] cc;
begin
 launch(xx,yy,ww,hh,cc);
 // Mutating command inputs after start must not change the active rectangle.
 x=0;y=0;w=1;h=1;color=0;
 wait_done();if(error!=0)$fatal(1,"Unexpected fill error %h",error);
 for(j=yy;j<yy+hh;j=j+1) for(k=xx;k<xx+ww;k=k+1) expected[j*WIDTH+k]=cc;
 for(i=0;i<WORDS;i=i+1) if(mem[i]!==expected[i]) $fatal(1,"Pixel %0d got %h expected %h",i,mem[i],expected[i]);
end
endtask
initial begin
 for(i=0;i<WORDS;i=i+1) begin mem[i]=32'h00556677;expected[i]=32'h00556677;end
 repeat(4)@(negedge clk);rst_n=1;
 launch(1,1,8,2,32'hfff);repeat(10)@(negedge clk);
 if(busy||commands!=0||aw_count!=0)$fatal(1,"Command before INIT_DONE");
 enabled=1;
 rectangle(1015,0,70,2,32'ha1122334); // 4KiB boundary and partial first/last beats
 rectangle(3,3,9,3,32'h00f0e0d0);
 rectangle(WIDTH-1,HEIGHT-1,1,1,32'h00abcdef);
 rectangle(0,0,WIDTH,HEIGHT,32'h00102030);
 old_aw=aw_count;launch(0,0,0,1,0);wait_done();
 if(error!=32'h11||aw_count!=old_aw)$fatal(1,"Zero width accepted");
 launch(32'hfffffffe,0,8,1,0);wait_done();
 if(error!=32'h11||aw_count!=old_aw)$fatal(1,"Overflowing geometry accepted");
 inject_b=1;launch(0,0,100,1,0);wait_done();
 if(error!=32'h12||aw_count!=old_aw+1)$fatal(1,"B error not terminal");
 inject_b=0;stall_aw=1;launch(0,1,100,1,32'hff0000);
 repeat(300)@(negedge clk);
 if(!busy||!av||done||error!=32'h13)$fatal(1,"Timeout withdrew pending AW");
 stall_aw=0;wait_done();
 if(error!=32'h13||aw_count!=old_aw+2)$fatal(1,"Timeout did not drain exactly one burst");
 stall_w=1;launch(1,2,99,1,32'h00123456);wait(wv);
 repeat(300)@(negedge clk);
 if(!busy||!wv||done||error!=32'h13)$fatal(1,"Timeout withdrew pending W");
 stall_w=0;wait_done();
 if(error!=32'h13||aw_count!=old_aw+3)$fatal(1,"W timeout did not drain exactly one burst");
 $display("PASS fill writer: strobes/4KiB/geometry/parameter snapshot/backpressure/B errors/timeout drain/display settle");$finish;
end
initial begin #2000000;$fatal(1,"watchdog");end
endmodule
