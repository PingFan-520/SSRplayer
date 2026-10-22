`timescale 1ns / 1ps
// ============================================================================
//  tb_sdram_model.v —— 先确认 TD 的 SDRAM 芯片模型是否真的能存数据
//  直接按 SDRAM 命令时序手打：PRECHARGE / REFRESH / MRS / WRITE / READ
// ============================================================================
module tb_sdram_model;

    reg clk = 1'b0;
    always #5 clk = ~clk;          // 100MHz

    reg        ras_n = 1'b1, cas_n = 1'b1, we_n = 1'b1;
    reg  [10:0] addr = 11'd0;
    reg  [1:0]  ba   = 2'd0;
    reg  [31:0] dq_out = 32'd0;
    reg         dq_oe  = 1'b0;
    wire [31:0] dq;
    assign dq = dq_oe ? dq_out : 32'bz;

    reg cs_n = 1'b0, cke = 1'b1;
    reg dm0 = 1'b0, dm1 = 1'b0, dm2 = 1'b0, dm3 = 1'b0;

    EG_PHY_SDRAM_2M_32 u_mem (
        .clk(clk), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
        .addr(addr), .ba(ba), .dq(dq), .cs_n(cs_n),
        .dm0(dm0), .dm1(dm1), .dm2(dm2), .dm3(dm3), .cke(cke)
    );

    task cmd;
        input r, c, w;
        input [10:0] a;
        input [1:0]  b;
        begin
            @(negedge clk);
            ras_n = r; cas_n = c; we_n = w; addr = a; ba = b;
        end
    endtask

    task nop;
        begin
            @(negedge clk);
            ras_n = 1; cas_n = 1; we_n = 1;
        end
    endtask

    integer i;
    reg [31:0] rd;

    initial begin
        // 上电等待
        repeat (20) @(posedge clk);

        // PRECHARGE ALL
        cmd(0, 1, 0, 11'h400, 2'd0); nop;
        repeat (3) nop;

        // REFRESH x2
        cmd(0, 0, 1, 11'd0, 2'd0); nop; repeat (5) nop;
        cmd(0, 0, 1, 11'd0, 2'd0); nop; repeat (5) nop;

        // MRS: burst=1, CAS latency=3, sequential
        cmd(0, 0, 0, 11'b000_0_011_0_000, 2'd0); nop;
        repeat (3) nop;

        // 写入：ACTIVE row0 bank0
        cmd(0, 1, 1, 11'd0, 2'd0); nop;
        repeat (3) nop;
        // WRITE col=5
        @(negedge clk);
        ras_n = 1; cas_n = 0; we_n = 0; addr = 11'd5; ba = 2'd0; dq_oe = 1; dq_out = 32'hDEADBEEF;
        @(negedge clk); ras_n = 1; cas_n = 1; we_n = 1;
        @(negedge clk); dq_oe = 0;
        repeat (4) nop;

        // PRECHARGE
        cmd(0, 1, 0, 11'h400, 2'd0); nop; repeat (3) nop;

        // 读回：ACTIVE row0
        cmd(0, 1, 1, 11'd0, 2'd0); nop; repeat (3) nop;
        // READ col=5, CAS=3
        cmd(1, 0, 1, 11'd5, 2'd0); nop;
        repeat (5) nop;
        rd = dq;
        $display("[sdram] read back = %h  (expect deadbeef)", rd);
        if (rd === 32'hDEADBEEF) $display("SDRAM_MODEL_OK");
        else                     $display("SDRAM_MODEL_BAD");
        $finish;
    end

endmodule
