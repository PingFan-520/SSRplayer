// ============================================================================
//  tb_bmp_scale_chain.v —— 解码 + 缩放 全链路仿真（用真实 BMP 文件）
//
//  把 图片资源/test_1280x720.bmp 的字节一个时钟一个喂给 bmp_decode，
//  再把解码输出接 bmp_scale，把缩放后的 640x480 框（RGB565）dump 成 .raw，
//  由 sim/cmp_scale.py 转 PNG 并与 Python 侧的期望采样逐像素比对。
//
//  用法（run_scale.bat chain <bmp路径>）：
//    vsim -c -do "run -all; quit -f" work_scale.tb_bmp_scale_chain \
//         -gFILE=...
// ============================================================================
`timescale 1ns / 1ps

module tb_bmp_scale_chain;

    parameter integer DW = 640;
    parameter integer DH = 480;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #13.3 clk = ~clk;

    reg  [7:0] s_data  = 8'd0;
    reg        s_valid = 1'b0;

    wire        o_we;
    wire [11:0] o_sx, o_sy, o_x, o_y;
    wire [15:0] o_rgb, img_w, img_h;
    wire        img_ok, eof, fdone;

    bmp_decode #(.FB_WIDTH(1280), .FB_HEIGHT(720)) u_bmp (
        .clk(clk), .rst(rst),
        .s_data(s_data), .s_valid(s_valid), .s_ready(),
        .o_we(o_we), .o_x(o_x), .o_y(o_y),
        .o_sx(o_sx), .o_sy(o_sy), .o_rgb565(o_rgb),
        .o_eof(eof), .o_frame_done(fdone),
        .o_img_w(img_w), .o_img_h(img_h), .o_hdr_ok(img_ok)
    );

    wire        sc_we;
    wire [11:0] sc_x, sc_y;
    wire [15:0] sc_rgb;
    wire [2:0]  sc_k;

    reg [1:0] mode_t = 2'd0;       // +MODE=0/1/2

    bmp_scale #(.DW(DW), .DH(DH)) u_scale (
        .clk(clk), .rst(rst),
        .s_we(o_we), .s_sx(o_sx), .s_sy(o_sy), .s_rgb(o_rgb),
        .img_w(img_w), .img_h(img_h), .mode(mode_t),
        .clr(1'b0), .clr_done(), .clr_busy(),
        .o_rdy(1'b1),
        .o_we(sc_we), .o_x(sc_x), .o_y(sc_y), .o_rgb(sc_rgb), .o_k(sc_k)
    );

    // ------------------------------------------------------------------
    // 捕获
    // ------------------------------------------------------------------
    reg [15:0] cap [0:DW*DH-1];
    integer i, cnt;
    initial begin
        cnt = 0;
        for (i = 0; i < DW*DH; i = i + 1) cap[i] = 16'h0000;
    end

    always @(posedge clk) begin
        if (sc_we) begin
            cap[sc_y*DW + sc_x] <= sc_rgb;
            cnt = cnt + 1;
        end
    end

    // ------------------------------------------------------------------
    // 主流程：从文件逐字节喂
    // ------------------------------------------------------------------
    integer fd, ch, nbyte, x, y, void_ignore;
    reg [1023:0] fname;

    initial begin
        if (!$value$plusargs("FILE=%s", fname)) begin
            $display("[ERR] 需要 +FILE=<bmp>");
            $finish;
        end
        void_ignore = $value$plusargs("MODE=%d", mode_t);
        $display("[chain] mode=%0d (0=FIT 1=FILL 2=STRETCH)", mode_t);
        fd = $fopen(fname, "rb");
        if (fd == 0) begin
            $display("[ERR] 打不开 %0s", fname);
            $finish;
        end

        repeat (5) @(negedge clk);
        rst = 1'b0;
        repeat (5) @(negedge clk);

        nbyte = 0;
        ch = $fgetc(fd);
        while (ch != -1 && !eof) begin
            @(negedge clk);
            s_valid = 1'b1;
            s_data  = ch[7:0];
            nbyte   = nbyte + 1;
            ch      = $fgetc(fd);
        end
        @(negedge clk);
        s_valid = 1'b0;
        $fclose(fd);

        repeat (20) @(negedge clk);

        $display("[chain] 喂入 %0d 字节, 图片 %0dx%0d, k=%0d, 输出 %0d 像素",
                 nbyte, img_w, img_h, sc_k, cnt);

        // dump RGB565（小端）
        fd = $fopen("scale_out.raw", "wb");
        for (y = 0; y < DH; y = y + 1)
            for (x = 0; x < DW; x = x + 1) begin
                $fwrite(fd, "%c", cap[y*DW+x][7:0]);
                $fwrite(fd, "%c", cap[y*DW+x][15:8]);
            end
        $fclose(fd);
        $display("[chain] 已写出 scale_out.raw");
        $finish;
    end

    initial begin
        #400_000_000;
        $display("[ERR] timeout");
        $finish;
    end

endmodule
