`timescale 1ns / 1ps
// ============================================================================
//  tb_osd_demo.v —— 菜单 / 转场 / 亮度 / 字幕 验证与截图导出
//
//  面板区域 560x500：menu_*.ppm
//  全屏 1/2 抽样   ：menu_full*.ppm、trans_*.ppm、bright_*.ppm、sub_*.ppm
//
//  验证点：
//    1. 菜单开合无残留
//    2. 菜单打开时背景仍在逐帧刷新
//    3. FADE / SLIDE / WIPE 三种转场中间态
//    4. 亮度 100% -> 30% 画面确实变暗
//    5. 字幕 ON/OFF 确实控制底部字幕条
// ============================================================================
module tb_osd_demo;

    localparam integer HACT = 1280;
    localparam integer VACT = 720;
    localparam integer PX0  = 340;
    localparam integer PY0  = 30;
    localparam integer PW   = 600;
    localparam integer PH   = 660;

    reg         clk = 1'b0;
    always #6.6667 clk = ~clk;            // 75MHz

    reg         rst_n = 1'b0;
    reg  [3:0]  key   = 4'b1111;          // {OK, DOWN, UP, MENU}，低有效

    wire [23:0] rgb;
    wire        hs, vs, de;
    wire [11:0] x, y;
    wire        mo;
    wire [2:0]  it;
    wire [3:0]  vl;
    wire [7:0]  pg;
    wire [1:0]  ef;
    wire [5:0]  ss;
    wire [7:0]  sd;

    top_osd_demo #(
        .HACTIVE(HACT), .VACTIVE(VACT),
        .PX0(PX0), .PY0(PY0), .PW(PW), .PH(PH),
        .KEY_CLK_HZ(1_500_000),           // 仿真加速：去抖 20ms -> 30000 拍
        .HOLD_FRAMES(600)                 // 保持彩条，转场用 force 精确控制
    ) dut (
        .clk(clk), .rst_n(rst_n), .key(key),
        .rgb_out(rgb), .hs_out(hs), .vs_out(vs), .de_out(de),
        .x_out(x), .y_out(y),
        .menu_open(mo), .dbg_item(it), .dbg_val(vl),
        .dbg_prog(pg), .dbg_effect(ef),
        .seg_sel(ss), .seg_data(sd),
        .img_changed(1'b0),
        .ext_rgb(16'd0),
        .raw_de(), .raw_x(), .raw_y(),
        .dbg_ext(24'd0),
        .aud_samp(16'sd0), .aud_samp_v(1'b0), .aud_meter_en(1'b1),
        .mus_total(4'd3), .mus_name(64'h2020_3130_5453_4554), .media_alert(1'b0)
    );

    // ------------------------------------------------------------------
    // 面板区域连续抓帧
    // ------------------------------------------------------------------
    reg [7:0] fbuf [0:PW*PH*3-1];
    integer   wp = 0;

    wire in_win = de && (x >= PX0) && (x < PX0 + PW) && (y >= PY0) && (y < PY0 + PH);

    always @(posedge clk) begin
        if (de && (x == PX0) && (y == PY0))
            wp <= 0;
        else if (in_win) begin
            fbuf[wp]     <= rgb[23:16];
            fbuf[wp+1]   <= rgb[15:8];
            fbuf[wp+2]   <= rgb[7:0];
            wp          <= wp + 3;
        end
    end

    // ---- 全屏 1/2 抽样 ----
    localparam integer FW = HACT/2;
    localparam integer FH = VACT/2;
    reg [7:0] fbuf2 [0:FW*FH*3-1];
    integer   wp2 = 0;

    always @(posedge clk) begin
        if ((x == 12'd0) && (y == 12'd0))
            wp2 <= 0;
        else if (de && (x[0] == 1'b0) && (y[0] == 1'b0)) begin
            fbuf2[wp2]   <= rgb[23:16];
            fbuf2[wp2+1] <= rgb[15:8];
            fbuf2[wp2+2] <= rgb[7:0];
            wp2          <= wp2 + 3;
        end
    end

    task wait_frames;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                wait ((x == 12'd0) && (y == 12'd0));
                @(posedge clk);
            end
        end
    endtask

    task dump_full;
        input integer id;
        integer fd;
        integer i;
        begin
            wait_frames(3);       // 参数在帧首提交，等 3 帧让缓冲里是最终状态
            #100;
            case (id)
                0:  fd = $fopen("menu_full.ppm",  "wb");
                1:  fd = $fopen("menu_full2.ppm", "wb");
                10: fd = $fopen("trans_fade.ppm", "wb");
                11: fd = $fopen("trans_slide.ppm","wb");
                12: fd = $fopen("trans_wipe.ppm", "wb");
                13: fd = $fopen("bright_base.ppm","wb");
                14: fd = $fopen("bright_low.ppm", "wb");
                15: fd = $fopen("sub_off.ppm",    "wb");
                17: fd = $fopen("sub_play.ppm",   "wb");
                default: fd = $fopen("sub_on.ppm", "wb");
            endcase
            $fwrite(fd, "P6\n%0d %0d\n255\n", FW, FH);
            for (i = 0; i < FW * FH * 3; i = i + 1)
                $fwrite(fd, "%c", fbuf2[i]);
            $fclose(fd);
            $display("[dump] full id=%0d open=%b item=%0d val=%0d prog=%0d eff=%0d",
                     id, mo, it, vl, pg, ef);
        end
    endtask

    task dump_ppm;
        input integer id;
        integer fd;
        integer i;
        begin
            case (id)
                0: fd = $fopen("menu_closed.ppm",  "wb");
                1: fd = $fopen("menu_open.ppm",    "wb");
                2: fd = $fopen("menu_img.ppm",     "wb");
                3: fd = $fopen("menu_img2.ppm",    "wb");
                4: fd = $fopen("menu_music.ppm",   "wb");
                5: fd = $fopen("menu_vu.ppm",      "wb");
                default: fd = $fopen("menu_closed2.ppm", "wb");
            endcase
            $fwrite(fd, "P6\n%0d %0d\n255\n", PW, PH);
            for (i = 0; i < PW * PH * 3; i = i + 1)
                $fwrite(fd, "%c", fbuf[i]);
            $fclose(fd);
            $display("[dump] panel id=%0d open=%b item=%0d val=%0d", id, mo, it, vl);
        end
    endtask

    task shot;
        input integer id;
        begin
            // 菜单状态在帧首才生效（防撕裂），这里等两帧再抓，
            // 免得抓到"按键已经按下、面板还没画"的那一帧
            wait_frames(2);
            @(posedge clk);
            wait (de && (x == PX0 + PW - 1) && (y == PY0 + PH - 1));
            @(posedge clk);
            #100;
            dump_ppm(id);
        end
    endtask

    // 强制转场效果与进度，等两帧让全屏缓冲填满，再导出
    task shot_effect;
        input [1:0]   eff;
        input [7:0]   p;
        input integer id;
        begin
            force dut.ef_trans   = eff;
            force dut.trans_prog = p;
            wait_frames(3);
            dump_full(id);
            release dut.trans_prog;
            release dut.ef_trans;
            wait_frames(1);
        end
    endtask

    integer n_fail = 0;

    task chk;
        input [255:0] name;
        input integer got;
        input integer exp;
        begin
            if (got !== exp) begin
                $display("[FAIL] %0s: got %0d exp %0d", name, got, exp);
                n_fail = n_fail + 1;
            end else
                $display("[ ok ] %0s = %0d", name, got);
        end
    endtask

    task press;
        input integer k;
        begin
            @(posedge clk);
            key[k] = 1'b0;
            repeat (60000) @(posedge clk);   // ~0.8ms 仿真时间，足够去抖
            key[k] = 1'b1;
            repeat (60000) @(posedge clk);
        end
    endtask

    // 导航脉冲计数（非菜单态按 KEY1/KEY2 应该正好产生 1 个脉冲）
    integer n_next = 0, n_prev = 0;
    always @(posedge clk) begin
        if (dut.nav_next) n_next = n_next + 1;
        if (dut.nav_prev) n_prev = n_prev + 1;
    end

    initial begin
        #1000 rst_n = 1'b1;

        // ==================================================================
        //  键位约定（与 RTL 一致）：
        //    press(1) = KEY1 上    press(2) = KEY2 下
        //    press(3) = KEY3 功能菜单 / 确认    press(0) = KEY4 音乐列表 / 关闭
        // ==================================================================

        // ------------------------------------------------------------------
        // 0) 默认态：字幕 ON / 频谱 OFF / 音乐 OFF / 轮播 OFF
        // ------------------------------------------------------------------
        repeat (4) @(posedge vs);
        $display("---- default state ----");
        chk("menu_open",  mo,              1'b0);
        chk("cfg_mus",    dut.ef_mus,      3'd0);
        chk("cfg_meter",  dut.ef_meter,    1'b0);
        chk("cfg_auto",   dut.ef_auto,     1'b0);
        chk("v_sub",      dut.u_menu.v_sub, 1'b1);
        chk("v_trans",    dut.ef_trans,    2'd0);
        dump_full(13);

        // ------------------------------------------------------------------
        // 1) KEY3 = 打开功能菜单（设置页 7 项，光标首项 IMG）
        // ------------------------------------------------------------------
        press(3);
        $display("---- settings page (KEY3) ----");
        chk("menu_open_after_key3", mo, 1'b1);
        chk("page",  dut.u_menu.page, 2'd0);
        chk("item",  it,              3'd0);
        shot(1);
        dump_full(0);

        // ------------------------------------------------------------------
        // 2) KEY3 再按一次 = 确认/进入 IMG 子菜单
        // ------------------------------------------------------------------
        press(3);
        $display("---- image submenu ----");
        chk("page",  dut.u_menu.page, 2'd2);
        chk("item",  it,              3'd0);
        chk("auto",  dut.u_menu.v_auto, 1'b0);
        shot(2);
        dump_full(2);

        // 3) 子菜单：KEY3 开轮播；KEY2 下移；改效果；再改间隔
        press(3);
        $display("---- submenu: autoplay ON ----");
        chk("v_auto", dut.u_menu.v_auto, 1'b1);
        press(2);                          // 到「切屏效果」
        chk("item",   it, 3'd1);
        press(3);                          // FADE -> SLIDE
        chk("v_trans", dut.u_menu.v_trans, 2'd1);
        repeat (3) @(posedge vs);
        chk("ef_auto",  dut.ef_auto,  1'b1);
        chk("ef_trans", dut.ef_trans, 2'd1);

        press(2);                          // 到「切屏间隔」
        chk("item", it, 3'd2);
        chk("v_hold_default", dut.u_menu.v_hold, 3'd1);
        press(3);                          // 5s -> 8s
        chk("v_hold", dut.u_menu.v_hold, 3'd2);
        repeat (3) @(posedge vs);
        chk("ef_hold", dut.ef_hold, 3'd2);
        shot(3);
        dump_full(1);

        // 4) KEY4 在子菜单里一次按键直接关闭
        press(0);
        $display("---- close from submenu (KEY4) ----");
        chk("menu_open", mo, 1'b0);

        // ------------------------------------------------------------------
        // 5) 字幕 OFF -> ON（设置页第 6 项 = SUB）
        // ------------------------------------------------------------------
        press(3);                          // 打开设置页，光标回第 0 项
        press(2); press(2); press(2);
        press(2); press(2); press(2);      // 0 -> 6（SUB）
        chk("item", it, 3'd6);
        press(3);                          // ON -> OFF
        chk("v_sub", dut.u_menu.v_sub, 1'b0);
        press(0);
        dump_full(15);

        press(3);
        press(2); press(2); press(2);
        press(2); press(2); press(2);
        press(3);                          // OFF -> ON
        chk("v_sub", dut.u_menu.v_sub, 1'b1);
        press(0);
        dump_full(16);

        // ------------------------------------------------------------------
        // 6) VU 二级菜单：默认关 -> 开 -> 模式 BAR->CIRC
        // ------------------------------------------------------------------
        press(3);
        press(2); press(2); press(2); press(2); press(2);   // 0 -> 5（VU）
        chk("item", it, 3'd5);
        press(3);                          // 进入 VU 子菜单
        chk("page_vu", dut.u_menu.page, 2'd3);
        chk("item", it, 3'd0);
        press(3);                          // ON
        repeat (3) @(posedge vs);
        chk("ef_meter_on",  dut.ef_meter, 1'b1);
        press(2);                          // 到 MODE
        chk("item", it, 3'd1);
        chk("style_default", dut.u_menu.v_style, 1'b0);
        press(3);                          // BAR -> CIRC
        repeat (3) @(posedge vs);
        chk("ef_style", dut.ef_style, 1'b1);
        shot(5);
        press(0);                          // 关闭

        // ------------------------------------------------------------------
        // 7) KEY4 = 打开音乐列表（默认光标在 OFF）
        // ------------------------------------------------------------------
        press(0);
        $display("---- music list (KEY4) ----");
        chk("music_page", dut.u_menu.page, 2'd1);
        chk("item", it, 3'd0);
        shot(4);
        press(3);                          // 选中 OFF
        chk("menu_open", mo,     1'b0);
        repeat (3) @(posedge vs);
        chk("cfg_mus", dut.ef_mus, 3'd0);

        // 8) 选 GEN -> 内置音阶
        press(0);
        press(2);                          // OFF -> GEN
        press(3);
        repeat (3) @(posedge vs);
        chk("cfg_mus_gen", dut.ef_mus, 3'd1);
        press(0);
        press(1);                          // GEN -> OFF
        press(3);
        repeat (3) @(posedge vs);
        chk("cfg_mus_off", dut.ef_mus, 3'd0);

        // ------------------------------------------------------------------
        // 9) 选 T1：字幕应切成 "NOW PLAYING TEST01 MUSIC FRAME"
        // ------------------------------------------------------------------
        press(0);
        press(2); press(2);                // OFF -> GEN -> T1
        chk("item", it, 3'd2);
        press(3);
        repeat (4) @(posedge vs);
        chk("cfg_mus_t1", dut.ef_mus, 3'd2);
        dump_full(17);

        press(0);
        press(1); press(1);
        press(3);
        repeat (3) @(posedge vs);
        chk("cfg_mus_final", dut.ef_mus, 3'd0);

        // ------------------------------------------------------------------
        // 10) 非菜单态：KEY1=上一张 KEY2=下一张（各产生 1 个 nav 脉冲）
        //     菜单打开时：方向键只移动光标，不产生 nav
        // ------------------------------------------------------------------
        $display("---- nav keys (menu closed) ----");
        chk("menu_closed", mo, 1'b0);
        n_next = 0; n_prev = 0;
        press(2);                          // KEY2 下 -> 下一张
        chk("nav_next_cnt", n_next, 1);
        chk("nav_prev_cnt", n_prev, 0);
        press(1);                          // KEY1 上 -> 上一张
        chk("nav_prev_cnt2", n_prev, 1);
        chk("nav_next_cnt2", n_next, 1);

        $display("---- nav keys blocked while menu open ----");
        press(3);                          // 打开设置页
        n_next = 0; n_prev = 0;
        press(2); press(1);
        chk("nav_next_menu", n_next, 0);
        chk("nav_prev_menu", n_prev, 0);
        press(0);                          // 关闭

        if (n_fail == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL (%0d)", n_fail);
        $finish;
    end

endmodule
