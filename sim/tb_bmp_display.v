`timescale 1ns / 1ps
// ============================================================================
//  tb_bmp_display.v —— 真实 BMP + 转场 + OSD 菜单 的显示链验证
//
//  用两张真实 640x480 BMP 填充行为级帧存（模拟 SDRAM 的两块 buffer），
//  再走与 top_osd_demo 相同的输出链：
//    帧存 -> 转场 -> 亮度/对比度 -> 4 拍对齐 -> alpha_blend(菜单) -> PPM
//
//  导出：
//    bmp_a.ppm        图 A（菜单关）
//    bmp_fade.ppm     A->B 淡入淡出 50%
//    bmp_menu.ppm     图 B + 菜单打开
// ============================================================================
module tb_bmp_display;

    localparam integer FW = 1280;
    localparam integer FH = 720;
    localparam integer PX0 = 360;
    localparam integer PY0 = 110;
    localparam integer PW  = 560;
    localparam integer PH  = 500;
    localparam integer HSTART = 260;
    localparam integer VSTART = 25;

    reg clk = 1'b0;
    always #6.6667 clk = ~clk;

    reg rst = 1'b1;
    initial #200 rst = 1'b0;

    // ------------------------------------------------------------------
    // 720p 时序
    // ------------------------------------------------------------------
    wire hs, vs, de;
    wire [11:0] hcnt, vcnt;

    color_bar_hd u_bar (
        .clk(clk), .rst(rst),
        .hs(hs), .vs(vs), .de(de),
        .rgb_r(), .rgb_g(), .rgb_b(),
        .o_hcnt(hcnt), .o_vcnt(vcnt)
    );

    wire [11:0] act_x = hcnt - HSTART[11:0];
    wire [11:0] act_y = vcnt - VSTART[11:0];

    // ------------------------------------------------------------------
    // 两块行为级帧存（板上是 SDRAM 的两个 buffer）
    // ------------------------------------------------------------------
    reg [15:0] fbA [0:FW*FH-1];
    reg [15:0] fbB [0:FW*FH-1];

    // ------------------------------------------------------------------
    // 两个解码器，各自喂一张图
    // ------------------------------------------------------------------
    reg  [7:0] a_data = 8'd0,  b_data = 8'd0;
    reg        a_vld  = 1'b0,  b_vld  = 1'b0;
    wire       a_we, b_we, a_done, b_done, a_ok, b_ok;
    wire [11:0] a_x, a_y, b_x, b_y;
    wire [15:0] a_px, b_px, a_w, a_h, b_w, b_h;

    bmp_decode #(.FB_WIDTH(FW), .FB_HEIGHT(FH)) u_dec_a (
        .clk(clk), .rst(rst), .s_data(a_data), .s_valid(a_vld), .s_ready(),
        .o_we(a_we), .o_x(a_x), .o_y(a_y), .o_rgb565(a_px),
        .o_frame_done(a_done), .o_img_w(a_w), .o_img_h(a_h), .o_hdr_ok(a_ok)
    );

    bmp_decode #(.FB_WIDTH(FW), .FB_HEIGHT(FH)) u_dec_b (
        .clk(clk), .rst(rst), .s_data(b_data), .s_valid(b_vld), .s_ready(),
        .o_we(b_we), .o_x(b_x), .o_y(b_y), .o_rgb565(b_px),
        .o_frame_done(b_done), .o_img_w(b_w), .o_img_h(b_h), .o_hdr_ok(b_ok)
    );

    always @(posedge clk) if (a_we) fbA[a_y * FW + a_x] <= a_px;
    always @(posedge clk) if (b_we) fbB[b_y * FW + b_x] <= b_px;

    // ------------------------------------------------------------------
    // 视频源：从帧存取像素（行为级）
    // ------------------------------------------------------------------
    wire [15:0] px_a = fbA[act_y * FW + act_x];
    wire [15:0] px_b = fbB[act_y * FW + act_x];

    function [23:0] to888;
        input [15:0] p;
        begin
            to888 = {p[15:11], 3'b0, p[10:5], 2'b0, p[4:0], 3'b0};
        end
    endfunction

    // ------------------------------------------------------------------
    // 转场 + 亮度
    // ------------------------------------------------------------------
    reg  [1:0] eff  = 2'd0;
    reg  [7:0] prog = 8'd0;

    wire [23:0] trans_rgb, adj_rgb;

    transition #(.HACTIVE(FW)) u_tr (
        .clk(clk), .rst(rst),
        .rgb_a(to888(px_a)), .rgb_b(to888(px_b)),
        .x(act_x), .effect(eff), .prog(prog), .rgb_out(trans_rgb)
    );

    param_apply u_pa (
        .rgb_in(trans_rgb), .bright(4'd10), .contrast(4'd10), .rgb_out(adj_rgb)
    );

    // ------------------------------------------------------------------
    // 4 拍延时 + OSD
    // ------------------------------------------------------------------
    reg [23:0] vd1, vd2;
    reg        hsd1, hsd2, hsd3, hsd4, vsd1, vsd2, vsd3, vsd4, ded1, ded2, ded3, ded4;
    reg [11:0] xd1, xd2, xd3, xd4, yd1, yd2, yd3, yd4;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            vd1 <= 0; vd2 <= 0;
            hsd1 <= 0; hsd2 <= 0; hsd3 <= 0; hsd4 <= 0;
            vsd1 <= 0; vsd2 <= 0; vsd3 <= 0; vsd4 <= 0;
            ded1 <= 0; ded2 <= 0; ded3 <= 0; ded4 <= 0;
            xd1 <= 0; xd2 <= 0; xd3 <= 0; xd4 <= 0;
            yd1 <= 0; yd2 <= 0; yd3 <= 0; yd4 <= 0;
        end else begin
            vd1 <= adj_rgb; vd2 <= vd1;
            hsd1 <= hs; hsd2 <= hsd1; hsd3 <= hsd2; hsd4 <= hsd3;
            vsd1 <= vs; vsd2 <= vsd1; vsd3 <= vsd2; vsd4 <= vsd3;
            ded1 <= de; ded2 <= ded1; ded3 <= ded2; ded4 <= ded3;
            xd1 <= act_x; xd2 <= xd1; xd3 <= xd2; xd4 <= xd3;
            yd1 <= act_y; yd2 <= yd1; yd3 <= yd2; yd4 <= yd3;
        end
    end

    reg         menu_key = 1'b0, up_key = 1'b0, dn_key = 1'b0, ok_key = 1'b0;
    wire        osd_on;
    wire [23:0] osd_rgb;
    wire [3:0]  osd_alpha;
    wire        menu_open;
    wire [2:0]  dbg_item;
    wire [3:0]  dbg_val;
    wire        cfg_commit;
    wire [1:0]  cfg_trans, cfg_scale;
    wire [3:0]  cfg_bright, cfg_contrast, cfg_vol;
    wire        cfg_sub;

    osd_menu #(
        .HACTIVE(FW), .VACTIVE(FH), .PX0(PX0), .PY0(PY0), .PW(PW), .PH(PH)
    ) u_menu (
        .clk(clk), .rst(rst),
        .x(act_x), .y(act_y), .de(de),
        .key_menu(menu_key), .key_up(up_key), .key_down(dn_key), .key_ok(ok_key),
        .osd_on(osd_on), .osd_rgb(osd_rgb), .osd_alpha(osd_alpha),
        .menu_open(menu_open), .dbg_item(dbg_item), .dbg_val(dbg_val),
        .cfg_commit(cfg_commit),
        .cfg_trans(cfg_trans), .cfg_bright(cfg_bright), .cfg_contrast(cfg_contrast),
        .cfg_scale(cfg_scale), .cfg_sub(cfg_sub), .cfg_vol(cfg_vol)
    );

    reg [23:0] od_rgb;
    reg [3:0]  od_alpha;
    reg        od_on;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            od_rgb <= 0; od_alpha <= 0; od_on <= 0;
        end else begin
            od_rgb <= osd_rgb; od_alpha <= osd_alpha; od_on <= osd_on;
        end
    end

    wire [23:0] rgb_out;
    alpha_blend u_bl (
        .vid_rgb(vd2), .osd_rgb(od_rgb), .alpha(od_alpha), .out_rgb(rgb_out)
    );

    // ------------------------------------------------------------------
    // 全屏抓帧
    // ------------------------------------------------------------------
    localparam integer DW = FW/2;
    localparam integer DH = FH/2;
    reg [7:0] cap [0:DW*DH*3-1];
    integer   wp = 0;

    always @(posedge clk) begin
        if ((xd4 == 12'd0) && (yd4 == 12'd0))
            wp <= 0;
        else if (ded4 && (xd4[0] == 1'b0) && (yd4[0] == 1'b0)) begin
            cap[wp]   <= rgb_out[23:16];
            cap[wp+1] <= rgb_out[15:8];
            cap[wp+2] <= rgb_out[7:0];
            wp        <= wp + 3;
        end
    end

    task dump;
        input [8*32-1:0] name;
        integer f, k;
        begin
            wait ((xd4 == 12'd0) && (yd4 == 12'd0));
            repeat (3) @(posedge vsd4);
            wait ((xd4 == 12'd0) && (yd4 == 12'd0));
            @(posedge clk); #100;
            f = $fopen(name, "wb");
            $fwrite(f, "P6\n%0d %0d\n255\n", DW, DH);
            for (k = 0; k < DW*DH*3; k = k + 1) $fwrite(f, "%c", cap[k]);
            $fclose(f);
            $display("[dump] %0s  menu=%b item=%0d val=%0d prog=%0d", name, menu_open, dbg_item, dbg_val, prog);
        end
    endtask

    // ------------------------------------------------------------------
    // 喂文件
    // ------------------------------------------------------------------
    reg [7:0] memA [0:1200000];
    reg [7:0] memB [0:1200000];
    integer nA, nB, fa, fbb, i;

    initial begin
        fa  = $fopen("img_a.bmp", "rb");
        fbb = $fopen("img_b.bmp", "rb");
        nA  = $fread(memA, fa);  $fclose(fa);
        nB  = $fread(memB, fbb); $fclose(fbb);
        $display("[tb] A=%0d bytes  B=%0d bytes", nA, nB);
    end

    // A 先喂，B 后喂（顺序喂，避免两个 always 抢时序）
    initial begin
        wait (rst == 1'b0);
        repeat (10) @(posedge clk);

        for (i = 0; i < nA; i = i + 1) begin
            @(negedge clk); a_data = memA[i]; a_vld = 1'b1;
            @(negedge clk); a_vld = 1'b0;
        end
        repeat (5) @(posedge clk);
        $display("[tb] image A done=%b ok=%b %0dx%0d", a_done, a_ok, a_w, a_h);

        for (i = 0; i < nB; i = i + 1) begin
            @(negedge clk); b_data = memB[i]; b_vld = 1'b1;
            @(negedge clk); b_vld = 1'b0;
        end
        repeat (5) @(posedge clk);
        $display("[tb] image B done=%b ok=%b %0dx%0d", b_done, b_ok, b_w, b_h);
    end

    // ------------------------------------------------------------------
    // 场景
    // ------------------------------------------------------------------
    initial begin
        // 等两张图都解码完
        wait (a_done == 1'b1);
        wait (b_done == 1'b1);
        repeat (2) @(posedge vsd4);

        eff = 2'd0; prog = 8'd0;
        dump("bmp_a.ppm");

        prog = 8'd128;
        dump("bmp_fade.ppm");

        prog = 8'd255;
        dump("bmp_b.ppm");

        // 打开菜单
        @(negedge clk); menu_key = 1'b1; @(negedge clk); menu_key = 1'b0;
        repeat (10) @(posedge clk);
        dump("bmp_menu.ppm");

        $display("ALL_DONE");
        $finish;
    end

endmodule
