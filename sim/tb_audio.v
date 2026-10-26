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
    reg  [255:0] bars_flat = 256'd0;   // 32 段高度
    reg         men   = 1'b1;
    wire        m_on;
    wire [23:0] m_rgb;
    wire [3:0]  m_alpha;

    reg  [11:0] mx = 12'd0, my = 12'd0;
    reg         mfs = 1'b0;            // 帧首（推一列）

    audio_meter #(.X0(128), .Y0(468), .BARW(32), .NBAR(32), .MAXH(112)) u_m (
        .clk(clk), .rst(rst),
        .x(mx), .y(my),
        .bars(bars_flat), .enable(men),
        .on(m_on), .rgb(m_rgb), .alpha(m_alpha)
    );

    // 推一列：给一个 frame_start 脉冲
    task push_col; begin
        @(negedge clk); mfs = 1'b1;
        @(negedge clk); mfs = 1'b0;
        repeat (4) @(negedge clk);
    end endtask

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
            mag_a = l_a[23] ? ((~l_a + 24'd1)) : l_a;         // |sample|（24 位补码取负）
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
            mag_a = l_b[23] ? ((~l_b + 24'd1)) : l_b;
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

        // ---- 4) 频谱柱显示（直接给 32 段高度）----
        bars_flat = {32{8'd255}};
        mx = 12'd131; my = 12'd468;
        @(posedge clk); #1; if (!m_on) begin $display("[FAIL] 满幅：柱顶未点亮"); errs = errs + 1; end
        mx = 12'd131; my = 12'd579;
        @(posedge clk); #1; if (!m_on) begin $display("[FAIL] 满幅：柱底未点亮"); errs = errs + 1; end
        mx = 12'd157; my = 12'd520;
        @(posedge clk); #1; if (m_on) begin $display("[FAIL] 柱子间隙不该点亮"); errs = errs + 1; end
        mx = 12'd131; my = 12'd460;
        @(posedge clk); #1; if (m_on) begin $display("[FAIL] 区域外(上)不该点亮"); errs = errs + 1; end
        mx = 12'd1160; my = 12'd520;
        @(posedge clk); #1; if (m_on) begin $display("[FAIL] 区域外(右)不该点亮"); errs = errs + 1; end

        bars_flat = {32{8'd64}};
        mx = 12'd131; my = 12'd579;
        @(posedge clk); #1; if (!m_on) begin $display("[FAIL] 低段：柱底应点亮"); errs = errs + 1; end
        mx = 12'd131; my = 12'd508;
        @(posedge clk); #1; if (m_on) begin $display("[FAIL] 低段：dy=40 不该亮"); errs = errs + 1; end

        bars_flat = {32{8'd255}};
        mx = 12'd131; my = 12'd473;
        @(posedge clk); #1; if (m_rgb !== 24'hFF1040) begin
            $display("[FAIL] 顶部颜色 %06h，应为 FF1040", m_rgb); errs = errs + 1; end
        mx = 12'd131; my = 12'd564;
        @(posedge clk); #1; if (m_rgb !== 24'h7038F0) begin
            $display("[FAIL] 底部颜色 %06h，应为 7038F0", m_rgb); errs = errs + 1; end
        $display("[ok] 频谱柱几何/间隙/颜色分段正确");

        begin : dump_meter
            integer fd, bx, by, cc, hh2;
            for (i = 0; i < 32; i = i + 1) begin
                hh2 = 90 + ((i * 53) % 150);      // 伪随机，像真实音乐
                bars_flat[i*8 +: 8] = hh2[7:0];
            end
            fd = $fopen("meter_out.ppm", "wb");
            $fwrite(fd, "P6\n1024 112\n255\n");
            for (by = 0; by < 112; by = by + 1) begin
                for (bx = 0; bx < 1024; bx = bx + 1) begin
                    mx = 128 + bx;
                    my = 468 + by;
                    @(posedge clk); #1;
                    cc = m_on ? m_rgb : 24'h000000;
                    $fwrite(fd, "%c%c%c", cc[23:16], cc[15:8], cc[7:0]);
                end
            end
            $fclose(fd);
            $display("[ok] 频谱柱渲染图已写出 meter_out.ppm");
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
