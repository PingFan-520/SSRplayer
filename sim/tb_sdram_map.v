`timescale 1ns/1ps
// ============================================================================
//  tb_sdram_map.v —— 摸清 App 地址 -> SDRAM 物理索引 的映射
//
//  背景：写 byte=0x4000（字索引 4096）的 burst，实际落在索引 4096+768；
//        而早先写 byte=76960 又恰好落在 19240（=76960/4）。两次结果不一致，
//        说明"索引 = 字节地址/4"这个结论只在某些范围内成立，必须画映射表。
//
//  做法：向间隔 64KB 的 24 个地址各写一个唯一标记（4 拍 burst），
//        然后扫描 4 个 bank 的存储数组，反查每个标记的真实位置。
// ============================================================================
module tb_sdram_map;

    localparam real    TCK = 8.0;
    localparam integer NP  = 24;          // 测试点数
    localparam integer STEP = 65536;      // 字节步进 64KB

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

    // 写一个 4 拍 burst（地址按字节 +4 递增）
    task wr_burst;
        input [20:0] byte_addr;
        input [31:0] tag;
        integer k;
        begin
            @(negedge clk);
            while (ref_vld || busy) @(negedge clk);
            for (k = 0; k < 4; k = k + 1) begin
                app_wr_en   = 1'b1;
                app_wr_addr = byte_addr + k*4;
                app_wr_din  = tag + k;
                @(negedge clk);
            end
            app_wr_en = 1'b0;
            @(negedge clk);
        end
    endtask

    integer i, k, found, at_bank, at_idx;
    reg [31:0] tag;

    // 在 4 个 bank 里找某个标记
    task locate;
        input [31:0] t;
        integer b, j;
        begin
            found = 0; at_bank = -1; at_idx = -1;
            for (j = 0; j < 524288 && !found; j = j + 1) begin
                if (u_chip.Bank0[j] === t) begin found=1; at_bank=0; at_idx=j; end
            end
            for (j = 0; j < 524288 && !found; j = j + 1) begin
                if (u_chip.Bank1[j] === t) begin found=1; at_bank=1; at_idx=j; end
            end
            for (j = 0; j < 524288 && !found; j = j + 1) begin
                if (u_chip.Bank2[j] === t) begin found=1; at_bank=2; at_idx=j; end
            end
            for (j = 0; j < 524288 && !found; j = j + 1) begin
                if (u_chip.Bank3[j] === t) begin found=1; at_bank=3; at_idx=j; end
            end
        end
    endtask

    initial begin
        $display("[tb] map start");
        #1000; rst = 1'b0;
        wait (init_done === 1'b1);
        $display("[tb] init_done at %0t ns", $time);
        repeat (50) @(negedge clk);

        // 写 24 个点
        for (i = 0; i < NP; i = i + 1)
            wr_burst(i*STEP, 32'hAB00_0000 + i);
        repeat (400) @(negedge clk);
        $display("[tb] 24 markers written");

        // 反查
        for (i = 0; i < NP; i = i + 1) begin
            tag = 32'hAB00_0000 + i;
            locate(tag);
            if (found)
                $display("[map] byte=0x%05h (%7d) -> bank%0d idx=%7d  ratio=%0d",
                         i*STEP, i*STEP, at_bank, at_idx, at_idx / ((i*STEP)/4 + 1));
            else
                $display("[map] byte=0x%05h (%7d) -> NOT FOUND", i*STEP, i*STEP);
        end

        $display("[tb] MAP_DONE");
        $finish;
    end

    initial begin
        #80000000;
        $display("[tb] GLOBAL TIMEOUT");
        $finish;
    end

endmodule
