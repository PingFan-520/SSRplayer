`timescale 1ns/1ps
module tb_afifo_full;
  reg cw=0, cr=0; always #5 cw=~cw; always #6.6667 cr=~cr;
  reg aclr=1, we=0, re=0; reg [31:0] di=0;
  wire [31:0] dout; wire full, empty;
  afifo #(.DW(32), .AW(10)) u(.clk_w(cw), .clk_r(cr), .aclr(aclr),
     .wr_en(we), .wr_data(di), .wr_full(full), .rd_en(re), .rd_data(dout), .rd_empty(empty));
  integer i, acc=0;
  initial begin
    #100 aclr=0; @(negedge cw);
    for (i=0;i<1500;i=i+1) begin
      @(negedge cw); we=1; di=i;
      @(negedge cw); we=0;
      if (!full) acc=acc+1;
    end
    $display("[f] accepted=%0d full=%b wbin=%0d", acc, full, u.wbin);
    $finish;
  end
endmodule
