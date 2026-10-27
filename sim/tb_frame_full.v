`timescale 1ns / 1ps
// ============================================================================
//  tb_frame_full.v —— 满屏帧缓存通路验证（960x540 存储 -> 1280x720 显示）
//
//  1) 用 load_mode 把 960x540 的线性图案写进 bank0；
//  2) 逐字比对 SDRAM 里 259,200 个字；
//  3) 切回正常显示，抓一帧，逐像素比对 4:3 上采样结果：
//        期望像素 = pat((3x)>>2, (3y)>>2)
//  4) 统计读 burst 数（应为 720 行 x 120 组 = 86,400）与 FIFO 饥饿。
// ============================================================================
module tb_frame_full;

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

    // ---------------- 真实 SDRAM 链路 ----------------
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
    reg        wr_pix_en  = 1'b0;
    reg        wr_bank_t  = 1'b0;
    reg [11:0] wr_pix_x   = 12'd0;
    reg [11:0] wr_pix_y   = 12'd0;
    reg [15:0] wr_pix_rgb = 16'd0;

    wire [15:0] fb_rgb;
    wire        fb_de, wr_ready;

    frame_buffer #(
        .FB_W(FW), .FB_H(FH), .VACTIVE(FH), .WR_LINES(16), .V_OFFSET(VSTART),
        .SW(SW), .SH(SH)
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

        .clk_mem (mem_clk),
        .rst_mem (rst),

        .pix_clk (pix_clk),
        .pix_rst (rst),
        .wr_en   (wr_pix_en),
        .wr_x    (wr_pix_x),
        .wr_y    (wr_pix_y),
        .wr_rgb  (wr_pix_rgb),
        .wr_buf  (1'b0),
        .wr_ready(wr_ready),

        .vs      (vs),
        .de      (de),
        .x       (act_x),
        .y       (vcnt),
        .rd_buf  (1'b0),
        .load_mode(load_mode),
        .rd_bank (1'b0),
        .rd_bank_new(1'b0),
        .rd_wipe (20'd720),
        .wr_bank (wr_bank_t),
        .wr_fifo_used(),
        .wr_idle (),
        .wr_drop (),
        .rgb_out (fb_rgb),
        .de_out  (fb_de)
    );

    // 图案：低 16 位 = x*3 + y*7，逐像素变化，便于抓移位/错行
    function [15:0] pat;
        input integer px, py;
        begin
            pat = (px * 3 + py * 7) & 16'hFFFF;
        end
    endfunction

    // ---------------- 统计 ----------------
    integer c_rd = 0, c_starve = 0, c_drop = 0;
    always @(posedge mem_clk) begin
        if (fb_rd_en) c_rd = c_rd + 1;
        if (u_fb.wr_drop) c_drop = c_drop + 1;
    end
    // 显示要数据（该弹字）但 FIFO 空 = 饥饿
    always @(posedge pix_clk)
        if (fb_de && u_fb.pop && u_fb.rf_empty) c_starve = c_starve + 1;

    // ---------------- 抓帧 ----------------
    reg [15:0] frame_buf [0:FW*FH-1];
    integer frm = 0, frm0 = 0;
    reg vs_d2 = 1'b0;
    always @(posedge pix_clk) begin
        vs_d2 <= vs;
        if (vs_d2 && !vs && frm > 2)
            $display("[st] frm=%0d win=%b used=%0d rstart=%0d burst=%b busy=%b empty=%b rd=%0d starve=%0d",
                     frm, u_fb.wr_win_m, u_fb.rf_used, u_fb.rstart, u_fb.rburst,
                     u_fb.app_busy, u_fb.rf_empty, c_rd, c_starve);
    end

    reg vs_dd = 1'b0;
    always @(posedge pix_clk) begin
        vs_dd <= vs;
        if (vs_dd && !vs) frm = frm + 1;      // 每帧一次（vs 下降沿）
    end
    always @(posedge pix_clk)
        if (fb_de && (act_x < FW) && (act_y < FH))
            frame_buf[act_y * FW + act_x] <= fb_rgb;

    integer x, y, xw, bad_w, bad_p, bad_win, bad_bank2, fd;
    integer rf_peak = 0;
    always @(posedge mem_clk)
        if (u_fb.rf_used > rf_peak) rf_peak = u_fb.rf_used;
    integer chk_rd_base;
    reg [15:0] exp_word, exp_px;
    reg [31:0] rd_word;

    initial begin
        bad_w = 0; bad_p = 0; bad_bank2 = 0;
        $display("[tb] waiting SDRAM init...");
        wait (sdr_init_done === 1'b1);
        $display("[tb] init_done at %0t ns", $time);
        repeat (100) @(posedge pix_clk);

        // ---------- 1. 写入 960x540 ----------
        $display("[tb] write 960x540 (load_mode=1)...");
        for (y = 0; y < SH; y = y + 1) begin
            for (x = 0; x < SW; x = x + 1) begin
                @(negedge pix_clk);
                while (!wr_ready) @(negedge pix_clk);
                wr_pix_en  = 1'b1;
                wr_pix_x   = x[11:0];
                wr_pix_y   = y[11:0];
                wr_pix_rgb = pat(x, y);
                @(negedge pix_clk);
                wr_pix_en = 1'b0;
            end
        end
        $display("[tb] write done, waiting wr_idle...");
        wait (u_fb.wr_idle === 1'b1);
        repeat (50) @(posedge mem_clk);

        // ---------- 2. SDRAM 内容比对 ----------
        for (y = 0; y < SH; y = y + 1) begin
            for (xw = 0; xw < SW/2; xw = xw + 1) begin
                exp_word = {pat(2*xw, y), pat(2*xw + 1, y)};
                rd_word  = u_chip.Bank0[y*480 + xw];
                if (rd_word[15:0] !== exp_word[15:0]) begin
                    if (bad_w < 6)
                        $display("[w] y=%0d xw=%0d got=%h exp=%h", y, xw, rd_word[15:0], exp_word);
                    bad_w = bad_w + 1;
                end
            end
        end
        $display("[res] SDRAM words : %0d/%0d wrong", bad_w, SW*SH/2);

        // ---------- 3. 切到正常显示 ----------
        load_mode = 1'b0;
        chk_rd_base = c_rd;
        c_starve = 0;
        frm0 = frm;
        // 等一整帧让 FIFO 预灌稳定，再清饥饿计数，然后抓下一整帧
        while (frm < frm0 + 1) @(posedge pix_clk);
        c_starve = 0;
        while (frm < frm0 + 2) @(posedge pix_clk);
        $display("[tb] captured (frm %0d -> %0d)", frm0, frm);

        // ---------- 4. 逐像素比对 ----------
        for (y = 0; y < FH; y = y + 1) begin
            for (x = 0; x < FW; x = x + 1) begin
                exp_px = pat((3*x) >> 2, (3*y) >> 2);
                if (frame_buf[y*FW + x] !== exp_px) begin
                    if (bad_p < 12)
                        $display("[p] y=%0d x=%0d got=%h exp=%h (src %0d,%0d)",
                                 y, x, frame_buf[y*FW+x], exp_px, (3*x)>>2, (3*y)>>2);
                    bad_p = bad_p + 1;
                end
            end
        end
        $display("[res] display px : %0d/%0d wrong", bad_p, FW*FH);
        $display("[res] read bursts in %0d frames = %0d (expect ~%0d)",
                 frm - frm0, c_rd - chk_rd_base, (frm-frm0)*86400);
        $display("[res] starve=%0d drop=%0d", c_starve, c_drop);

        // ---------- 5. 导出 PPM ----------
        fd = $fopen("fb_full.ppm", "wb");
        $fwrite(fd, "P6\n%0d %0d\n255\n", FW, FH);
        for (y = 0; y < FH; y = y + 1)
            for (x = 0; x < FW; x = x + 1)
                $fwrite(fd, "%c%c%c",
                        {frame_buf[y*FW+x][15:11], 3'b000},
                        {frame_buf[y*FW+x][10:5],  2'b00},
                        {frame_buf[y*FW+x][4:0],   3'b000});
        $fclose(fd);

        // ---------- 6. 正常显示期（双缓冲写窗口）再写两行，验证消隐窗口 ----------
        $display("[tb] window-write test (load_mode=0)...");
        for (y = 100; y < 102; y = y + 1) begin
            for (x = 0; x < SW; x = x + 1) begin
                @(negedge pix_clk);
                while (!wr_ready) @(negedge pix_clk);
                wr_pix_en  = 1'b1;
                wr_pix_x   = x[11:0];
                wr_pix_y   = y[11:0];
                wr_pix_rgb = 16'hA5A5;
                @(negedge pix_clk);
                wr_pix_en = 1'b0;
            end
        end
        wait (u_fb.wr_idle === 1'b1);
        repeat (20) @(posedge mem_clk);
        bad_win = 0;
        for (y = 100; y < 102; y = y + 1)
            for (xw = 0; xw < SW/2; xw = xw + 1)
                if (u_chip.Bank0[y*480 + xw] !== 32'hA5A5A5A5) bad_win = bad_win + 1;
        $display("[res] window write : %0d/1920 wrong", bad_win);

        // ---------- 7. bank B 偏移（第二块缓冲起始 = 259200 字）----------
        wr_bank_t = 1'b1;
        for (y = 0; y < 2; y = y + 1) begin
            for (x = 0; x < SW; x = x + 1) begin
                @(negedge pix_clk);
                while (!wr_ready) @(negedge pix_clk);
                wr_pix_en  = 1'b1;
                wr_pix_x   = x[11:0];
                wr_pix_y   = y[11:0];
                wr_pix_rgb = 16'h5A5A;
                @(negedge pix_clk);
                wr_pix_en = 1'b0;
            end
        end
        wait (u_fb.wr_idle === 1'b1);
        repeat (20) @(posedge mem_clk);
        bad_bank2 = 0;
        for (y = 0; y < 2; y = y + 1)
            for (xw = 0; xw < SW/2; xw = xw + 1)
                if (u_chip.Bank0[259200 + y*480 + xw] !== 32'h5A5A5A5A) bad_bank2 = bad_bank2 + 1;
        $display("[res] bank B offset : %0d/960 wrong", bad_bank2);

        $display("[res] read FIFO peak used = %0d / 2048, rtl rd_drop = %0d",
                 rf_peak, u_fb.rd_drop_cnt);
        if (bad_w == 0 && bad_p == 0 && c_starve == 0 && bad_win == 0 && bad_bank2 == 0)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");
        $finish;
    end

endmodule
