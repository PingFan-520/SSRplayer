`timescale 1ns / 1ps
// ============================================================================
//  tb_meter_wf.v —— 电平条"瀑布"写入/读出方向与铺满的单测
//
//  不接整个视频通路，直接给 frame_start 打脉冲，128 帧内就能把历史写满，
//  然后逐列核对顶部亮起的位置，确认：
//    ① 最新的一列在最右边，越往左越老（左移的方向是对的）
//    ② 每一列的显示高度 = 该帧写入的电平（不丢列、不清零）
//
//  期望关系：第 c 列（0=最左、127=最右）= 128-c 帧之前的那个电平值。
// ============================================================================
module tb_meter_wf;

    localparam integer NBAR = 128;
    localparam integer BARW = 8;
    localparam integer X0   = 128;
    localparam integer Y0   = 468;
    localparam integer MAXH = 112;
    localparam integer NFRM = 128;          // 正好一圈：每个槽写一次，写完后 wp=0

    reg         clk = 1'b0;
    always #13.333 clk = ~clk;              // 37.5MHz

    reg         rst = 1'b1;
    reg         fs  = 1'b0;
    reg  [7:0]  lvl = 8'd0;
    reg  [11:0] px  = 12'd0, py = 12'd0;

    wire        on;
    wire [23:0] rgb;
    wire [3:0]  alpha;

    audio_meter #(
        .X0(X0), .Y0(Y0), .BARW(BARW), .NBAR(NBAR), .MAXH(MAXH)
    ) u_m (
        .clk(clk), .rst(rst),
        .x(px), .y(py),
        .frame_start(fs),
        .level(lvl), .enable(1'b1),
        .on(on), .rgb(rgb), .alpha(alpha)
    );

    // 第 f 帧写入的电平
    function [7:0] lv_of;
        input integer f;
        integer v;
        begin
            v = f + 10;                     // 10..137，每个槽唯一 -> 一眼看出错位
            lv_of = v[7:0];
        end
    endfunction

    // 期望高度（与 RTL 一致）：hh = lv/2 + lv/8，钳到 MAXH
    function integer hh_of;
        input [7:0] v;
        integer h;
        begin
            h = (v >> 1) + (v >> 3);
            hh_of = (h > MAXH) ? MAXH : h;
        end
    endfunction

    integer f, c, dy, exp_top, got_top, errs;
    reg [7:0] hist_lv [0:NBAR-1];           // 期望：地址 -> 电平

    initial begin
        errs = 0;
        for (c = 0; c < NBAR; c = c + 1) hist_lv[c] = 8'd0;

        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (3) @(posedge clk);

        // 先把"出声瞬间整幅铺满"(filling) 放完，再把历史清零对齐，
        // 这样后面每一帧的写指针位置都是确定的（否则前 16 帧会被 filling 吞掉）
        lvl = 8'd1;
        repeat (400) @(posedge clk);
        for (c = 0; c < NBAR; c = c + 1) u_m.hist[c] = 8'd0;
        u_m.wp   = 7'd0;
        u_m.peak = 8'd0;
        @(posedge clk);

        // ---- 写 140 帧 ----
        for (f = 0; f < NFRM; f = f + 1) begin
            lvl = lv_of(f);
            // 让 level 保持几拍，peak 才吃得到
            repeat (4) @(posedge clk);
            fs = 1'b1; @(posedge clk); fs = 1'b0;
            hist_lv[f % NBAR] = lv_of(f);   // 该帧写进 hist[f % 128]
            repeat (3) @(posedge clk);
        end
        lvl = 8'd0;
        repeat (4) @(posedge clk);

        // ---- 逐列核对 ----
        for (c = 0; c < NBAR; c = c + 1) begin
            // 写完 128 帧后 wp=0，第 c 列读 hist[c]，其内容就是 f=c 那一帧
            exp_top = MAXH - hh_of(hist_lv[c % NBAR]);

            got_top = -1;
            for (dy = 0; dy < MAXH; dy = dy + 1) begin
                px = X0 + c * BARW + 2;
                py = Y0 + dy;
                @(posedge clk); #1;
                if (on) begin got_top = dy; dy = MAXH; end
            end

            if (got_top != exp_top) begin
                if (errs < 8)
                    $display("[FAIL] 第 %0d 列(槽%0d): 顶点 %0d 期望 %0d | hist=%0d 模型=%0d",
                             c, c, got_top, exp_top, u_m.hist[c], hist_lv[c]);
                errs = errs + 1;
            end
        end

        // ---- 落柱：静音 10 帧后最新一列应比原来少 80（每帧 -8）----
        lvl = 8'd0;
        // 第 1 帧的 peak 还是上一帧的残留，不参与衰减；从第 2 帧开始每帧 -8
        for (f = 0; f < 11; f = f + 1) begin
            fs = 1'b1; @(posedge clk); fs = 1'b0;
            repeat (3) @(posedge clk);
        end
        begin : dk
            integer newest, want;
            newest = u_m.hist[(u_m.wp - 1'b1)];
            want   = (137 > 80) ? (137 - 80) : 0;
            if (newest != want) begin
                $display("[FAIL] 静音 10 帧后最新列 = %0d，期望 %0d（每帧 -8）",
                         newest, want);
                errs = errs + 1;
            end else
                $display("[ok] 静音时按每帧 -8 下落（10 帧衰减后 %0d）", newest);
        end
        // 再静音 40 帧应落到 0
        for (f = 0; f < 40; f = f + 1) begin
            fs = 1'b1; @(posedge clk); fs = 1'b0;
            repeat (3) @(posedge clk);
        end
        if (u_m.hist[(u_m.wp - 1'b1)] != 8'd0) begin
            $display("[FAIL] 静音 50 帧后最新列仍为 %0d，应落到 0", u_m.hist[(u_m.wp - 1'b1)]);
            errs = errs + 1;
        end else
            $display("[ok] 静音 50 帧后落到底（0）");

        if (errs == 0)
            $display("[ok] 128 列全部与写入的电平一致（方向=右新左老、无丢列）");
        else
            $display("[FAIL] %0d 列不符", errs);

        // ---- 最右列与最左列必须不同（证明真的在平移，不是静止）----
        if (hist_lv[(NFRM - 1) % NBAR] == hist_lv[(NFRM - NBAR) % NBAR])
            $display("[warn] 本用例左右两端电平恰好相同，方向性由上面的逐列核对保证");

        if (errs == 0) $display("[PASS] 电平条瀑布方向与铺满正确");
        else           $display("[FAIL] 共 %0d 处错误", errs);
        $finish;
    end

endmodule
