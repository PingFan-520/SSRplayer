//=============================================================================
// tb_sdram_pin.v
//-----------------------------------------------------------------------------
// 目的：用厂商加密控制器 sdr_as_ram + 官方引脚级 SDRAM 模型 IS42s32200
//       验证 App 接口的真实时序（读写、延迟、busy、刷新）。
//
// 时钟：125MHz（与参考工程 lab_ex5 的 SDR_CLK_PERIOD 一致）
//       Clk_sft 比 Clk 延后 ~2ns，模拟 PLL 的相位偏移
//=============================================================================
`timescale 1ns/1ps

module tb_sdram_pin;

    localparam integer TP = 6667;         // 150MHz 半周期（ps 单位下 3333.5）-> 用 ns 精度
    // 用 ns 精度：周期 6.667ns
    localparam real    TCK = 8.0;      // 125MHz：IS42S32200 的 tCK 最小 7ns

    reg clk    = 1'b0;
    reg clk_sft= 1'b0;
    reg rst    = 1'b1;

    always #(TCK/2.0) clk = ~clk;
    // clk_sft 延后 2ns 翻转（等效相位滞后）
    always @(clk) clk_sft <= #2 clk;

    // ---------------- DUT 引脚 ----------------
    wire        SDRAM_CLK;
    wire        SDR_CKE, SDR_RAS, SDR_CAS, SDR_WE;
    wire [1:0]  SDR_BA;
    wire [10:0] SDR_ADDR;
    wire [3:0]  SDR_DM;
    wire [31:0] SDR_DQ;

    // ---------------- App 接口 ----------------
    reg         app_wr_en   = 1'b0;
    reg  [20:0] app_wr_addr = 21'd0;
    reg  [3:0]  app_wr_dm   = 4'h0;
    reg  [31:0] app_wr_din  = 32'd0;
    reg         app_rd_en   = 1'b0;
    reg  [20:0] app_rd_addr = 21'd0;

    wire        sdr_init_done, sdr_init_ref_vld, sdr_busy;
    wire        sdr_rd_en;
    wire [31:0] sdr_rd_dout;

    sdram u_sdram (
        .SDRAM_CLK (SDRAM_CLK),
        .SDR_CKE   (SDR_CKE),
        .SDR_RAS   (SDR_RAS),
        .SDR_CAS   (SDR_CAS),
        .SDR_WE    (SDR_WE),
        .SDR_BA    (SDR_BA),
        .SDR_ADDR  (SDR_ADDR),
        .SDR_DM    (SDR_DM),
        .SDR_DQ    (SDR_DQ),
        .Clk       (clk),
        .Clk_sft   (clk_sft),
        .Rst       (rst),
        .Sdr_init_done    (sdr_init_done),
        .Sdr_init_ref_vld (sdr_init_ref_vld),
        .Sdr_busy         (sdr_busy),
        .App_wr_en   (app_wr_en),
        .App_wr_addr (app_wr_addr),
        .App_wr_dm   (app_wr_dm),
        .App_wr_din  (app_wr_din),
        .App_rd_en   (app_rd_en),
        .App_rd_addr (app_rd_addr),
        .Sdr_rd_en   (sdr_rd_en),
        .Sdr_rd_dout (sdr_rd_dout)
    );

    IS42s32200 u_chip (
        .Clk   (SDRAM_CLK),
        .Cke   (SDR_CKE),
        .Cs_n  (1'b0),
        .Ras_n (SDR_RAS),
        .Cas_n (SDR_CAS),
        .We_n  (SDR_WE),
        .Ba    (SDR_BA),
        .Dqm   (SDR_DM),
        .Addr  (SDR_ADDR),
        .Dq    (SDR_DQ)
    );

    // ---------------- 读数据收集 ----------------
    integer rd_cnt = 0;
    reg [31:0] rd_q [0:63];
    always @(posedge clk) begin
        if (sdr_rd_en) begin
            rd_q[rd_cnt] = sdr_rd_dout;
            rd_cnt <= rd_cnt + 1;
        end
    end

    integer clk_edge = 0;
    always @(SDRAM_CLK) clk_edge = clk_edge + 1;
    initial begin
        #19000;
        $display("[clk] SDRAM_CLK edges in 19us = %0d, clk edges ok", clk_edge);
        #1000;
        $display("[clk] after rst release: %0d", clk_edge);
    end

    // ---------------- 引脚监控（诊断初始化） ----------------
    integer mon_n = 0;
    always @(posedge clk) begin
        mon_n = mon_n + 1;
        if (!rst && (mon_n < 8 || (mon_n % 15625) == 0))
            $display("[pin] %0t CKE=%b RAS=%b CAS=%b WE=%b BA=%0d A=%h init_done=%b",
                     $time, SDR_CKE, SDR_RAS, SDR_CAS, SDR_WE, SDR_BA, SDR_ADDR, sdr_init_done);
    end

    integer i;
    integer err = 0;
    integer c_act = 0, c_wcmd = 0, c_rcmd = 0;
    always @(posedge clk) begin
        if (!SDR_RAS && SDR_CAS && SDR_WE)  c_act  = c_act + 1;
        if (SDR_RAS && !SDR_CAS && !SDR_WE) c_wcmd = c_wcmd + 1;
        if (SDR_RAS && !SDR_CAS && SDR_WE)  c_rcmd = c_rcmd + 1;
    end
    integer tc;

    initial begin
        $display("[tb] start, waiting init...");
        #1000;                        // 等时钟稳定
        rst = 1'b0;

        // 等初始化完成（上电计数 2^17 拍 ≈ 1.05ms@125MHz），最多等 3ms
        begin : wait_init
            tc = 0;
            while (sdr_init_done !== 1'b1 && tc < 375000) begin
                @(posedge clk);
                tc = tc + 1;
            end
            if (sdr_init_done === 1'b1)
                $display("[tb] init_done at %0t ns", $time);
            else
                $display("[tb] TIMEOUT waiting init_done (init_done=%b ref_vld=%b busy=%b)",
                         sdr_init_done, sdr_init_ref_vld, sdr_busy);
        end

        if (sdr_init_done !== 1'b1) begin
            $display("[tb] FAIL: init never completed");
            $finish;
        end

        // ---------------- 写 8 个字（地址 100..107）----------------
        // 在 negedge 驱动，posedge 时控制器正好采样；刷新/busy 期间跳过该拍
        $display("[tb] writing 8 words @76960...");
        i = 0;
        while (i < 8) begin
            @(negedge clk);
            if (!sdr_init_ref_vld && !sdr_busy) begin
                app_wr_en   = 1'b1;
                app_wr_addr = 21'd76960 + i;
                app_wr_din  = 32'hA5A50000 + i;
                i = i + 1;
            end else begin
                app_wr_en   = 1'b0;
            end
        end
        @(negedge clk);
        app_wr_en = 1'b0;
        $display("[tb] write done at %0t ns", $time);

        repeat (60) @(posedge clk);

        // ---------------- 读回 ----------------
        $display("[tb] reading 8 words @76960...");
        i = 0;
        while (i < 8) begin
            @(negedge clk);
            if (!sdr_init_ref_vld && !sdr_busy) begin
                app_rd_en   = 1'b1;
                app_rd_addr = 21'd76960 + i;
                i = i + 1;
            end else begin
                app_rd_en   = 1'b0;
            end
        end
        @(negedge clk);
        app_rd_en = 1'b0;

        repeat (200) @(posedge clk);

        $display("[tb] rd_cnt=%0d", rd_cnt);
        for (i = 0; i < rd_cnt && i < 8; i = i + 1) begin
            $display("[tb] rd[%0d] = %h  expect %h  %s", i, rd_q[i],
                     32'hA5A50000 + i,
                     (rd_q[i] === (32'hA5A50000 + i)) ? "OK" : "MISMATCH");
            if (rd_q[i] !== (32'hA5A50000 + i)) err = err + 1;
        end
        $display("[tb] errors=%0d", err);
        $display("[tb] 引脚 ACT=%0d WR=%0d RD=%0d", c_act, c_wcmd, c_rcmd);
        $display("[tb] SDRAM_PIN_DONE");
        $finish;
    end

    // 兜底超时
    initial begin
        #20000000;
        $display("[tb] GLOBAL TIMEOUT");
        $finish;
    end

endmodule
