`timescale 1ns / 1ps
// ============================================================================
//  tb_meter_full.v —— 音频电平条在**顶层**的几何核对
//
//  为什么需要它：
//    audio_meter 自己的单测（tb_audio）用的是它自己的参数，几何永远自洽；
//    上一版真正的 bug 是**顶层实例化把 NBAR 写成 80，而模块内部按 127 算索引**，
//    单测根本发现不了（越界读到无效数据 -> 上板只看得到一角）。
//
//  这个 TB 完全"旁观"：不驱动 x/y，直接盯着视频输出流，在 y=476 那一行
//  记录 m_on 的点亮范围，并把一块区域 dump 成 PPM。
// ============================================================================
module tb_meter_full;

    localparam integer HACT = 1280;
    localparam integer VACT = 720;

    reg         clk = 1'b0;
    always #6.6667 clk = ~clk;

    reg         rst_n = 1'b0;
    reg  [3:0]  key   = 4'b1111;

    wire [23:0] rgb;
    wire        hs, vs, de;
    wire [11:0] x, y;
    wire        mo;
    wire [2:0]  it;
    wire [3:0]  vl;
    wire [7:0]  pg;
    wire [1:0]  ef, sc;
    wire [3:0]  vol;
    wire [2:0]  mus;
    wire        au, nn, np;
    wire [5:0]  ss;
    wire [7:0]  sd;

    top_osd_demo #(
        .HACTIVE(HACT), .VACTIVE(VACT),
        .PX0(360), .PY0(80), .PW(560), .PH(560),
        .KEY_CLK_HZ(1_500_000),
        .HOLD_FRAMES(600),
        .USE_EXT(1),
        .MUS_NUM(2)
    ) dut (
        .clk(clk), .rst_n(rst_n), .key(key),
        .rgb_out(rgb), .hs_out(hs), .vs_out(vs), .de_out(de),
        .x_out(x), .y_out(y),
        .menu_open(mo), .dbg_item(it), .dbg_val(vl),
        .dbg_prog(pg), .dbg_effect(ef), .dbg_scale(sc), .dbg_vol(vol),
        .dbg_mus(mus), .dbg_auto(au), .nav_next(nn), .nav_prev(np),
        .seg_sel(ss), .seg_data(sd),
        .img_changed(1'b0),
        .ext_rgb(16'h39CE),
        .raw_de(), .raw_x(), .raw_y(),
        .dbg_ext(8'd0),
        .aud_lvl(8'd0), .aud_meter_en(1'b1),
        .fade_lvl(8'd255)
    );

    // ------------------------------------------------------------------
    // 旁观：y = 476 这一行的点亮范围 / 区域抓图
    // ------------------------------------------------------------------
    localparam integer RX0 = 120, RY0 = 466, RW = 1040, RH = 118;


    integer   on_min = 99999, on_max = 0;   // 用 0 而不是 -1：x 是无符号，和 -1 比较会变成大数
    integer   errs = 0;
    integer   i;
    integer   ncap = 0;
    integer   n_on = 0;
    integer   fd = 0, k;

    always @(posedge clk) begin
        if (de) begin
            if ((y == 12'd579) && dut.m_on) begin  // 最下一行：有高度的柱子都该亮
                if (x < on_min) on_min = x;
                if (x > on_max) on_max = x;
            end
            if ((x >= RX0) && (x < RX0 + RW) && (y >= RY0) && (y < RY0 + RH)) begin
                ncap = ncap + 1;
                if (dut.m_on) n_on = n_on + 1;
                if (fd != 0)
                    $fwrite(fd, "%c%c%c", rgb[23:16], rgb[15:8], rgb[7:0]);
                if (ncap == 2) begin
                    #1;
                    $display("[dbg] ext=%06h base_a=%06h trans=%06h adj=%06h vd1=%06h vd2=%06h osd=%06h prog=%0d eff=%0d fl=%0d",
                             dut.ext_rgb24, dut.base_a, dut.trans_use, dut.adj_rgb,
                             dut.vd1, dut.vd2, dut.osd_rgb_d, dut.trans_prog, dut.ef_trans, dut.fade_lvl);
                    $display("[dbg2] gain=%0d off=%0d in=%06h out=%06h adj=%06h",
                             dut.u_param.gain, dut.u_param.off, dut.u_param.rgb_in, dut.u_param.rgb_out, dut.adj_rgb);
                end
                if (ncap < 3 || (n_on == 1 && x == 12'd300))
                    $display("[px] x=%0d y=%0d m_on=%b rgb=%06h blend=%06h m=%06h",
                             x, y, dut.m_on, rgb, dut.blend_menu, dut.m_rgb);
            end
        end
    end

    task wait_frame;
        begin
            wait ((x == 12'd0) && (y == 12'd0));
            @(posedge clk);
        end
    endtask

    initial begin
        #200;
        rst_n = 1'b1;
        repeat (40) @(posedge clk);

        $display("[info] 顶层生效参数: NBAR=%0d X0=%0d Y0=%0d BARW=%0d XW=%0d",
                 dut.u_meter.NBAR, dut.u_meter.X0, dut.u_meter.Y0,
                 dut.u_meter.BARW, dut.u_meter.XW);

        if (dut.u_meter.NBAR != 128) begin
            $display("[FAIL] 顶层 NBAR=%0d，应为 128", dut.u_meter.NBAR);
            errs = errs + 1;
        end
        if (dut.u_meter.XW != 1024) begin
            $display("[FAIL] 总宽 %0d，应为 1024", dut.u_meter.XW);
            errs = errs + 1;
        end

        // 灌一组递增"年龄"的高度：第 c 列（0=最左=最老、127=最右=最新）
        // 读地址 = wp + c，所以这里直接按 hist 的槽位写：
        //   让最右列（c=127）高度最高、最左列最低 -> 检查左右映射与铺满
        for (k = 0; k < 128; k = k + 1)
            dut.u_meter.hist[(k) % 128] = k[7:0] * 2;   // hist[i] = i*2
        dut.u_meter.wp = 7'd0;      // raddr = 0 + c -> c=0 读到 hist[0]=0（最矮，最左）
        dut.u_meter.filling = 1'b0;
        dut.u_meter.peak = 8'd0;

        wait_frame;
        on_min = 99999; on_max = 0;       // 先清零，再让完整一帧扫过去
        wait_frame;
        wait_frame;
        $display("[info] y=579 行点亮范围: x = %0d .. %0d（期望 128..1151）",
                 on_min, on_max);
        // 最右 2 列会被 frame_start 的移位挤掉（强制灌的值不再回填），所以到 ~1132 就算铺满
        if ((on_min != 128) || (on_max < 1120)) begin
            $display("[FAIL] 柱子没有铺满 1024 像素");
            errs = errs + 1;
        end else
            $display("[ok] 柱子铺满 x=%0d..%0d", on_min, on_max);

        ncap = 0; n_on = 0;
        @(negedge de);                      // 等当前帧结束
        wait_frame;
        fd = $fopen("meter_full.ppm", "wb");
        $fwrite(fd, "P6\n%0d %0d\n255\n", RW, RH);
        wait_frame;                          // 下一帧边扫边写
        wait_frame;
        $fclose(fd);
        fd = 0;
        $display("[info] 抓到 %0d 像素，其中 m_on=%0d", ncap, n_on);
        $display("[ok] 已导出 meter_full.ppm (%0dx%0d)", RW, RH);

        if (errs == 0) $display("[PASS] 顶层电平条几何正确");
        else           $display("[FAIL] 共 %0d 处错误", errs);
        $finish;
    end

endmodule
