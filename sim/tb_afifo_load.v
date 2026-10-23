`timescale 1ns/1ps
module tb_afifo_load;
  reg cw=0, cr=0; always #5 cw=~cw; always #6.6667 cr=~cr;
  reg aclr=1, we=0, re=0; reg [31:0] di=0;
  wire [31:0] dout; wire full, empty;
  afifo #(.DW(32), .AW(10)) u(.clk_w(cw), .clk_r(cr), .aclr(aclr),
     .wr_en(we), .wr_data(di), .wr_full(full), .rd_en(re), .rd_data(dout), .rd_empty(empty));
  integer i, acc=0, pops=0, got, err=0, exp=0;
  // 写侧：连续写
  initial begin
    #100 aclr=0;
    for (i=0;i<600000;i=i+1) begin
      @(negedge cw); we=1; di=i;
      if (!full) acc=acc+1;
    end
    we=0;
    $display("[L] accepted=%0d", acc);
  end
  // 读侧：每 2 拍读 1 次
  initial begin
    #200;
    forever begin
      repeat (2) @(negedge cr);
      re=1; @(negedge cr); re=0; pops=pops+1;
    end
  end
  initial begin
    #3000000;
    $display("[L] pops=%0d acc=%0d diff=%0d", pops, acc, acc-pops);
    $finish;
  end
endmodule
