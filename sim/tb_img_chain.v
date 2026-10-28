// ============================================================================
//  tb_img_chain.v —— 真实 BMP 走 "解码 -> 3/4 缩放" 的逐像素校验
//
//  目的：区分"显示错位"是数据损坏还是 4:3 重采样本身的锯齿。
//   1) 统计每个 (x,y) 被写了几次：必须恰好 1 次，且每行 x=0..959 连续
//   2) 与 Python 生成的期望图逐像素比对
//
//  用法：期望文件 img_exp.bin（960*540*2 字节，RGB565 小端，行优先）
// ============================================================================
`timescale 1ns / 1ps

module tb_img_chain;

    localparam integer DW = 960;
    localparam integer DH = 540;

    reg clk = 1'b0;
    always #13.333 clk = ~clk;          // 37.5MHz

    reg rst = 1'b1;

    // ---------------- 字节流 ----------------
    reg [7:0] bmp [0:3_000_000];
    integer   bmp_n;
    integer   bi;
    reg       s_valid;
    reg [7:0] s_data;

    // ---------------- 解码 ----------------
    wire        o_we;
    wire [11:0] o_x, o_y, o_sx, o_sy;
    wire [15:0] o_rgb;
    wire        o_eof, o_frame_done, o_hdr_ok;
    wire [15:0] o_img_w, o_img_h;

    bmp_decode #(.FB_WIDTH(1280), .FB_HEIGHT(720)) u_dec (
        .clk(clk), .rst(rst),
        .s_data(s_data), .s_valid(s_valid), .s_ready(),
        .o_we(o_we), .o_x(o_x), .o_y(o_y), .o_rgb565(o_rgb),
        .o_sx(o_sx), .o_sy(o_sy),
        .o_eof(o_eof), .o_frame_done(o_frame_done),
        .o_img_w(o_img_w), .o_img_h(o_img_h), .o_hdr_ok(o_hdr_ok)
    );

    // ---------------- 缩放 ----------------
    wire        p_we;
    wire [11:0] p_x, p_y;
    wire [15:0] p_rgb;
    wire [2:0]  p_k;

    // 模拟帧缓存写窗口：o_rdy 大部分时间为 0，只有一小段为 1
    reg        o_rdy_r = 1'b1;
    integer    cyc = 0;
    always @(posedge clk) begin
        cyc <= cyc + 1;
        o_rdy_r <= ((cyc % 3000) < 700);
    end

    wire scale_busy;

    bmp_scale #(.DW(DW), .DH(DH)) u_scale (
        .clk(clk), .rst(rst),
        .s_we(o_we), .s_sx(o_sx), .s_sy(o_sy), .s_rgb(o_rgb),
        .img_w(o_img_w), .img_h(o_img_h), .mode(2'd0),
        .clr(1'b0), .clr_done(), .clr_busy(),
        .o_rdy(o_rdy_r),
        .o_we(p_we), .o_x(p_x), .o_y(p_y), .o_rgb(p_rgb), .o_k(p_k), .o_busy(scale_busy), .o_full()
    );

    // ---------------- 收集 ----------------
    reg [15:0] cap [0:DW*DH-1];
    reg [7:0]  cnt [0:DW*DH-1];      // 每个位置被写了几次
    integer    n_we, n_bad_pos, n_missing, n_mismatch;

    always @(posedge clk) begin
        if (p_we) begin
            cap[p_y*DW + p_x] <= p_rgb;
            cnt[p_y*DW + p_x] <= cnt[p_y*DW + p_x] + 8'd1;
            n_we = n_we + 1;
        end
    end

    // ---------------- 期望图 ----------------
    reg [7:0] expb [0:DW*DH*2-1];
    integer   efd, en;

    integer i, x, y, bad;
    initial begin
        n_we = 0; n_bad_pos = 0; n_missing = 0; n_mismatch = 0;
        for (i = 0; i < DW*DH; i = i + 1) begin
            cap[i] = 16'hDEAD; cnt[i] = 8'd0;
        end

        efd = $fopen("img_exp.bin", "rb");
        if (efd == 0) begin $display("ERROR: img_exp.bin missing"); $finish; end
        en = $fread(expb, efd);
        $fclose(efd);
        $display("[tb] expect bytes %0d", en);

        bi = $fopen("img_src.bmp", "rb");
        if (bi == 0) begin $display("ERROR: img_src.bmp missing"); $finish; end
        bmp_n = $fread(bmp, bi);
        $fclose(bi);
        $display("[tb] bmp bytes %0d", bmp_n);

        repeat (20) @(posedge clk);
        rst <= 1'b0;
        repeat (10) @(posedge clk);

        // 按 FIFO 的节奏送字节：每 2 拍 1 个
        for (i = 0; i < bmp_n; i = i + 1) begin
            // 反压：缩放器忙时不送字节（与 top_board 里 sfifo_rd 的门控等价）
            while (scale_busy) @(posedge clk);
            @(posedge clk);
            s_valid <= 1'b1;
            s_data  <= bmp[i];
            @(posedge clk);
            s_valid <= 1'b0;
        end
        repeat (200) @(posedge clk);

        $display("[res] pulses=%0d (expect 518400)  hdr_ok=%b img=%0dx%0d k=%0d",
                 n_we, o_hdr_ok, o_img_w, o_img_h, p_k);

        // 覆盖性检查
        bad = 0;
        for (y = 0; y < DH; y = y + 1)
            for (x = 0; x < DW; x = x + 1) begin
                if (cnt[y*DW+x] == 8'd0) begin
                    if (n_missing < 8) $display("[miss] (%0d,%0d)", x, y);
                    n_missing = n_missing + 1;
                end else if (cnt[y*DW+x] > 8'd1) begin
                    if (n_bad_pos < 8) $display("[dup ] (%0d,%0d) cnt=%0d", x, y, cnt[y*DW+x]);
                    n_bad_pos = n_bad_pos + 1;
                end
                if (cap[y*DW+x] !== {expb[(y*DW+x)*2+1], expb[(y*DW+x)*2]}) begin
                    if (n_mismatch < 8)
                        $display("[pix ] (%0d,%0d) got=%h exp=%h",
                                 x, y, cap[y*DW+x], {expb[(y*DW+x)*2+1], expb[(y*DW+x)*2]});
                    n_mismatch = n_mismatch + 1;
                end
            end

        $display("[res] missing=%0d dup=%0d mismatch=%0d", n_missing, n_bad_pos, n_mismatch);
        if (n_missing == 0 && n_bad_pos == 0 && n_mismatch == 0 && n_we == DW*DH)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");
        $finish;
    end

endmodule
