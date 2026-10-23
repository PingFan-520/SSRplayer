`timescale 1ns/1ps
// ============================================================================
//  tb_sdram_burst.v —— 黑盒摸清厂商 SDRAM 控制器的 burst 规则
//
//  背景：之前 tb_sdram_pin 用"地址 +1 连续 8 拍"验证，看似正确，其实是
//        两个相互重叠的 burst（索引 A/4..A/4+3 与 A/4+1..A/4+4 重叠），
//        读回"全对"属于同址覆盖的巧合。必须用独立地址重新验证。
//
//  四组实验，每组写 8 个 burst（32 字），地址按 +16 步进：
//    A: burst 之间 0 拍 gap（背靠背）
//    B: burst 之间 1 拍 gap
//    C: burst 之间 4 拍 gap
//    D: 一次连续 32 拍（地址 +1），看是否支持长 burst
//
//  结果直接读 IS42s32200 的存储数组，按"期望值是否落盘"统计。
// ============================================================================
module tb_sdram_burst;

    localparam real TCK = 8.0;          // 125MHz

    reg clk     = 1'b0;
    reg clk_sft = 1'b0;
    reg rst     = 1'b1;

    always #(TCK/2.0) clk = ~clk;
    always @(clk) clk_sft <= #2 clk;

    // ---------------- DUT 引脚 ----------------
    wire        SDRAM_CLK, SDR_CKE, SDR_RAS, SDR_CAS, SDR_WE;
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

    // ---------------- 写一个 burst：连续 4 拍，地址 +1 ----------------
    // base 是**字索引**，内部换算成字节地址 base*4
    task wr_burst;
        input [20:0] base;              // 起始字索引
        input [31:0] tag;               // 数据标记
        integer k;
        begin
            @(negedge clk);
            while (ref_vld || busy) @(negedge clk);
            for (k = 0; k < 4; k = k + 1) begin
                app_wr_en   = 1'b1;
                app_wr_addr = (base + k) * 4;
                app_wr_din  = tag + base + k;
                @(negedge clk);
            end
            app_wr_en = 1'b0;
        end
    endtask

    task wr_gap;
        input [31:0] n;
        begin
            repeat (n) @(negedge clk);
        end
    endtask

    // ---------------- 读一个字（burst 4 读，只取第一个） ----------------
    integer rd_got = 0;
    reg [31:0] rd_q [0:255];
    always @(posedge clk)
        if (rd_en) begin
            rd_q[rd_got] = rd_dout;
            rd_got <= rd_got + 1;
        end

    task rd_burst;
        input [20:0] base;
        integer k;
        begin
            @(negedge clk);
            while (ref_vld || busy) @(negedge clk);
            for (k = 0; k < 4; k = k + 1) begin
                app_rd_en   = 1'b1;
                app_rd_addr = (base + k) * 4;
                @(negedge clk);
            end
            app_rd_en = 1'b0;
        end
    endtask

    // ---------------- 统计 ----------------
    integer i, k, ok_a, ok_b, ok_c, ok_d, tot;
    integer base_a, base_b, base_c, base_d;

    initial begin
        $display("[tb] start");
        #1000; rst = 1'b0;

        wait (init_done === 1'b1);
        $display("[tb] init_done at %0t ns", $time);
        repeat (50) @(negedge clk);

        base_a = 400;      // 索引 400..1199（200 个 burst）
        base_b = 2000;
        base_c = 3000;
        base_d = 4000;

        // ---------- A: 200 个 burst 背靠背，地址 +4 步进 ----------
        for (i = 0; i < 200; i = i + 1)
            wr_burst(base_a + i*4, 32'hA000_0000);
        $display("[tb] A done (8 bursts back-to-back)");
        wr_gap(100);

        // ---------- B: 每个 burst 后 1 拍 gap ----------
        for (i = 0; i < 8; i = i + 1) begin
            wr_burst(base_b + i*4, 32'hB000_0000);
            wr_gap(1);
        end
        $display("[tb] B done (1-cycle gap)");
        wr_gap(100);

        // ---------- C: 每个 burst 后 4 拍 gap ----------
        for (i = 0; i < 8; i = i + 1) begin
            wr_burst(base_c + i*4, 32'hC000_0000);
            wr_gap(4);
        end
        $display("[tb] C done (4-cycle gap)");
        wr_gap(100);

        // ---------- D: 一次连续 32 拍（地址 +1） ----------
        @(negedge clk);
        while (ref_vld || busy) @(negedge clk);
        for (k = 0; k < 32; k = k + 1) begin
            app_wr_en   = 1'b1;
            app_wr_addr = (base_d + k) * 4;
            app_wr_din  = 32'hD000_0000 + base_d + k;
            @(negedge clk);
        end
        app_wr_en = 1'b0;
        $display("[tb] D done (32-cycle continuous)");
        wr_gap(200);

        // ---------- 检查 SDRAM 存储内容 ----------
        ok_a = 0; ok_b = 0; ok_c = 0; ok_d = 0;
        for (i = 0; i < 800; i = i + 1)
            if (u_chip.Bank0[base_a + i] === (32'hA000_0000 + base_a + i)) ok_a = ok_a + 1;
        for (i = 0; i < 32; i = i + 1) begin
            if (u_chip.Bank0[base_b + i] === (32'hB000_0000 + base_b + i)) ok_b = ok_b + 1;
            if (u_chip.Bank0[base_c + i] === (32'hC000_0000 + base_c + i)) ok_c = ok_c + 1;
            if (u_chip.Bank0[base_d + i] === (32'hD000_0000 + base_d + i)) ok_d = ok_d + 1;
        end
        $display("[res] A(200 bursts back-to-back) : %0d/800", ok_a);
        $display("[res] B(8 bursts, 1-cycle gap)   : %0d/32", ok_b);
        $display("[res] C(8 bursts, 4-cycle gap)   : %0d/32", ok_c);
        $display("[res] D(32 continuous)           : %0d/32", ok_d);

        // 打印 A 组实际落盘分布，看是否只落了每 burst 的首字
        $display("[raw] A: %h %h %h %h %h %h %h %h",
                 u_chip.Bank0[base_a+0], u_chip.Bank0[base_a+1],
                 u_chip.Bank0[base_a+2], u_chip.Bank0[base_a+3],
                 u_chip.Bank0[base_a+4], u_chip.Bank0[base_a+5],
                 u_chip.Bank0[base_a+6], u_chip.Bank0[base_a+7]);
        $display("[raw] D: %h %h %h %h %h %h %h %h",
                 u_chip.Bank0[base_d+0], u_chip.Bank0[base_d+1],
                 u_chip.Bank0[base_d+2], u_chip.Bank0[base_d+3],
                 u_chip.Bank0[base_d+4], u_chip.Bank0[base_d+5],
                 u_chip.Bank0[base_d+6], u_chip.Bank0[base_d+7]);
        // ---------- 读实验：同一 SDRAM 行内（256 字）读 28 个 burst ----------
        rd_got = 0;
        for (i = 0; i < 28; i = i + 1)
            rd_burst(base_a + i*4);
        repeat (200) @(negedge clk);
        ok_a = 0;
        for (i = 0; i < 112; i = i + 1)
            if (rd_q[i] === (32'hA000_0000 + base_a + i)) ok_a = ok_a + 1;
        $display("[res] READ row-local (112 words) : %0d/112", ok_a);
        // 再读跨行的一段（从 448 起，跨 512 边界）56 个字
        rd_got = 0;
        for (i = 0; i < 14; i = i + 1)
            rd_burst(448 + i*4);
        repeat (200) @(negedge clk);
        ok_a = 0;
        for (i = 0; i < 56; i = i + 1)
            if (rd_q[i] === (32'hA000_0000 + 448 + i)) ok_a = ok_a + 1;
        $display("[res] READ crossing row (56 words): %0d/56", ok_a);
        // 打印前 16 个实际读回值，看是否 4 个一组正常
        $display("[rdq] %h %h %h %h %h %h %h %h",
                 rd_q[0], rd_q[1], rd_q[2], rd_q[3],
                 rd_q[4], rd_q[5], rd_q[6], rd_q[7]);

        $display("[tb] BURST_EXP_DONE");
        $finish;
    end

    initial begin
        #20000000;
        $display("[tb] GLOBAL TIMEOUT");
        $finish;
    end

endmodule
