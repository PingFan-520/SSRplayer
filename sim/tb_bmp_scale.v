// ============================================================================
//  tb_bmp_scale.v —— bmp_scale 单元测试
//
//  验证四件事：
//    1. k 的选择        640x480 -> 0；1280x720 -> 1；1920x1080 -> 2
//    2. 坐标映射         每个输出像素的坐标/颜色是否等于对应源像素
//    3. 输出像素数       = (w>>k) * (h>>k)
//    4. 清屏             640x480 全写 0，覆盖整个框
// ============================================================================
`timescale 1ns / 1ps

module tb_bmp_scale;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #13.3 clk = ~clk;          // 37.5MHz

    reg        s_we  = 1'b0;
    reg [11:0] s_sx  = 12'd0;
    reg [11:0] s_sy  = 12'd0;
    reg [15:0] s_rgb = 16'd0;
    reg [15:0] img_w = 16'd0;
    reg [15:0] img_h = 16'd0;
    reg [1:0]  mode  = 2'd0;

    reg        clr = 1'b0;
    wire       clr_done, clr_busy;
    reg        o_rdy = 1'b1;

    wire        o_we;
    wire [11:0] o_x, o_y;
    wire [15:0] o_rgb;
    wire [2:0]  o_k;

    bmp_scale #(.DW(640), .DH(480)) dut (
        .clk(clk), .rst(rst),
        .s_we(s_we), .s_sx(s_sx), .s_sy(s_sy), .s_rgb(s_rgb),
        .img_w(img_w), .img_h(img_h), .mode(mode),
        .clr(clr), .clr_done(clr_done), .clr_busy(clr_busy),
        .o_rdy(o_rdy), .o_we(o_we), .o_x(o_x), .o_y(o_y), .o_rgb(o_rgb),
        .o_k(o_k)
    );

    // ------------------------------------------------------------------
    // 输出捕获
    // ------------------------------------------------------------------
    reg [15:0] cap  [0:640*480-1];
    reg        seen [0:640*480-1];

    integer o_cnt;            // 累计输出的像素数
    integer i;

    initial begin
        o_cnt = 0;
        for (i = 0; i < 640*480; i = i + 1) begin
            cap[i]  = 16'hDEAD;
            seen[i] = 1'b0;
        end
    end

    always @(posedge clk) begin
        if (o_we) begin
            cap [o_y*640 + o_x] <= o_rgb;
            seen[o_y*640 + o_x] <= 1'b1;
            o_cnt = o_cnt + 1;
        end
    end

    // ------------------------------------------------------------------
    // 工具任务
    // ------------------------------------------------------------------
    task clear_cap;
        integer k;
        begin
            for (k = 0; k < 640*480; k = k + 1) begin
                cap[k]  = 16'hDEAD;
                seen[k] = 1'b0;
            end
            o_cnt = 0;
        end
    endtask

    // 送一整幅 "坐标编码" 图案：颜色 = {sx[7:0], sy[7:0]}
    task send_img(input integer W, input integer H);
        integer xx, yy;
        begin
            img_w = W[15:0];
            img_h = H[15:0];
            for (yy = 0; yy < H; yy = yy + 1) begin
                for (xx = 0; xx < W; xx = xx + 1) begin
                    @(negedge clk);
                    s_we  = 1'b1;
                    s_sx  = xx[11:0];
                    s_sy  = yy[11:0];
                    s_rgb = {xx[7:0], yy[7:0]};
                end
            end
            @(negedge clk);
            s_we = 1'b0;
            repeat (4) @(negedge clk);
        end
    endtask

    // 检查一个目标像素：期望来自源 ( (dx-xoff)<<k , (dy-yoff)<<k )
    integer err_total;
    task chk_pix(input integer dx, input integer dy,
                 input integer kk, input integer xo, input integer yo);
        integer sx, sy;
        reg [15:0] exp_c;
        begin
            sx = (dx - xo) << kk;
            sy = (dy - yo) << kk;
            exp_c = {sx[7:0], sy[7:0]};
            if (!seen[dy*640 + dx]) begin
                err_total = err_total + 1;
                if (err_total < 12)
                    $display("  [ERR] (%0d,%0d) 没有输出", dx, dy);
            end else if (cap[dy*640 + dx] !== exp_c) begin
                err_total = err_total + 1;
                if (err_total < 12)
                    $display("  [ERR] (%0d,%0d) 得到 %04h 期望 %04h (源 %0d,%0d)",
                             dx, dy, cap[dy*640 + dx], exp_c, sx, sy);
            end
        end
    endtask

    // 每轴不同缩放指数的检查（STRETCH: kx!=ky）
    task chk_pix2(input integer dx, input integer dy,
                  input integer kkx, input integer kky,
                  input integer xo, input integer yo);
        integer sx, sy;
        reg [15:0] exp_c;
        begin
            sx = (dx - xo) << kkx;
            sy = (dy - yo) << kky;
            exp_c = {sx[7:0], sy[7:0]};
            if (!seen[dy*640 + dx]) begin
                err_total = err_total + 1;
                if (err_total < 12)
                    $display("  [ERR] (%0d,%0d) 没有输出", dx, dy);
            end else if (cap[dy*640 + dx] !== exp_c) begin
                err_total = err_total + 1;
                if (err_total < 12)
                    $display("  [ERR] (%0d,%0d) 得到 %04h 期望 %04h (源 %0d,%0d)",
                             dx, dy, cap[dy*640 + dx], exp_c, sx, sy);
            end
        end
    endtask

    task chk_empty(input integer dx, input integer dy);
        begin
            if (seen[dy*640 + dx]) begin
                err_total = err_total + 1;
                if (err_total < 12)
                    $display("  [ERR] (%0d,%0d) 本应是黑边却有输出", dx, dy);
            end
        end
    endtask

    // ------------------------------------------------------------------
    // 主流程
    // ------------------------------------------------------------------
    integer x, y, n;

    initial begin
        err_total = 0;

        repeat (5) @(negedge clk);
        rst = 1'b0;
        repeat (5) @(negedge clk);

        // ---------- 用例 1：640x480 直通 ----------
        $display("[case1] 640x480 直通");
        clear_cap;
        send_img(640, 480);
        if (o_k !== 3'd0) begin err_total = err_total + 1; $display("  [ERR] k=%0d 应为 0", o_k); end
        if (o_cnt !== 640*480) begin err_total = err_total + 1; $display("  [ERR] 输出 %0d 像素，应为 %0d", o_cnt, 640*480); end
        // 抽查 5 个点（含四角）
        chk_pix(0,   0,   0, 0, 0);
        chk_pix(639, 479, 0, 0, 0);
        chk_pix(320, 240, 0, 0, 0);
        chk_pix(1,   1,   0, 0, 0);
        chk_pix(639, 0,   0, 0, 0);

        // ---------- 用例 2：1280x720 -> k=1，640x360 居中(yoff=60) ----------
        $display("[case2] 1280x720 -> 640x360 yoff=60");
        clear_cap;
        send_img(1280, 720);
        if (o_k !== 3'd1) begin err_total = err_total + 1; $display("  [ERR] k=%0d 应为 1", o_k); end
        if (o_cnt !== 640*360) begin err_total = err_total + 1; $display("  [ERR] 输出 %0d 像素，应为 %0d", o_cnt, 640*360); end
        chk_pix(0,   60,  1, 0, 60);
        chk_pix(639, 419, 1, 0, 60);
        chk_pix(320, 240, 1, 0, 60);
        chk_pix(1,   61,  1, 0, 60);
        chk_empty(0, 0);          // 上边黑边
        chk_empty(639, 479);      // 下边黑边
        chk_empty(0, 59);
        chk_empty(0, 420);

        // ---------- 用例 3：1920x1080 -> k=2，480x270 居中(80,105) ----------
        $display("[case3] 1920x1080 -> 480x270 xoff=80 yoff=105");
        clear_cap;
        send_img(1920, 1080);
        if (o_k !== 3'd2) begin err_total = err_total + 1; $display("  [ERR] k=%0d 应为 2", o_k); end
        if (o_cnt !== 480*270) begin err_total = err_total + 1; $display("  [ERR] 输出 %0d 像素，应为 %0d", o_cnt, 480*270); end
        chk_pix(80,  105, 2, 80, 105);
        chk_pix(559, 374, 2, 80, 105);
        chk_pix(320, 240, 2, 80, 105);
        chk_empty(79, 104);
        chk_empty(80, 104);

        // ---------- 用例 5：FILL 1280x720 -> 1:1 中心裁切 ----------
        //   kx=ky=0, ox=(640-1280)/2=-320, oy=(480-720)/2=-120
        //   目标(dx,dy) 取源 (dx+320, dy+120)，正好铺满、四边各裁 320/120
        $display("[case5] FILL 1280x720 -> 1:1 中心裁切 640x480");
        mode = 2'd1;
        clear_cap;
        send_img(1280, 720);
        if (o_k !== 3'd0) begin err_total = err_total + 1; $display("  [ERR] kx=%0d 应为 0", o_k); end
        if (o_cnt !== 640*480) begin err_total = err_total + 1; $display("  [ERR] 输出 %0d 像素，应为 %0d", o_cnt, 640*480); end
        chk_pix(0,   0,   0, -320, -120);
        chk_pix(639, 479, 0, -320, -120);
        chk_pix(320, 240, 0, -320, -120);
        chk_pix(1,   1,   0, -320, -120);

        // ---------- 用例 6：STRETCH 1280x720 -> 宽度压到 640、纵向裁切 ----------
        //   kx=1(1280>>1=640), ky=0, ox=0, oy=(480-720)/2=-120
        //   目标(dx,dy) 取源 (2dx, dy+120)
        $display("[case6] STRETCH 1280x720 -> 640x480 铺满(纵向裁切)");
        mode = 2'd2;
        clear_cap;
        send_img(1280, 720);
        if (o_k !== 3'd1) begin err_total = err_total + 1; $display("  [ERR] kx=%0d 应为 1", o_k); end
        if (o_cnt !== 640*480) begin err_total = err_total + 1; $display("  [ERR] 输出 %0d 像素，应为 %0d", o_cnt, 640*480); end
        chk_pix2(0,   0,   1, 0, 0, -120);
        chk_pix2(639, 479, 1, 0, 0, -120);
        chk_pix2(320, 240, 1, 0, 0, -120);
        chk_pix2(1,   1,   1, 0, 0, -120);

        // 回到 FIT 再清屏
        mode = 2'd0;

        // ---------- 用例 4：清屏 ----------
        $display("[case4] 清屏 640x480");
        clear_cap;
        @(negedge clk); clr = 1'b1;
        wait (clr_done);
        @(negedge clk); clr = 1'b0;
        repeat (4) @(negedge clk);
        if (o_cnt !== 640*480) begin err_total = err_total + 1; $display("  [ERR] 清屏写了 %0d 像素，应为 %0d", o_cnt, 640*480); end
        n = 0;
        for (y = 0; y < 480; y = y + 1)
            for (x = 0; x < 640; x = x + 1) begin
                if (!seen[y*640+x]) n = n + 1;
                else if (cap[y*640+x] !== 16'h0000) n = n + 1;
            end
        if (n != 0) begin err_total = err_total + 1; $display("  [ERR] 清屏有 %0d 个像素不对", n); end

        // ---------- 汇总 ----------
        if (err_total == 0) $display("[PASS] bmp_scale 全部用例通过");
        else                $display("[FAIL] bmp_scale 共 %0d 处错误", err_total);
        $finish;
    end

    initial begin
        #600_000_000;                   // 兜底超时 600ms（6 组用例共约 500 万拍）
        $display("[FAIL] timeout, o_cnt=%0d", o_cnt);
        $finish;
    end

endmodule
