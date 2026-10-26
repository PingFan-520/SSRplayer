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
    localparam integer PX0  = 360;
    localparam integer PY0  = 110;
    localparam integer PW   = 560;
    localparam integer PH   = 500;

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
        .dbg_ext(8'd0),
        .aud_samp(16'sd0), .aud_samp_v(1'b0), .aud_meter_en(1'b1)
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
                3: fd = $fopen("menu_slide.ppm",   "wb");
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

    initial begin
        #1000 rst_n = 1'b1;

        // 1) 关菜单：彩条 + 底部字幕
        repeat (2) @(posedge vs);
        shot(0);
        dump_full(13);                    // 基准亮度 100%

        // 2) 打开菜单
        press(0);
        shot(1);
        dump_full(0);
        dump_full(1);                     // 相邻两帧：验证背景仍在动

        // 3) 下移 3 次到「缩放模式」，上移 3 次回第一项并改值 FADE -> SLIDE
        press(2); press(2); press(2);
        press(1); press(1); press(1);
        press(3);
        shot(3);

        // 4) 关菜单后看三种转场中间态
        press(0);
        shot(4);
        shot_effect(2'd0, 8'd128, 10);    // FADE 50%
        shot_effect(2'd1, 8'd96,  11);    // SLIDE 37.5%
        shot_effect(2'd2, 8'd160, 12);    // WIPE  62.5%

        // 5) 亮度 100% -> 30%
        press(0);                         // 打开
        press(2);                         // 光标到「亮度」
        press(3); press(3); press(3); press(3);   // 10 -> 0 -> 1 -> 2 -> 3
        press(0);                         // 关闭
        dump_full(14);

        // 6) 字幕 OFF
        press(0);                         // 打开，光标仍在「亮度」
        press(2); press(2); press(2);     // 到「字幕」
        press(3);                         // ON -> OFF
        press(0);                         // 关闭
        dump_full(15);

        // 7) 字幕 ON（恢复）
        press(0);
        press(3);
        press(0);
        dump_full(16);

        $display("done, menu_open=%b", mo);
        $finish;
    end

endmodule
