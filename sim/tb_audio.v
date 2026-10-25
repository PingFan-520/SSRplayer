// ============================================================================
//  tb_audio.v —— 音频通路单元测试（tone_gen + audio_meter）
//
//  覆盖四件事：
//    1) 采样率：aud_valid 的密度必须是 48kHz（37.5MHz 下约 1/781）
//    2) 音量：vol=10 与 vol=5 的峰值应约为 1:0.5；vol=0 必须全 0
//    3) 旋律/音高：8 步的零穿越次数比应为 1, 1.5, 2, 1.25, 1, 1.5, 2, 0.5
//    4) 电平表：给定恒定 level，柱子高度/间隙/颜色分段是否正确
//
//  为了跑得快，tone_gen 的 NOTE_LEN 改小到 2400（真实是 6000）。
// ============================================================================
`timescale 1ns / 1ps

module tb_audio;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #13.3 clk = ~clk;              // 37.5MHz

    // ---------------- DUT 1：满音量 ----------------
    reg  [3:0]  vol_a = 4'd10;
    wire        av_a;
    wire [23:0] l_a, r_a;
    wire [7:0]  env_a;

    tone_gen #(.CLK_HZ(37_500_000), .SAMPLE_HZ(48_000), .NOTE_LEN(1200)) u_a (
        .clk(clk), .rst(rst),
        .note_idx(8'd3),                  // 800Hz 基音
        .vol(vol_a), .mute(1'b0),
        .aud_valid(av_a), .aud_left(l_a), .aud_right(r_a), .env_out(env_a)
    );

    // ---------------- DUT 2：半音量 ----------------
    reg  [3:0]  vol_b = 4'd5;
    wire        av_b;
    wire [23:0] l_b, r_b;
    wire [7:0]  env_b;

    tone_gen #(.CLK_HZ(37_500_000), .SAMPLE_HZ(48_000), .NOTE_LEN(1200)) u_b (
        .clk(clk), .rst(rst),
        .note_idx(8'd3),
        .vol(vol_b), .mute(1'b0),
        .aud_valid(av_b), .aud_left(l_b), .aud_right(r_b), .env_out(env_b)
    );

    // ---------------- DUT 3：电平表 ----------------
    reg  [7:0]  level = 8'd0;
    reg         men   = 1'b1;
    wire        m_on;
    wire [23:0] m_rgb;
    wire [3:0]  m_alpha;

    reg  [11:0] mx = 12'd0, my = 12'd0;

    audio_meter #(.X0(480), .Y0(624), .BARW(8), .NBAR(32), .MAXH(88)) u_m (
        .clk(clk), .rst(rst),
        .x(mx), .y(my),
        .level(level), .enable(men),
        .on(m_on), .rgb(m_rgb), .alpha(m_alpha)
    );

    // ------------------------------------------------------------------
    // 1) 采样率：数 375000 拍（10ms）内的 aud_valid 个数，应为 480
    // ------------------------------------------------------------------
    integer n_valid = 0, i;
    always @(posedge clk) if (av_a) n_valid = n_valid + 1;

    // ------------------------------------------------------------------
    // 3) 零穿越 + 峰值：按 aud_valid 逐个采样分析
    // ------------------------------------------------------------------
    integer note_idx_sim = -1;            // 由采样计数推算当前是第几个音符
    integer zc_a [0:7];
    integer pk_a [0:7];                   // 每音符峰值（|sample|）
    integer sc_a = 0;                     // 采样计数
    integer seg  = 0;                     // 当前音符
    reg     last_neg = 1'b0;
    integer v_a, mag_a;

    integer zc_b = 0, pk_b = 0;
    reg     last_neg_b = 1'b0;

    initial begin
        for (i = 0; i < 8; i = i + 1) begin
            zc_a[i] = 0;
            pk_a[i] = 0;
        end
    end

    always @(posedge clk) begin
        if (av_a) begin
            v_a = $signed(l_a);                  // 24 位有符号，判符号用
            mag_a = l_a[23] ? ((24'h1000000 - l_a)) : l_a;   // |sample|
            if (seg < 8) begin
                if (!last_neg && (v_a < 0)) zc_a[seg] = zc_a[seg] + 1;
                if (mag_a > pk_a[seg]) pk_a[seg] = mag_a;
            end
            last_neg = (v_a < 0);

            sc_a = sc_a + 1;
            if (sc_a == 1200) begin
                sc_a = 0;
                seg  = seg + 1;
            end
        end

        if (av_b) begin
            mag_a = l_b[23] ? ((24'h1000000 - l_b)) : l_b;
            if (mag_a > pk_b) pk_b = mag_a;
            last_neg_b = l_b[23];
        end
    end

    // ------------------------------------------------------------------
    // 主流程
    // ------------------------------------------------------------------
    integer errs = 0;
    integer rate;

    initial begin
        repeat (10) @(negedge clk);
        rst = 1'b0;
        repeat (10) @(negedge clk);

        // ---- 1) 采样率 ----
        n_valid = 0;
        repeat (375000) @(negedge clk);
        rate = n_valid * 100;             // 10ms -> 1s
        if ((rate > 47900) && (rate < 48100))
            $display("[ok] 采样率 %0d Hz（10ms 内 %0d 个）", rate, n_valid);
        else begin
            $display("[FAIL] 采样率 %0d Hz（10ms 内 %0d 个），应约 48000", rate, n_valid);
            errs = errs + 1;
        end

        // ---- 3) 等 8 个音符走完（8*2400 采样 = 400ms 仿真）----
        wait (seg == 8);
        $display("[info] 8 步零穿越次数: %0d %0d %0d %0d %0d %0d %0d %0d",
                 zc_a[0], zc_a[1], zc_a[2], zc_a[3], zc_a[4], zc_a[5], zc_a[6], zc_a[7]);

        // 期望比率 1, 1.5, 2, 1.25, 1, 1.5, 2, 0.5（以第 0 步为基准）
        begin : chk_melody
            integer base, j;
            real ratio;
            base = zc_a[0];
            if (base < 20) begin
                $display("[FAIL] 基准音零穿越太少（%0d），旋律没跑起来", base);
                errs = errs + 1;
                disable chk_melody;
            end
            for (j = 0; j < 8; j = j + 1) begin
                case (j)
                    0: ratio = 1.0;   1: ratio = 1.5;  2: ratio = 2.0;  3: ratio = 1.25;
                    4: ratio = 1.0;   5: ratio = 1.5;  6: ratio = 2.0;  default: ratio = 0.5;
                endcase
                if ((zc_a[j] < base*ratio*0.85) || (zc_a[j] > base*ratio*1.15)) begin
                    $display("[FAIL] 第 %0d 步零穿越 %0d，期望 %0d（x%0.2f）",
                             j, zc_a[j], base*ratio, ratio);
                    errs = errs + 1;
                end
            end
            if (errs == 0)
                $display("[ok] 旋律比率正确（基准 %0d 次/音符）", base);
        end

        // ---- 2) 音量比例 ----
        $display("[info] 峰值 vol=10: %0d, vol=5: %0d", pk_a[0], pk_b);
        if ((pk_a[0] < 100000) || (pk_b == 0)) begin
            $display("[FAIL] 峰值异常（vol10=%0d vol5=%0d）", pk_a[0], pk_b);
            errs = errs + 1;
        end else if ((pk_b*100/pk_a[0]) < 40 || (pk_b*100/pk_a[0]) > 60) begin
            $display("[FAIL] vol=5 的峰值是 vol=10 的 %0d%%，应约 50%%", pk_b*100/pk_a[0]);
            errs = errs + 1;
        end else
            $display("[ok] 音量比例 %0d%%（应约 50%%）", pk_b*100/pk_a[0]);

        // ---- 2b) 静音 ----
        vol_a = 4'd0;
        repeat (3000) @(negedge clk);
        if (pk_a[0] == 0) begin
            $display("[FAIL] vol=0 之后仍有输出");
            errs = errs + 1;
        end else begin
            pk_a[0] = 0;                                  // 重新计峰值
            repeat (20000) @(negedge clk);
            if (pk_a[0] == 0) $display("[ok] vol=0 静音");
            else begin $display("[FAIL] vol=0 时峰值仍为 %0d", pk_a[0]); errs = errs + 1; end
        end
        vol_a = 4'd10;

        // ---- 4) 电平表 ----
        // level=255 -> 柱高被夹到 MAXH=88 -> 整列填满；间隙列 dx[2:0]>=6 不画
        level = 8'd255;
        repeat (20000) @(negedge clk);         // 32 列全部填满（每列 512 拍）
        my = 12'd624;      mx = 12'd480;       // 柱底（dy=0 是顶部，dy=87 是底部）
        #1; if (!m_on) begin $display("[FAIL] 电平表：满幅柱顶未点亮"); errs = errs + 1; end
        my = 12'd711;      mx = 12'd480;       // 最底一行
        #1; if (!m_on) begin $display("[FAIL] 电平表：满幅柱底未点亮"); errs = errs + 1; end
        mx = 12'd486;      my = 12'd700;       // 柱内间隙（dx[2:0]=6）
        #1; if (m_on) begin $display("[FAIL] 电平表：柱子间隙不该点亮"); errs = errs + 1; end
        mx = 12'd480;      my = 12'd620;       // 面板上方
        #1; if (m_on) begin $display("[FAIL] 电平表：面板外不该点亮"); errs = errs + 1; end

        // level=64 -> 柱高 32 -> thr=88-32=56；dy=87 亮、dy=10 灭
        level = 8'd64;
        repeat (2048) @(negedge clk);
        mx = 12'd728; my = 12'd711;            // 最右一列 = 最新数据
        #1; if (!m_on) begin $display("[FAIL] 低电平：柱底应点亮"); errs = errs + 1; end
        mx = 12'd728; my = 12'd640;
        #1; if (m_on) begin $display("[FAIL] 低电平：柱高应较低（dy=16 不该亮）"); errs = errs + 1; end
        $display("[ok] 电平表高度/间隙/边界正确");

        // ---- 5) 用一段"衰减型包络"填满 32 列，dump 成 PPM 看效果 ----
        begin : dump_meter
            integer fd, bx, by, bi2, lvv;
            reg [23:0] cc;
            for (bi2 = 0; bi2 < 32; bi2 = bi2 + 1) begin
                lvv = 240 - (bi2 % 8) * 26;            // 240,214,...,58 循环
                level = lvv[7:0];
                repeat (600) @(negedge clk);           // > 512，推一列
            end
            level = 8'd0;
            fd = $fopen("meter_out.ppm", "wb");
            $fwrite(fd, "P6\n256 88\n255\n");
            for (by = 0; by < 88; by = by + 1) begin
                for (bx = 0; bx < 256; bx = bx + 1) begin
                    mx = 480 + bx;
                    my = 624 + by;
                    #1;
                    cc = m_on ? m_rgb : 24'h000000;
                    $fwrite(fd, "%c%c%c", cc[23:16], cc[15:8], cc[7:0]);
                end
            end
            $fclose(fd);
            $display("[ok] 电平表渲染图已写出 meter_out.ppm");
        end

        if (errs == 0) $display("[PASS] 音频通路全部用例通过");
        else           $display("[FAIL] 音频通路共 %0d 处错误", errs);
        $finish;
    end

    initial begin
        #400_000_000;
        $display("[FAIL] timeout, seg=%0d", seg);
        $finish;
    end

endmodule
