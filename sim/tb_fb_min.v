`timescale 1ns / 1ps
// ============================================================================
//  tb_frame_sdram.v —— frame_buffer + 厂商 SDRAM 控制器 + 官方 SDRAM 模型
//
//  与 tb_frame_buffer.v 的区别：把行为级 sdram_app_model 换成真实链路
//      frame_buffer -> sdram.v(加密的 sdr_as_ram) -> IS42s32200 引脚级模型
//
//  流程：
//    1) 等 Sdr_init_done（上电计数 2^17 拍 ≈ 1.05ms@125MHz）
//    2) 往 1280x720 画布中心 640x480 写渐变+棋盘
//    3) 抓一帧导出 fb_sdram.ppm
// ============================================================================
module tb_fb_min;

    localparam integer FW = 1280;
    localparam integer FH = 720;

    // ---------------- 时钟 ----------------
    reg pix_clk = 1'b0;
    always #6.6667 pix_clk = ~pix_clk;      // 75MHz  像素域

    reg mem_clk = 1'b0;
    always #4.0 mem_clk = ~mem_clk;         // 125MHz SDRAM 域

    reg clk_sft = 1'b0;
    always @(mem_clk) clk_sft <= #2 mem_clk;   // 相位滞后 2ns

    reg rst = 1'b1;
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
        .SDRAM_CLK (SDRAM_CLK),
        .SDR_CKE   (SDR_CKE),
        .SDR_RAS   (SDR_RAS),
        .SDR_CAS   (SDR_CAS),
        .SDR_WE    (SDR_WE),
        .SDR_BA    (SDR_BA),
        .SDR_ADDR  (SDR_ADDR),
        .SDR_DM    (SDR_DM),
        .SDR_DQ    (SDR_DQ),
        .Clk       (mem_clk),
        .Clk_sft   (clk_sft),
        .Rst       (rst),
        .Sdr_init_done    (sdr_init_done),
        .Sdr_init_ref_vld (sdr_init_ref_vld),
        .Sdr_busy         (sdr_busy),
        .App_wr_en   (fb_wr_en),
        .App_wr_addr (fb_wr_addr),
        .App_wr_dm   (4'h0),
        .App_wr_din  (fb_wr_din),
        .App_rd_en   (fb_rd_en),
        .App_rd_addr (fb_rd_addr),
        .Sdr_rd_en   (sdr_rd_en),
        .Sdr_rd_dout (fb_rd_dout)
    );

    IS42s32200 u_chip (
        .Clk   (SDRAM_CLK),
        .Cke   (SDR_CKE),
        .Cs_n  (1'b0),
        .Ras_n (SDR_RAS),
        .Cas_n (SDR_CAS),
        .We_n  (SDR_WE),
        .Ba    (SDR_BA),
        .Dqm   (SDR_DM),
        .Addr  (SDR_ADDR),
        .Dq    (SDR_DQ)
    );

    // ---------------- 帧缓存 ----------------
    reg        wr_pix_en  = 1'b0;
    reg [11:0] wr_pix_x   = 12'd0;
    reg [11:0] wr_pix_y   = 12'd0;
    reg [15:0] wr_pix_rgb = 16'd0;

    wire [15:0] fb_rgb;
    wire        fb_de, wr_ready;

    frame_buffer #(
        .FB_W(FW), .FB_H(FH), .VACTIVE(FH), .WR_LINES(25)
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
        .y       (vcnt),          // 帧内行号 0..749，写窗口 = 前 25 行
        .rd_buf  (1'b0),
        .rgb_out (fb_rgb),
        .de_out  (fb_de)
    );

    // ---------------- 调试计数 ----------------
    integer c_rd_en = 0, c_rd_vld = 0, c_rf_rd = 0, c_wr = 0;
    integer c_win = 0, c_cyc = 0, c_fwr = 0, c_nz = 0;
    integer c_act = 0, c_wcmd = 0, c_rcmd = 0, c_pre = 0, c_ref = 0;
    always @(posedge mem_clk) begin
        if (fb_rd_en) c_rd_en = c_rd_en + 1;
        if (sdr_rd_en) c_rd_vld = c_rd_vld + 1;
        if (fb_wr_en)  c_wr = c_wr + 1;
        if (u_fb.rf_wr) c_fwr = c_fwr + 1;
        c_cyc = c_cyc + 1;
        if (u_fb.wr_win_m) c_win = c_win + 1;
        // SDRAM 引脚命令译码：RAS/CAS/WE 低有效
        if (!SDR_RAS && SDR_CAS && SDR_WE)  c_act  = c_act + 1;   // ACTIVE
        if (SDR_RAS && !SDR_CAS && SDR_WE)  c_rcmd = c_rcmd + 1;  // READ
        if (SDR_RAS && !SDR_CAS && !SDR_WE) c_wcmd = c_wcmd + 1;  // WRITE
        if (!SDR_RAS && SDR_CAS && !SDR_WE) c_pre  = c_pre + 1;   // PRECHARGE
        if (!SDR_RAS && !SDR_CAS && SDR_WE) c_ref  = c_ref + 1;   // AUTO REFRESH
    end
    always @(posedge pix_clk) begin
        if (u_fb.rf_rd) c_rf_rd = c_rf_rd + 1;
        if (fb_de && (fb_rgb != 16'd0)) c_nz = c_nz + 1;
    end

    // 每帧结束打印一次状态
    reg vs_d = 1'b0;
    always @(posedge pix_clk) begin
        vs_d <= vs;
        if (vs_d && !vs)
            $display("[st] t=%0t win=%b occ=%0d rdcnt=%0d empty=%b rd_en=%0d rd_vld=%0d rf_rd=%0d wr=%0d",
                     $time, u_fb.wr_win_m, u_fb.occ, u_fb.rd_cnt, u_fb.rf_empty,
                     c_rd_en, c_rd_vld, c_rf_rd, c_wr);
        if (vs_d && !vs)
            $display("[st2] win_ratio=%0d%% fifo_wr=%0d nz_px=%0d cyc=%0d",
                     (c_win*100)/c_cyc, c_fwr, c_nz, c_cyc);
    end

    // ---------------- bn 变化追踪 ----------------
    reg [2:0] bn_d = 3'd0;
    always @(posedge mem_clk) begin
        if (u_fb.bn !== bn_d) begin
            $display("[bn] t=%0t bn=%0d baddr=%0d waddr=%0d empty=%b win=%b bsend=%b full=%b",
                     $time, u_fb.bn, u_fb.baddr, u_fb.word_addr,
                     u_fb.wf_empty, u_fb.wr_win_m, u_fb.bsend, u_fb.bfull);
            bn_d = u_fb.bn;
        end
    end

    // ---------------- 打包状态监控 ----------------
    integer mn = 0;
    always @(posedge mem_clk) begin
        mn = mn + 1;
        if (mn > 1000 && (mn % 5000) == 0)
            $display("[pk] bn=%0d bfull=%b win=%b empty=%b wvld=%b bsend=%b baddr=%0d waddr=%0d",
                     u_fb.bn, u_fb.bfull, u_fb.wr_win_m, u_fb.wf_empty,
                     u_fb.wvld, u_fb.bsend, u_fb.baddr, u_fb.word_addr);
    end

    // ---------------- 抓帧 ----------------
    reg [15:0] frame_buf [0:FW*FH-1];
    integer wp = 0;
    always @(posedge pix_clk) begin
        if ((act_x == 12'd0) && (act_y == 12'd0))
            wp <= 0;
        if (fb_de && (act_x < FW) && (act_y < FH)) begin
            frame_buf[act_y * FW + act_x] <= fb_rgb;
            wp <= wp + 1;
        end
    end

    integer fh, wxx, wyy, i, j, k, found = 0, cnt_w;
    reg [7:0] r8, g8, b8;
    reg [15:0] exp_rgb;

    task dump_ppm;
        input [1023:0] fname;
        integer fd;
        begin
            fd = $fopen(fname, "wb");
            $fwrite(fd, "P6\n%0d %0d\n255\n", FW, FH);
            for (i = 0; i < FH; i = i + 1) begin
                for (j = 0; j < FW; j = j + 1) begin
                    r8 = {frame_buf[i*FW+j][15:11], 3'b000};
                    g8 = {frame_buf[i*FW+j][10:5],  2'b00};
                    b8 = {frame_buf[i*FW+j][4:0],   3'b000};
                    $fwrite(fd, "%c%c%c", r8, g8, b8);
                end
            end
            $fclose(fd);
            $display("[tb] %0s dumped", fname);
        end
    endtask

    // ---------------- 主流程 ----------------
    initial begin
        $display("[tb] waiting SDRAM init...");
        // 上电计数 2^17 拍 @125MHz ≈ 1.05ms
        wait (sdr_init_done === 1'b1);
        $display("[tb] SDRAM init_done at %0t ns", $time);

        repeat (200) @(posedge pix_clk);

        // 写 640x480 图案到 (320,120)
        $display("[tb] writing 16 px...");
        for (wyy = 0; wyy < 1; wyy = wyy + 1) begin
            for (wxx = 0; wxx < 16; wxx = wxx + 1) begin
                @(negedge pix_clk);
                while (!wr_ready) @(negedge pix_clk);
                wr_pix_en  = 1'b1;
                wr_pix_x   = 320 + wxx;
                wr_pix_y   = 120 + wyy;
                // 渐变 + 32px 棋盘
                wr_pix_rgb = {wxx[7:3], wyy[7:2],
                              (1'b0 | (((wxx >> 5) + (wyy >> 5)) & 1))};
                if ((((wxx >> 5) + (wyy >> 5)) & 1))
                    wr_pix_rgb = {wxx[7:3], wyy[7:2], 5'b11111};
                else
                    wr_pix_rgb = {wxx[7:3], wyy[7:2], 5'b00000};
            end
        end
        @(negedge pix_clk);
        wr_pix_en = 1'b0;
        $display("[tb] pattern written at %0t ns", $time);

        // 等两个写窗口，让攒好的 burst 真正写进 SDRAM
        @(posedge vs);
        @(posedge vs);
        repeat (200) @(posedge mem_clk);
        $display("[chk] Bank0[19240]=%h [19241]=%h",
                 u_chip.Bank0[19240], u_chip.Bank0[19241]);
        cnt_w = 0;
        for (k = 0; k < 200000; k = k + 1)
            if (u_chip.Bank0[k] !== 32'hxxxxxxxx) begin
                if (cnt_w < 8)
                    $display("[at] Bank0[%0d] = %h", k, u_chip.Bank0[k]);
                cnt_w = cnt_w + 1;
            end
        $display("[chk] Bank0 前 200000 字中已写 %0d 个", cnt_w);
        $display("[chk] 引脚: ACT=%0d WR=%0d RD=%0d PRE=%0d REF=%0d | App写=%0d",
                 c_act, c_wcmd, c_rcmd, c_pre, c_ref, c_wr);

        // 等两帧让读侧稳定
        @(posedge vs);
        @(posedge vs);

        wait ((act_x == 12'd0) && (act_y == 12'd0));
        @(posedge pix_clk);
        #200;
        dump_ppm("fb_sdram.ppm");
        $display("[tb] FRAME_SDRAM_DONE");
        $finish;
    end

    initial begin
        #1500000000;     // 1.5s 兜底
        $display("[tb] GLOBAL TIMEOUT");
        $finish;
    end

endmodule
