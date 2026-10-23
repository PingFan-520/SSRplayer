`timescale 1ns/1ps
// ============================================================================
//  tb_sdram_readscan.v —— 连续读/写长度扫描（修正版）
//
//  为什么重做：
//    之前 tb_sdram_burst.v 里 rd_q 只声明了 [0:255]，却连续读 800 个字，
//    越界写入导致"只有前 256 字正确"的假象。256 这个数字正好等于数组深度，
//    并不是 SDRAM 行边界。
//
//  本 tb 做的事：
//    1) 写 NW 个字（地址连续，字索引 +1，App 地址 = 字索引*4）
//    2) 一次性连续读回 NW 个字，rd_q 深度 4096，不会越界
//    3) 逐字比对，输出总正确数 + 每 64 字一段的正确数 + 前若干错误位置
//
//  只有这一条结论成立（读全对），才能把 frame_buffer 的 19% 错误归到
//  我们自己的状态机上，而不是控制器。
// ============================================================================
module tb_sdram_readscan;

    localparam real    TCK = 8.0;        // 125MHz
    localparam integer NW  = 2048;       // 读写字数（跨 8 个 SDRAM 行）
    localparam integer BASE = 0;         // 起始字索引

    reg clk     = 1'b0;
    reg clk_sft = 1'b0;
    reg rst     = 1'b1;

    always #(TCK/2.0) clk = ~clk;
    always @(clk) clk_sft <= #2 clk;

    wire        SDRAM_CLK, SDR_CKE, SDR_RAS, SDR_CAS, SDR_WE;
    wire [1:0]  SDR_BA;
    wire [10:0] SDR_ADDR;
    wire [3:0]  SDR_DM;
    wire [31:0] SDR_DQ;

    reg         app_wr_en   = 1'b0;
    reg  [20:0] app_wr_addr = 21'd0;
    reg  [3:0]  app_wr_dm   = 4'h0;
    reg  [31:0] app_wr_din  = 32'd0;
    reg         app_rd_en   = 1'b0;
    reg  [20:0] app_rd_addr = 21'd0;

    wire        init_done, ref_vld, busy, rd_en;
    wire [31:0] rd_dout;

    sdram u_sdram (
        .SDRAM_CLK (SDRAM_CLK), .SDR_CKE (SDR_CKE),
        .SDR_RAS (SDR_RAS), .SDR_CAS (SDR_CAS), .SDR_WE (SDR_WE),
        .SDR_BA (SDR_BA), .SDR_ADDR (SDR_ADDR),
        .SDR_DM (SDR_DM), .SDR_DQ (SDR_DQ),
        .Clk (clk), .Clk_sft (clk_sft), .Rst (rst),
        .Sdr_init_done (init_done),
        .Sdr_init_ref_vld (ref_vld),
        .Sdr_busy (busy),
        .App_wr_en (app_wr_en), .App_wr_addr (app_wr_addr),
        .App_wr_dm (app_wr_dm), .App_wr_din (app_wr_din),
        .App_rd_en (app_rd_en), .App_rd_addr (app_rd_addr),
        .Sdr_rd_en (rd_en), .Sdr_rd_dout (rd_dout)
    );

    IS42s32200 u_chip (
        .Clk (SDRAM_CLK), .Cke (SDR_CKE), .Cs_n (1'b0),
        .Ras_n (SDR_RAS), .Cas_n (SDR_CAS), .We_n (SDR_WE),
        .Ba (SDR_BA), .Dqm (SDR_DM), .Addr (SDR_ADDR), .Dq (SDR_DQ)
    );

    // ---------------- 抓读回数据（深度 4096，绝不越界） ----------------
    reg [31:0] rd_q [0:4095];
    integer    rd_got = 0;
    always @(posedge clk)
        if (rd_en && (rd_got < 4096)) begin
            rd_q[rd_got] = rd_dout;
            rd_got      <= rd_got + 1;
        end

    // ---------------- 连续写 n 个字（地址字索引 +1） ----------------
    task wr_words;
        input [20:0] base;
        input integer n;
        integer k;
        begin
            @(negedge clk);
            while (ref_vld || busy) @(negedge clk);
            for (k = 0; k < n; k = k + 1) begin
                app_wr_en   = 1'b1;
                app_wr_addr = (base + k) * 4;
                app_wr_din  = 32'hC0DE_0000 + base + k;
                @(negedge clk);
                // 每 4 拍插 1 拍空闲：给控制器做 PRE/ACT 的机会
                if ((k % 4) == 3) begin
                    app_wr_en = 1'b0;
                    @(negedge clk);              // burst 间留 1 拍
                end
            end
            app_wr_en = 1'b0;
            @(negedge clk);
        end
    endtask

    // ---------------- 连续读 n 个字 ----------------
    task rd_words;
        input [20:0] base;
        input integer n;
        integer k;
        begin
            @(negedge clk);
            while (ref_vld || busy) @(negedge clk);
            for (k = 0; k < n; k = k + 1) begin
                app_rd_en   = 1'b1;
                app_rd_addr = (base + k) * 4;
                @(negedge clk);
                if ((k % 4) == 3) begin
                    app_rd_en = 1'b0;
                    repeat (16) @(negedge clk);   // 读延迟 10 拍 + PRE/ACT
                end
            end
            app_rd_en = 1'b0;
        end
    endtask

    // ---------------- 统计 ----------------
    integer i, seg, ok_all, ok_seg, err_shown, wcnt;
    reg [31:0] exp;

    initial begin
        $display("[tb] start, NW=%0d BASE=%0d", NW, BASE);
        #1000; rst = 1'b0;

        wait (init_done === 1'b1);
        $display("[tb] init_done at %0t ns", $time);
        repeat (50) @(negedge clk);

        // ---- 写 ----
        wr_words(BASE, NW);
        $display("[tb] write done at %0t ns", $time);

        // 等写完成 + tWR
        repeat (2000) @(negedge clk);

        // ---- 直接查芯片内容，确认写对了 ----
        wcnt = 0;
        for (i = 0; i < NW; i = i + 1)
            if (u_chip.Bank0[BASE + i] === (32'hC0DE_0000 + BASE + i)) wcnt = wcnt + 1;
        $display("[res] SDRAM written  : %0d/%0d", wcnt, NW);
        $display("[raw] chip[%0d..%0d] = %h %h %h %h",
                 BASE, BASE+3,
                 u_chip.Bank0[BASE+0], u_chip.Bank0[BASE+1],
                 u_chip.Bank0[BASE+2], u_chip.Bank0[BASE+3]);

        // ---- 连续读 ----
        rd_got = 0;
        rd_words(BASE, NW);
        repeat (600) @(negedge clk);
        $display("[tb] read issued, got %0d data beats", rd_got);

        // ---- 比对 ----
        ok_all = 0;
        err_shown = 0;
        for (i = 0; i < NW; i = i + 1) begin
            exp = 32'hC0DE_0000 + BASE + i;
            if (rd_q[i] === exp)
                ok_all = ok_all + 1;
            else if (err_shown < 12) begin
                $display("[err] idx=%0d got=%h exp=%h", i, rd_q[i], exp);
                err_shown = err_shown + 1;
            end
        end
        $display("[res] READ back      : %0d/%0d", ok_all, NW);

        // 每 64 字一段的正确数
        for (seg = 0; seg < NW/64; seg = seg + 1) begin
            ok_seg = 0;
            for (i = 0; i < 64; i = i + 1)
                if (rd_q[seg*64+i] === (32'hC0DE_0000 + BASE + seg*64 + i)) ok_seg = ok_seg + 1;
            $display("[seg] %4d..%4d : %0d/64", seg*64, seg*64+63, ok_seg);
        end

        $display("[tb] READSCAN_DONE");
        $finish;
    end

    initial begin
        #20000000;
        $display("[tb] GLOBAL TIMEOUT");
        $finish;
    end

endmodule
