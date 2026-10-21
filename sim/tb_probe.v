`timescale 1ns / 1ps
// ============================================================================
//  tb_probe.v —— 探针工程自检
//  检查项：
//    1. 两档模式的像素时钟 / 串行时钟是否为目标值
//    2. 5x 倍频比是否为 5
//    3. D0 通道是否有跳变（375MHz 方波 -> 1us 内约 375 个上升沿）
//    4. 数码管是否在扫描（seg_sel 不能恒为全 1）
// ============================================================================
module tb_probe;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    reg key1  = 1'b1;                 // 松开 -> 方波

    always #10 clk = ~clk;            // 50MHz

    // ---- 720p 档 ----
    wire [5:0] sel_a;
    wire [7:0] dat_a;
    wire       d0_a, clk_a;

    probe_top #(.MODE_720P(1), .IGNORE_LOCK(1)) dut_a (
        .clk(clk), .rst_n(rst_n), .key1(key1),
        .seg_sel(sel_a), .seg_data(dat_a),
        .HDMI_CLK_P(clk_a), .HDMI_D0_P(d0_a)
    );

    // ---- 1024x768 档 ----
    wire [5:0] sel_b;
    wire [7:0] dat_b;
    wire       d0_b, clk_b;

    probe_top #(.MODE_720P(0), .IGNORE_LOCK(1)) dut_b (
        .clk(clk), .rst_n(rst_n), .key1(key1),
        .seg_sel(sel_b), .seg_data(dat_b),
        .HDMI_CLK_P(clk_b), .HDMI_D0_P(d0_b)
    );

    real t0, t1, p;
    integer edges;
    reg     cnt_en = 1'b0;

    always @(posedge d0_a) if (cnt_en) edges = edges + 1;

    initial begin
        #200 rst_n = 1'b1;
        #2000;

        $display("");
        $display("=========== probe self-check ===========");

        // 1. 像素 / 串行时钟
        @(posedge dut_a.clk_pix); t0 = $realtime;
        repeat (10) @(posedge dut_a.clk_pix); t1 = $realtime;
        p = (t1 - t0) / 10.0;
        $display("[A] pixel_clk : %0.4f ns -> %0.3f MHz  (expect 13.3333 / 75.000)", p, 1000.0/p);

        @(posedge dut_a.clk_ser); t0 = $realtime;
        repeat (20) @(posedge dut_a.clk_ser); t1 = $realtime;
        p = (t1 - t0) / 20.0;
        $display("[A] serial_clk: %0.4f ns -> %0.3f MHz  (expect  2.6667 / 375.000)", p, 1000.0/p);

        @(posedge dut_b.clk_pix); t0 = $realtime;
        repeat (10) @(posedge dut_b.clk_pix); t1 = $realtime;
        p = (t1 - t0) / 10.0;
        $display("[B] pixel_clk : %0.4f ns -> %0.3f MHz  (expect 15.3846 / 65.000)", p, 1000.0/p);

        @(posedge dut_b.clk_ser); t0 = $realtime;
        repeat (20) @(posedge dut_b.clk_ser); t1 = $realtime;
        p = (t1 - t0) / 20.0;
        $display("[B] serial_clk: %0.4f ns -> %0.3f MHz  (expect  3.0769 / 325.000)", p, 1000.0/p);

        // 2. 倍频比
        #2000;
        $display("[A] ratio = %0d (expect 5)   locked=%b", dut_a.ratio, dut_a.locked);
        $display("[B] ratio = %0d (expect 5)", dut_b.ratio);

        // 3. D0 跳变计数（1us 窗口）
        edges = 0;
        cnt_en = 1'b1;
        #1000;
        cnt_en = 1'b0;
        $display("[A] D0 edges in 1us = %0d (expect ~375)", edges);

        // 4. 数码管扫描
        $display("[A] seg_sel sample = %b", sel_a);
        $display("========================================");

        #1000;
        $finish;
    end

endmodule
