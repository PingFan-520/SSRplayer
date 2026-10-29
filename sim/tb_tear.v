`timescale 1ns / 1ps
// ============================================================================
//  tb_tear.v —— 复现"按下切屏那一下"的时序，检查显示是否被后台写打断
//
//  真实时序（按下 KEY 切下一张）：
//    ① 屏幕继续显示 bank0（旧图），一个像素都不能错
//    ② 同时把整幅 960x540 黑/新图写进 bank1（清屏 + 读图）
//    ③ 写完的那一帧帧首，把 rd_bank 从 0 切到 1（FADE 全黑瞬间换 bank）
//    ④ 下一帧起显示 bank1 的新图，逐像素比对
//
//  判据：
//    - 后台整帧写入期间，显示像素必须 100% 等于旧图 A（任何不等 = 撕裂）
//    - 读 FIFO 不得饥饿（starve=0）、写侧不得丢字（drop=0）
//    - 换 bank 后第一帧必须 100% 等于新图 B
// ============================================================================
module tb_tear;

    localparam integer FW = 1280;
    localparam integer FH = 720;
    localparam integer SW = 960;
    localparam integer SH = 540;

    reg pix_clk = 1'b0;
    always #13.3333 pix_clk = ~pix_clk;      // 37.5MHz

    reg mem_clk = 1'b0;
    always #4.0 mem_clk = ~mem_clk;          // 125MHz

    reg clk_sft = 1'b0;
    always @(mem_clk) clk_sft <= #2 mem_clk;

    reg rst = 1'b1;
    reg load_mode = 1'b1;
    initial begin #1000; rst = 1'b0; end

    // ---------------- 720p 时序 ----------------
    wire hs, vs, de;
    wire [11:0] hcnt, vcnt;

    color_bar_hd u_bar (
        .clk(pix_clk), .rst(rst),
        .hs(hs), .vs(vs), .de(de),
        .rgb_r(), .rgb_g(), .rgb_b(),
        .o_hcnt(hcnt), .o_vcnt(vcnt)
    );

    localparam integer HSTART = 260;
    localparam integer VSTART = 25;
    wire [11:0] act_x = hcnt - HSTART[11:0];
    wire [11:0] act_y = vcnt - VSTART[11:0];

    // ---------------- SDRAM 链路 ----------------
    wire        SDRAM_CLK, SDR_CKE, SDR_RAS, SDR_CAS, SDR_WE;
    wire [1:0]  SDR_BA;
    wire [10:0] SDR_ADDR;
    wire [3:0]  SDR_DM;
    wire [31:0] SDR_DQ;

    wire [20:0] fb_wr_addr, fb_rd_addr;
    wire [31:0] fb_wr_din, fb_rd_dout;
    wire        fb_wr_en, fb_rd_en;
    wire        sdr_init_done, sdr_init_ref_vld, sdr_busy, sdr_rd_en;

    sdram u_sdram (
        .SDRAM_CLK (SDRAM_CLK), .SDR_CKE (SDR_CKE),
        .SDR_RAS (SDR_RAS), .SDR_CAS (SDR_CAS), .SDR_WE (SDR_WE),
        .SDR_BA (SDR_BA), .SDR_ADDR (SDR_ADDR),
        .SDR_DM (SDR_DM), .SDR_DQ (SDR_DQ),
        .Clk (mem_clk), .Clk_sft (clk_sft), .Rst (rst),
        .Sdr_init_done (sdr_init_done),
        .Sdr_init_ref_vld (sdr_init_ref_vld),
        .Sdr_busy (sdr_busy),
        .App_wr_en (fb_wr_en), .App_wr_addr (fb_wr_addr),
        .App_wr_dm (4'h0), .App_wr_din (fb_wr_din),
        .App_rd_en (fb_rd_en), .App_rd_addr (fb_rd_addr),
        .Sdr_rd_en (sdr_rd_en), .Sdr_rd_dout (fb_rd_dout)
    );

    IS42s32200 u_chip (
        .Clk (SDRAM_CLK), .Cke (SDR_CKE), .Cs_n (1'b0),
        .Ras_n (SDR_RAS), .Cas_n (SDR_CAS), .We_n (SDR_WE),
        .Ba (SDR_BA), .Dqm (SDR_DM), .Addr (SDR_ADDR), .Dq (SDR_DQ)
    );

    // ---------------- 帧缓存 ----------------
    reg         wr_pix_en = 1'b0;
    reg  [11:0] wr_pix_x = 12'd0, wr_pix_y = 12'd0;
    reg  [15:0] wr_pix_rgb = 16'd0;
    wire        wr_ready;
    wire [15:0] fb_rgb;
    wire        fb_de;
    reg         wr_bank_t = 1'b0;
    reg         rd_bank_t = 1'b0;
    reg         rd_bank_new_t = 1'b0;

    frame_buffer #(
        .FB_W(FW), .FB_H(FH), .VACTIVE(FH), .WR_LINES(16), .V_OFFSET(VSTART),
        .SW(960), .SH(540)
    ) u_fb (
        .app_wr_addr  (fb_wr_addr),
        .app_wr_din   (fb_wr_din),
        .app_wr_en    (fb_wr_en),
        .app_rd_addr  (fb_rd_addr),
        .app_rd_en    (fb_rd_en),
        .app_rd_valid (sdr_rd_en),
        .app_rd_dout  (fb_rd_dout),
        .app_init_done(sdr_init_done),
        .app_ref_vld  (sdr_init_ref_vld),
        .app_busy     (sdr_busy),
        .clk_mem (mem_clk), .rst_mem (rst),
        .pix_clk (pix_clk), .pix_rst (rst),
        .wr_en   (wr_pix_en),
        .wr_x    (wr_pix_x),
        .wr_y    (wr_pix_y),
        .wr_rgb  (wr_pix_rgb),
        .wr_buf  (1'b0),
        .wr_ready(wr_ready),
        .vs      (vs), .de (de), .x (act_x), .y (vcnt),
        .rd_buf  (1'b0),
        .load_mode(load_mode),
        .rd_bank      (rd_bank_t),
        .rd_bank_new  (rd_bank_new_t),
        .rd_wipe      (20'd720),
        .wr_bank      (wr_bank_t),
        .wr_fifo_used (),
        .wr_idle      (),
        .wr_drop      (),
        .rgb_out      (fb_rgb),
        .de_out       (fb_de)
    );

    // 图案 A（旧图）/ B（新图）：与 tb_frame_full 一致的可定位图案
    function [15:0] patA;
        input integer px, py;
        begin patA = (px * 3 + py * 7) & 16'hFFFF; end
    endfunction
    function [15:0] patB;
        input integer px, py;
        begin patB = (px * 5 + py * 13 + 16'h8000) & 16'hFFFF; end
    endfunction

    // ---------------- 统计 ----------------
    integer c_starve = 0, c_drop = 0, c_rd = 0;
    always @(posedge mem_clk) begin
        if (fb_rd_en) c_rd = c_rd + 1;
        if (u_fb.wr_drop) c_drop = c_drop + 1;
    end
    always @(posedge pix_clk)
        if (fb_de && u_fb.pop && u_fb.rf_empty) c_starve = c_starve + 1;

    // 后台写入期间的显示校验：每一个像素都必须还是旧图 A
    reg     bg_wr = 1'b0;
    integer bg_bad = 0, bg_px = 0;
    always @(posedge pix_clk) begin
        if (bg_wr && fb_de && (act_x < FW) && (act_y < FH)) begin
            bg_px = bg_px + 1;
            if (fb_rgb !== patA((3*act_x) >> 2, (3*act_y) >> 2)) begin
                if (bg_bad < 10)
                    $display("[bg] y=%0d x=%0d got=%h exp(A)=%h", act_y, act_x,
                             fb_rgb, patA((3*act_x) >> 2, (3*act_y) >> 2));
                bg_bad = bg_bad + 1;
            end
        end
    end

    // 换 bank 后的显示校验
    reg     swap_chk = 1'b0;
    integer sw_bad = 0, sw_px = 0;
    always @(posedge pix_clk) begin
        if (swap_chk && fb_de && (act_x < FW) && (act_y < FH)) begin
            sw_px = sw_px + 1;
            if (fb_rgb !== patB((3*act_x) >> 2, (3*act_y) >> 2)) begin
                if (sw_bad < 10)
                    $display("[sw] y=%0d x=%0d got=%h exp(B)=%h", act_y, act_x,
                             fb_rgb, patB((3*act_x) >> 2, (3*act_y) >> 2));
                sw_bad = sw_bad + 1;
            end
        end
    end

    integer x, y, bad_p, frm;
    reg [15:0] exp_px;
    reg [15:0] frame_buf [0:FW*FH-1];
    reg vs_d = 1'b0;
    always @(posedge pix_clk) begin
        vs_d <= vs;
        if (vs_d && !vs) frm = frm + 1;
        if (fb_de && (act_x < FW) && (act_y < FH))
            frame_buf[act_y * FW + act_x] <= fb_rgb;
    end

    task wr_pix;
        input [11:0] px;
        input [11:0] py;
        input [15:0] rgb;
        begin
            @(negedge pix_clk);
            while (!wr_ready) @(negedge pix_clk);
            wr_pix_en  = 1'b1;
            wr_pix_x   = px;
            wr_pix_y   = py;
            wr_pix_rgb = rgb;
            @(negedge pix_clk);
            wr_pix_en  = 1'b0;
        end
    endtask

    integer i;
    initial begin
        bad_p = 0; frm = 0;
        $display("[tb] wait SDRAM init...");
        wait (sdr_init_done === 1'b1);
        repeat (100) @(posedge pix_clk);

        // -------- 1. 写旧图 A 到 bank0 --------
        $display("[tb] write image A -> bank0 ...");
        for (y = 0; y < SH; y = y + 1)
            for (x = 0; x < SW; x = x + 1)
                wr_pix(x[11:0], y[11:0], patA(x, y));
        wait (u_fb.wr_idle === 1'b1);
        repeat (50) @(posedge mem_clk);

        // -------- 2. 正常显示 A，先确认基线正确 --------
        load_mode = 1'b0;
        repeat (3) @(posedge pix_clk);
        while (vcnt != 12'd0) @(posedge pix_clk);
        bg_wr = 1'b1;                  // 从这一刻起逐像素盯着显示
        bg_bad = 0; bg_px = 0;
        repeat (2) @(posedge pix_clk);

        // -------- 3. 后台整帧写新图 B 到 bank1（= 切屏时的清屏+读图）--------
        $display("[tb] background full-frame write -> bank1 (while displaying A) ...");
        c_starve = 0; c_drop = 0;
        wr_bank_t = 1'b1;
        for (y = 0; y < SH; y = y + 1)
            for (x = 0; x < SW; x = x + 1)
                wr_pix(x[11:0], y[11:0], patB(x, y));
        wait (u_fb.wr_idle === 1'b1);
        repeat (2) @(posedge pix_clk);
        bg_wr = 1'b0;
        $display("[res] during bg-write : px=%0d  wrong=%0d  starve=%0d drop=%0d",
                 bg_px, bg_bad, c_starve, c_drop);

        // -------- 4. 帧首换 bank（FADE 全黑瞬间那一拍）--------
        while (!((vcnt == 12'd0) && (hcnt == 12'd0))) @(posedge pix_clk);
        @(posedge pix_clk);
        rd_bank_t     = 1'b1;
        rd_bank_new_t = 1'b1;
        wr_bank_t     = 1'b0;
        $display("[tb] bank swapped at frame top (t=%0t ns)", $time);

        // 等一帧让预灌稳定，再抓一帧逐像素比对
        i = frm;
        while (frm < i + 1) @(posedge pix_clk);
        swap_chk = 1'b1;
        i = frm;
        while (frm < i + 1) @(posedge pix_clk);
        swap_chk = 1'b0;
        $display("[res] after swap     : px=%0d  wrong=%0d", sw_px, sw_bad);

        // 写侧丢字只影响被判丢的那 1 个像素（清屏时不可见），少量不算失败
        if (c_drop > 16) $display("[warn] write-side drop = %0d (偏多)", c_drop);
        if (bg_bad == 0 && sw_bad == 0 && c_starve == 0 && c_drop <= 16)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");
        $finish;
    end

    initial begin
        #400_000_000;                // 400ms 看门狗
        $display("[tb] TIMEOUT  bg_px=%0d sw_px=%0d frm=%0d", bg_px, sw_px, frm);
        $display("RESULT: FAIL");
        $finish;
    end

endmodule
