`timescale 1ns/1ps
// ============================================================================
//  tb_sdram_probe.v —— 单 burst 探针
//
//  向一个指定 App 地址写 1 个 4 拍 burst，然后扫描整个 Bank0，
//  把"所有非 x 的位置 + 值"全部打印出来。
//  这样能直接看到这个 burst 到底落到哪 4 个字，不依赖任何假设。
// ============================================================================
module tb_sdram_probe;

    localparam real    TCK  = 8.0;
    localparam integer PROBE = 4096;      // 要探测的字节地址

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

    integer k, j, n;
    // 记录引脚上的命令与地址，验证控制器是否真的发出了我们期望的地址
    integer act_n = 0;
    reg [10:0] last_a;
    reg [1:0]  last_ba;
    always @(posedge SDRAM_CLK) begin
        if (!SDR_RAS && SDR_CAS && SDR_WE) begin      // ACTIVE
            act_n = act_n + 1;
            if (act_n <= 12)
                $display("[pin] ACT  ba=%0d a=0x%03h", SDR_BA, SDR_ADDR);
        end
        if (SDR_RAS && !SDR_CAS && !SDR_WE) begin     // WRITE
            if (act_n <= 12)
                $display("[pin] WR   ba=%0d a=0x%03h dq=%h", SDR_BA, SDR_ADDR, SDR_DQ);
        end
    end

    initial begin
        $display("[tb] probe start, target byte = %0d", PROBE);
        #1000; rst = 1'b0;
        wait (init_done === 1'b1);
        $display("[tb] init_done at %0t ns", $time);
        repeat (200) @(negedge clk);

        // ---- 单 burst：4 拍连续，地址 +4 ----
        @(negedge clk);
        while (ref_vld || busy) @(negedge clk);
        for (k = 0; k < 4; k = k + 1) begin
            app_wr_en   = 1'b1;
            app_wr_addr = PROBE + k*4;
            app_wr_din  = 32'hAABB_0000 + k;
            @(negedge clk);
        end
        app_wr_en = 1'b0;
        $display("[tb] burst issued");

        repeat (300) @(negedge clk);

        // ---- 扫描 Bank0 全部，打印所有被写过的位置 ----
        n = 0;
        for (j = 0; j < 524288; j = j + 1)
            if (u_chip.Bank0[j] !== 32'hxxxxxxxx) begin
                if (n < 24)
                    $display("[hit] Bank0[%0d] = %h", j, u_chip.Bank0[j]);
                n = n + 1;
            end
        $display("[res] Bank0 non-x count = %0d", n);

        // ---- 同时扫 Bank1..3，看是否被分到别的 bank ----
        n = 0;
        for (j = 0; j < 524288; j = j + 1) begin
            if (u_chip.Bank1[j] !== 32'hxxxxxxxx) begin
                if (n < 6) $display("[hit] Bank1[%0d] = %h", j, u_chip.Bank1[j]);
                n = n + 1;
            end
        end
        $display("[res] Bank1 non-x count = %0d", n);
        n = 0;
        for (j = 0; j < 524288; j = j + 1) begin
            if (u_chip.Bank2[j] !== 32'hxxxxxxxx) begin
                if (n < 6) $display("[hit] Bank2[%0d] = %h", j, u_chip.Bank2[j]);
                n = n + 1;
            end
        end
        $display("[res] Bank2 non-x count = %0d", n);
        n = 0;
        for (j = 0; j < 524288; j = j + 1) begin
            if (u_chip.Bank3[j] !== 32'hxxxxxxxx) begin
                if (n < 6) $display("[hit] Bank3[%0d] = %h", j, u_chip.Bank3[j]);
                n = n + 1;
            end
        end
        $display("[res] Bank3 non-x count = %0d", n);

        $display("[tb] PROBE_DONE");
        $finish;
    end

    initial begin
        #40000000;
        $display("[tb] GLOBAL TIMEOUT");
        $finish;
    end

endmodule
