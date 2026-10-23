`timescale 1ns/1ps
module tb_afifo;
  reg cw=0, cr=0; always #5 cw=~cw; always #6.6667 cr=~cr;
  reg aclr=1, we=0, re=0;
  reg [31:0] di=0;
  wire [31:0] dout; wire full, empty;
  afifo #(.DW(32), .AW(10)) u(.clk_w(cw), .clk_r(cr), .aclr(aclr),
     .wr_en(we), .wr_data(di), .wr_full(full),
     .rd_en(re), .rd_data(dout), .rd_empty(empty));
  integer i, err=0, got;
  initial begin
    #100 aclr=0;
    for (i=0;i<100;i=i+1) begin
      @(negedge cw); we=1; di=i+1000;
      @(negedge cw); we=0;
    end
    $display("[f] written 100, empty=%b full=%b", empty, full);
    for (i=0;i<100;i=i+1) begin
      @(negedge cr); re=1;
      @(negedge cr); re=0; got=dout;
      if (got !== i+1000) begin err=err+1; if (err<6) $display("[f] i=%0d got=%0d exp=%0d", i, got, i+1000); end
    end
    $display("[f] errors=%0d", err);
    $finish;
  end
endmodule
