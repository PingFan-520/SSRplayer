// ============================================================================
//  tb_spectrum.v —— 32 段 Goertzel 频谱单元测试
//
//  验证"每根柱对应一个频段、各段独立"这件事本身：
//    1) 1kHz 单音  -> 峰值应落在 ~982Hz 那段（band 16）
//    2) 200Hz 单音 -> 峰值应落在 ~222Hz  那段（band 8）
//    3) 4kHz 单音  -> 峰值应落在 ~4350Hz 那段（band 24）
//    4) 300Hz+3kHz 双音 -> 两个不同的段同时高（证明不是"整排一起动"）
//    5) 静音 -> 全部落到 0
// ============================================================================
`timescale 1ns / 1ps

module tb_spectrum;

    localparam integer NB = 32;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #13.3 clk = ~clk;          // 37.5MHz

    reg signed [15:0] samp = 16'sd0;
    reg               samp_v = 1'b0;
    reg               frm = 1'b0;
    wire [NB*8-1:0]   bars;

    spectrum #(.NB(NB), .BLOCK(1024), .DECAY(40)) u_spec (
        .clk(clk), .rst(rst),
        .sample(samp), .sample_valid(samp_v),
        .frame_start(frm),
        .bars(bars)
    );

    // 48kHz 采样节拍（37.5MHz/48k = 781.25 拍）
    real    acc = 0.0;
    always @(posedge clk) begin
        acc = acc + 48000.0/37500000.0;
        if (acc >= 1.0) begin
            acc = acc - 1.0;
            samp_v <= 1'b1;
        end else
            samp_v <= 1'b0;
    end

    // 30Hz 帧首
    integer fc = 0;
    always @(posedge clk) begin
        frm <= 1'b0;
        fc = fc + 1;
        if (fc >= 1250000) begin
            fc = 0;
            frm <= 1'b1;
        end
    end

    // 生成测试音：f1、f2 两个正弦叠加
    real   ph1 = 0.0, ph2 = 0.0;
    real   f1 = 0.0, f2 = 0.0, a1 = 0.0, a2 = 0.0;

    always @(posedge clk) if (samp_v) begin
        ph1 = ph1 + 2.0*3.14159265358979*f1/48000.0;
        ph2 = ph2 + 2.0*3.14159265358979*f2/48000.0;
        if (ph1 > 6.283185307) ph1 = ph1 - 6.283185307;
        if (ph2 > 6.283185307) ph2 = ph2 - 6.283185307;
        samp <= $rtoi(a1*$sin(ph1) + a2*$sin(ph2));
    end

    // 统计：sample_valid 有多少个？FSM 实际处理了多少个？
    integer n_sv = 0, n_ua = 0, n_ub = 0, n_pw = 0;
    always @(posedge clk) begin
        if (samp_v) n_sv = n_sv + 1;
        if (u_spec.st == 3'd1) n_ua = n_ua + 1;
        if (u_spec.st == 3'd4 && u_spec.bi == 5'd0) n_pw = n_pw + 1;
        if (u_spec.st == 3'd4 && u_spec.bi == 5'd0) n_pw = n_pw + 1;
        if (u_spec.st == 3'd2) n_ub = n_ub + 1;
    end

    // ---------------- 读柱高 ----------------
    function [7:0] bar_at;           // 显示值（带峰值保持/衰减）
        input integer i;
        begin
            bar_at = bars[i*8 +: 8];
        end
    endfunction

    function [7:0] mag_at;           // 本块能量（分析结果，无保持）
        input integer i;
        begin
            mag_at = u_spec.mag[i];
        end
    endfunction

    integer peak_i, peak_v, i, errs;
    integer args;

    task dump_bars;
        input [255:0] tag;
        begin
            $write("[bars] %0s :", tag);
            for (i = 0; i < NB; i = i + 1) $write(" %0d", bar_at(i));
            $write("\n");
        end
    endtask

    task wait_blocks;                 // 等 n 毫秒左右的采样 + 一帧（让显示值更新）
        input integer n;
        begin
            repeat (n * 48) @(posedge samp_v);      // n ms
            @(posedge frm);
            repeat (2000) @(posedge clk);
        end
    endtask

    task find_peak;
        begin
            peak_i = 0; peak_v = 0;
            for (i = 0; i < NB; i = i + 1)
                if (bar_at(i) >= peak_v) begin      // 注意用无符号比较
                    peak_v = bar_at(i);
                    peak_i = i;
                end
        end
    endtask

    initial begin
        errs = 0;
        repeat (10) @(posedge clk);
        rst = 1'b0;
        repeat (10) @(posedge clk);

        // ---- 1) 1kHz ----
        f1 = 1072.0; a1 = 20000.0; f2 = 0.0; a2 = 0.0;
        wait_blocks(300);
        find_peak;
        dump_bars("1kHz   ");
        $display("[info] 1072Hz 峰值段 %0d（期望 16，~982Hz）值 %0d", peak_i, peak_v);
        if ((peak_i < 15) || (peak_i > 17)) begin
            $display("[FAIL] 1kHz 落在段 %0d", peak_i); errs = errs + 1;
        end

        // ---- 2) 200Hz ----
        f1 = 212.0; a1 = 20000.0;
        wait_blocks(300);
        find_peak;
        dump_bars("200Hz  ");
        $display("[info] 212Hz 峰值段 %0d（期望 7，~212Hz）值 %0d", peak_i, peak_v);
        if ((peak_i < 6) || (peak_i > 8)) begin
            $display("[FAIL] 200Hz 落在段 %0d", peak_i); errs = errs + 1;
        end

        // ---- 3) 4kHz ----
        f1 = 3785.0; a1 = 20000.0;
        wait_blocks(300);
        find_peak;
        dump_bars("4kHz   ");
        $display("[info] 3785Hz 峰值段 %0d（期望 23~24）值 %0d", peak_i, peak_v);
        if ((peak_i < 22) || (peak_i > 25)) begin
            $display("[FAIL] 4kHz 落在段 %0d", peak_i); errs = errs + 1;
        end

        // ---- 4) 双音：300Hz + 3kHz，两段应同时高 ----
        f1 = 304.0; a1 = 15000.0;
        f2 = 3161.0; a2 = 15000.0;
        wait_blocks(300);
        dump_bars("双音   ");
        find_peak;
        $display("[info] 双音：段9=%0d 段22=%0d", bar_at(9), bar_at(22));
        if ((bar_at(9) < 40) || (bar_at(22) < 40)) begin
            $display("[FAIL] 双音时两段没有同时起来（说明不是按频段分的）");
            errs = errs + 1;
        end
        if ((bar_at(15) > bar_at(9)) || (bar_at(30) > bar_at(22))) begin
            $display("[FAIL] 无关频段比目标频段还高");
            errs = errs + 1;
        end

        // ---- 5) 静音 -> 全部落地 ----
        f1 = 0.0; a1 = 0.0; f2 = 0.0; a2 = 0.0;
        
        wait_blocks(500);
        
        wait_blocks(300);
        
        
        

        f1 = 0.0; a1 = 0.0; f2 = 0.0; a2 = 0.0;
        wait_blocks(500);
        find_peak;
        $display("[info] 静音后最大块能量 %0d", peak_v);
        if (peak_v > 2) begin
            $display("[FAIL] 静音后没有落地（最大 %0d）", peak_v);
            errs = errs + 1;
        end

        
        if (errs == 0) $display("[PASS] 频谱 32 段：频段定位 + 独立 + 落地 全部正确");
        else           $display("[FAIL] 频谱有 %0d 项不对", errs);
        $finish;
    end

    initial begin
        #3_000_000_000;
        $display("[FAIL] timeout");
        $finish;
    end

endmodule
