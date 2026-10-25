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
module tb_frame_win;

    localparam integer FW = 1280;
    localparam integer FH = 720;

    // ---------------- 时钟 ----------------
    reg pix_clk = 1'b0;
    always #13.3333 pix_clk = ~pix_clk;     // 37.5MHz 像素域（720p30）

    reg mem_clk = 1'b0;
    always #4.0 mem_clk = ~mem_clk;         // 125MHz SDRAM 域

    reg clk_sft = 1'b0;
    always @(mem_clk) clk_sft <= #2 mem_clk;   // 相位滞后 2ns

    reg rst = 1'b1;
    reg load_mode = 1'b0;
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
    reg        rd_bank_t     = 1'b0;
    reg        rd_bank_new_t = 1'b0;
    reg [19:0] rd_wipe_t     = 20'd153600;
    reg [15:0] wr_pix_rgb = 16'd0;

    wire [15:0] fb_rgb;
    wire        fb_de, wr_ready;

    frame_buffer #(
        .FB_W(FW), .FB_H(FH), .VACTIVE(FH), .WR_LINES(25), .V_OFFSET(25),
        .IMG_W(640), .IMG_H(480), .IMG_X0(320), .IMG_Y0(120)
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
        .load_mode(load_mode),
        .rd_bank (rd_bank_t),
        .rd_bank_new(rd_bank_new_t),
        .rd_wipe (rd_wipe_t),
        .wr_bank (1'b0),
        .wr_fifo_used(),
        .rgb_out (fb_rgb),
        .de_out  (fb_de)
    );

    // ---------------- 调试计数 ----------------
    integer c_rd_en = 0, c_rd_vld = 0, c_rf_rd = 0, c_wr = 0;
    integer c_win = 0, c_cyc = 0, c_fwr = 0, c_nz = 0, c_busy = 0, c_refv = 0;
    integer c_act = 0, c_wcmd = 0, c_rcmd = 0, c_pre = 0, c_ref = 0;
    always @(posedge mem_clk) begin
        if (fb_rd_en) c_rd_en = c_rd_en + 1;
        if (sdr_rd_en) c_rd_vld = c_rd_vld + 1;
        if (fb_wr_en)  c_wr = c_wr + 1;
        if (u_fb.rf_wr) c_fwr = c_fwr + 1;
        c_cyc = c_cyc + 1;
        if (u_fb.wr_win_m) c_win = c_win + 1;
        if (sdr_busy) c_busy = c_busy + 1;
        if (sdr_init_ref_vld) c_refv = c_refv + 1;
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

    // ---------------- burst 基地址追踪 ----------------
    integer bs_n = 0;
    reg bsend_d = 1'b0;
    always @(posedge mem_clk) begin
        bsend_d <= fb_wr_en;
        if (fb_wr_en && !bsend_d) begin
            if (bs_n < 8)
                $display("[bs] #%0d t=%0t baddr=%0d word0=%h y=%0d xw=%0d",
                         bs_n, $time, u_fb.baddr, u_fb.bb0, u_fb.wd_y, u_fb.wd_xw);
            bs_n = bs_n + 1;
        end
    end

    // ---------------- wd_take 追踪（前 16 次） ----------------
    integer tk_n = 0;
    reg tk_d = 1'b0;
    always @(posedge mem_clk) begin
        tk_d <= u_fb.wd_take;
        if (u_fb.wd_take && tk_n < 16) begin
            $display("[tk] #%0d bn=%0d y=%0d xw=%0d baddr=%0d",
                     tk_n, u_fb.bn, u_fb.wd_y, u_fb.wd_xw, u_fb.baddr);
            tk_n = tk_n + 1;
        end
    end

    // ---------------- 读指针与显示消费 ----------------
    integer rd_d = -1;
    integer bw_n = 0, bw_busy = 0, bw_rd = 0;
    reg [19:0] rdc_last = 20'd0;
    always @(posedge pix_clk) begin
        if (vcnt >= 12'd30 && vcnt < 12'd745) begin
            bw_n = bw_n + 1;
            if (sdr_busy)    bw_busy = bw_busy + 1;
            if (fb_rd_en)    bw_rd   = bw_rd + 1;
        end
        if ((vcnt == 12'd745) && (hcnt == 12'd0) && bw_n > 0) begin
            $display("[fr] rd_cnt=%0d occ=%0d busy=%0d%% rd_en=%0d%% cyc=%0d",
                     u_fb.rd_cnt, u_fb.occ,
                     (bw_busy*100)/bw_n, (bw_rd*100)/bw_n, bw_n);
            bw_n = 0; bw_busy = 0; bw_rd = 0;
        end
    end

    // ---------------- vcnt 分布统计 ----------------
    integer v_cyc = 0, v_lt25 = 0, vmax = 0, vmin = 4095;
    always @(posedge pix_clk) begin
        v_cyc = v_cyc + 1;
        if (vcnt < 12'd25) v_lt25 = v_lt25 + 1;
        if (vcnt > vmax) vmax = vcnt;
        if (vcnt < vmin) vmin = vcnt;
    end

    // ---------------- 读地址序列 ----------------
    integer adr_n = 0;
    always @(posedge mem_clk)
        if (u_fb.app_rd_en && adr_n < 40) begin
            $display("[adr] addr=%0d cnt=%0d rb=%b gap=%0d", u_fb.app_rd_addr, u_fb.rd_cnt, u_fb.rburst, u_fb.rgap);
            adr_n = adr_n + 1;
        end

    // ---------------- rstart 触发时刻 ----------------
    integer rt_n = 0;
    always @(posedge mem_clk)
        if (u_fb.rstart && rt_n < 24) begin
            $display("[rt] t=%0t win=%b busy=%b init=%b fcnt=%0d rgap=%0d rb=%b",
                     $time, u_fb.wr_win_m, u_fb.app_busy, u_fb.app_init_done,
                     u_fb.fcnt, u_fb.rgap, u_fb.rburst);
            rt_n = rt_n + 1;
        end

    // ---------------- rstart 各条件占空比 ----------------
    integer a1=0,a2=0,a3=0,a4=0,a5=0,a6=0,a7=0,a8=0,a9=0,ac=0;
    integer b1=0,b2=0;
    integer xf=0,xg=0,xb=0,xr=0,xrr=0,xwin=0;
    integer c_bib = 0, c_burst = 0;
    always @(posedge mem_clk) begin
        ac = ac + 1;
        if (!u_fb.wr_win_m)       a1 = a1 + 1;
        if (u_fb.app_init_done)   a2 = a2 + 1;
        if (!u_fb.app_ref_vld)    a3 = a3 + 1;
        if (!u_fb.app_busy)       a4 = a4 + 1;
        if (u_fb.fcnt < 11'd512)  a5 = a5 + 1;
        if (!u_fb.rf_full)        a6 = a6 + 1;
        if (!u_fb.rburst)         a7 = a7 + 1;
        if (u_fb.rgap == 4'd0)    a8 = a8 + 1;
        if (u_fb.rstart)          a9 = a9 + 1;
        if (!u_fb.wr_win_m) b2 = b2 + 1;
        if (!u_fb.wr_win_m && !u_fb.app_busy) b1 = b1 + 1;
        if ((^u_fb.fcnt)   === 1'bx) xf  = xf + 1;
        if ((^u_fb.rgap)   === 1'bx) xg  = xg + 1;
        if ((^u_fb.rburst) === 1'bx) xb  = xb + 1;
        if (u_fb.rstart     === 1'bx) xr  = xr + 1;
        if (u_fb.rf_rd      === 1'bx) xrr = xrr + 1;
        if (u_fb.wr_win_m   === 1'bx) xwin= xwin + 1;
        if (u_fb.rburst) begin
            c_burst = c_burst + 1;
            if (u_fb.app_busy) c_bib = c_bib + 1;
        end
    end

    // ---------------- 读侧带宽统计 ----------------
    integer q_rden = 0, q_busy = 0, q_vld = 0, q_cyc = 0, q_fmax = 0, q_full = 0, q_win = 0, q_ref = 0;
    integer d_cyc = 0, d_win = 0, d_rden = 0, d_busy = 0;
    always @(posedge mem_clk) begin
        q_cyc = q_cyc + 1;
        if (u_fb.app_rd_en) q_rden = q_rden + 1;
        if (u_fb.app_rd_valid) q_vld = q_vld + 1;
        if (u_fb.app_busy) q_busy = q_busy + 1;
        if (u_fb.rf_full) q_full = q_full + 1;
        if (u_fb.wr_win_m) q_win = q_win + 1;
        if (u_fb.app_ref_vld) q_ref = q_ref + 1;
        if (!load_mode) begin
            d_cyc = d_cyc + 1;
            if (u_fb.wr_win_m) d_win = d_win + 1;
            if (u_fb.app_rd_en) d_rden = d_rden + 1;
            if (u_fb.app_busy) d_busy = d_busy + 1;
        end
        if (u_fb.fcnt > q_fmax) q_fmax = u_fb.fcnt;
    end

    // ---------------- FIFO 饥饿统计（显示要数据但 FIFO 空） ----------------
    integer c_starve = 0;
    integer frm = 0;
    always @(posedge pix_clk) if (vs) frm <= frm + 1;
    always @(posedge pix_clk)
        if (frm >= 2 && u_fb.in_img && u_fb.xr[0] && u_fb.rf_empty) c_starve = c_starve + 1;

    // ---------------- 读序列比对：FIFO 弹出顺序 vs SDRAM 内容 ----------------
    integer seq_i = 0, seq_bad = 0, seq_n = 0;
    reg     seq_rd_d = 1'b0;
    always @(posedge pix_clk) begin
        seq_rd_d <= u_fb.rf_rd;
        if (u_fb.pix_rst || vs) begin
            seq_i <= 0; seq_bad <= 0; seq_n <= 0;
        end else if (seq_rd_d && frm >= 2) begin
            if (u_fb.rf_dout !== u_chip.Bank0[seq_i]) begin
                if (seq_bad < 8)
                    $display("[seq] i=%0d got=%h exp=%h", seq_i, u_fb.rf_dout, u_chip.Bank0[seq_i]);
                seq_bad <= seq_bad + 1;
            end
            seq_i <= seq_i + 1;
            seq_n <= seq_n + 1;
        end
    end

    // ---------------- 丢字统计 ----------------
    integer c_drop = 0, c_rfwr = 0, c_rfrd = 0, c_rdm = 0, c_low = 0;
    always @(posedge mem_clk) begin
        if (u_fb.rf_used < 12'd64) c_low = c_low + 1;
        if (u_fb.rf_used > c_rdm) c_rdm = u_fb.rf_used;   // 峰值占用
    end
    always @(posedge mem_clk) begin
        if (u_fb.rf_wr) c_rfwr = c_rfwr + 1;
        if (u_fb.app_rd_valid && u_fb.rf_full) c_drop = c_drop + 1;
    end
    always @(posedge pix_clk) if (u_fb.rf_rd) c_rfrd = c_rfrd + 1;

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
    integer ry, cx, idx, wbad;

    // 转场分界地址检查
    reg        wk_en = 1'b0;
    integer    wk_bad = 0, wk_chk = 0, wk_lo = 0, wk_hi = 0;
    reg [20:0] wk_exp = 21'd0;
    always @(posedge mem_clk) begin
        if (wk_en && u_fb.rd_go) begin
            wk_exp = (u_fb.rd_cnt << 2) + ((u_fb.rd_cnt >= rd_wipe_t) ? 21'd614400 : 21'd0);
            if (u_fb.app_rd_addr !== wk_exp) wk_bad = wk_bad + 1;
            wk_chk = wk_chk + 1;
            if (u_fb.rd_cnt < rd_wipe_t) wk_lo = wk_lo + 1; else wk_hi = wk_hi + 1;
        end
    end

    // 写路径计数器：看 153600 字在哪一步丢的
    integer c_tk3 = 0, c_wd3 = 0, c_tl3 = 0, c_bs3 = 0, c_pp3 = 0;
    reg     bsd3 = 1'b0;
    always @(posedge mem_clk) begin
        if (u_fb.wd_take) c_tk3 = c_tk3 + 1;
        if (u_fb.wd_drop) c_wd3 = c_wd3 + 1;
        if (u_fb.tail_drop) c_tl3 = c_tl3 + 1;
        if (u_fb.wpop) c_pp3 = c_pp3 + 1;
        bsd3 <= u_fb.bsend;
        if (u_fb.bsend && !bsd3) c_bs3 = c_bs3 + 1;
    end
    reg [15:0] p0, p1;
    reg [4:0] r5v, b5v;
    reg [5:0] g6v;
    reg [31:0] expw;
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
        load_mode = 1'b0;          // 双缓冲路径：只写消隐期，读不停
        $display("[tb] writing 640x480 pattern...");
        for (wyy = 0; wyy < 480; wyy = wyy + 1) begin
            for (wxx = 0; wxx < 640; wxx = wxx + 1) begin
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
                @(negedge pix_clk);        // 单拍脉冲：每像素只写一次
                wr_pix_en = 1'b0;
            end
        end
        @(negedge pix_clk);
        wr_pix_en = 1'b0;
        $display("[tb] pattern written at %0t ns", $time);
        // 等 FIFO 排空、burst 发完，再切回显示
        wait (u_fb.wf_empty);
        repeat (3000) @(posedge mem_clk);   // 等最后一个 burst 发完
        load_mode = 1'b0;
        $display("[tb] load done at %0t ns", $time);

        // !!! 关键：必须等显示真正走完几帧再抓帧。
        // 之前这里直接抓，抓到的还是"读没开始"的状态，
        // 图像比对结果（57216 个错）其实是假象。
        repeat (3) @(posedge vs);
        $display("[tb] display settled at %0t ns", $time);

        repeat (20) @(posedge mem_clk);
        $display("[drop] rf_wr=%0d rf_rd=%0d drop_on_full=%0d used_max=%0d dry=%0d", c_rfwr, c_rfrd, c_drop, c_rdm, c_low);
        $display("[seq] popped=%0d bad=%0d starve=%0d", seq_n, seq_bad, c_starve);
        $display("[bw] rd_en=%0d rd_vld=%0d busy=%0d cyc=%0d fcnt_max=%0d", q_rden, q_vld, q_busy, q_cyc, q_fmax);
        $display("[bw2] rf_full=%0d win=%0d refvld=%0d", q_full, q_win, q_ref);
        $display("[cnd] cyc=%0d nwin=%0d nbusy=%0d rstart=%0d", ac, a1, a4, a9);
        $display("[cnd2] nwin=%0d  nwin_and_nbusy=%0d", b2, b1);
        $display("[x] fcnt=%0d rgap=%0d rburst=%0d rstart=%0d rf_rd=%0d win=%0d",
                 xf, xg, xb, xr, xrr, xwin);
        $display("[bib] burst_cycles=%0d busy_in_burst=%0d", c_burst, c_bib);
        $display("[disp] cyc=%0d win=%0d rd_en=%0d busy=%0d", d_cyc, d_win, d_rden, d_busy);
        $display("[vcnt] cyc=%0d lt25=%0d min=%0d max=%0d", v_cyc, v_lt25, vmin, vmax);

        repeat (50) @(posedge mem_clk);
        // 图片行 0 的前 16 个字：期望 0x0000 x4, 0x0800 x4, 0x1000 x4, 0x1800 x4
        $display("[w0] %h %h %h %h %h %h %h %h",
                 u_chip.Bank0[0], u_chip.Bank0[1], u_chip.Bank0[2], u_chip.Bank0[3],
                 u_chip.Bank0[4], u_chip.Bank0[5], u_chip.Bank0[6], u_chip.Bank0[7]);
        $display("[w1] %h %h %h %h %h %h %h %h",
                 u_chip.Bank0[8], u_chip.Bank0[9], u_chip.Bank0[10], u_chip.Bank0[11],
                 u_chip.Bank0[12], u_chip.Bank0[13], u_chip.Bank0[14], u_chip.Bank0[15]);
        cnt_w = 0;
        for (k = 0; k < 200000; k = k + 1)
            if (u_chip.Bank0[k] !== 32'hxxxxxxxx) cnt_w = cnt_w + 1;
        $display("[chk] Bank0 前 200000 字中已写 %0d 个", cnt_w);

        // ---- 逐字比对 SDRAM 内容与期望图案（153600 字）----
        wbad = 0;
        for (ry = 0; ry < 480; ry = ry + 1) begin
            for (cx = 0; cx < 320; cx = cx + 1) begin
                idx = ry*320 + cx;
                g6v = (ry & 255) >> 2;
                r5v = ((cx*2) & 255) >> 3;
                b5v = ((((cx*2) >> 5) + (ry >> 5)) & 1) ? 5'd31 : 5'd0;
                p0  = {r5v, g6v, b5v};
                r5v = ((cx*2+1) & 255) >> 3;
                b5v = ((((cx*2+1) >> 5) + (ry >> 5)) & 1) ? 5'd31 : 5'd0;
                p1  = {r5v, g6v, b5v};
                expw = {p1, p0};
                if (u_chip.Bank0[idx] !== expw) begin
                    if (wbad < 10)
                        $display("[wbad] idx=%0d row=%0d col=%0d got=%h exp=%h",
                                 idx, ry, cx, u_chip.Bank0[idx], expw);
                    wbad = wbad + 1;
                end
            end
        end
        $display("[res] SDRAM content match : %0d/%0d wrong", wbad, 153600);
        $display("[wr] take=%0d pop=%0d drop=%0d tail=%0d burst=%0d (期望 take=153600 burst=38400)",
                 c_tk3, c_pp3, c_wd3, c_tl3, c_bs3);
        // 逐行坏字数
        for (ry = 0; ry < 480; ry = ry + 1) begin
            wbad = 0;
            for (cx = 0; cx < 320; cx = cx + 1) begin
                idx = ry*320 + cx;
                if (u_chip.Bank0[idx] === 32'hxxxxxxxx) wbad = wbad + 1;
            end
            if (wbad != 0) $display("[badrow] %0d : 未写入 %0d/320", ry, wbad);
        end

        // 逐行统计：y=120..135 每行有多少字落盘（每行 320 字，索引 y*640+160..+479）
        for (k = 0; k < 16; k = k + 1) begin
            cnt_w = 0;
            for (i = 0; i < 320; i = i + 1)
                if (u_chip.Bank0[(k)*320 + i] !== 32'hxxxxxxxx) cnt_w = cnt_w + 1;
            $display("[row] img row %0d : %0d/320", k, cnt_w);
        end
        $display("[chk] 引脚: ACT=%0d WR=%0d RD=%0d PRE=%0d | App写=%0d", c_act, c_wcmd, c_rcmd, c_pre, c_wr);
        $display("[chk] busy=%0d%% refvld=%0d%% 周期=%0d", (c_busy*100)/c_cyc, (c_refv*100)/c_cyc, c_cyc);

        // 等 6 帧让读侧稳定（FIFO 预取需要时间）
        for (k = 0; k < 6; k = k + 1) @(posedge vs);

        // ---- 转场分界（整幅推入）地址检查 ----
        //   rd_wipe_t = 76800 时：字 < 76800 读 bank0，>= 76800 读 bank1。
        //   检查每个读拍 app_rd_addr 是否 = rd_cnt*4 + (跨过分界 ? 614400 : 0)。
        rd_bank_t     = 1'b0;
        rd_bank_new_t = 1'b1;
        rd_wipe_t     = 20'd76800;
        repeat (3) @(posedge vs);
        wk_en = 1'b1;
        @(posedge vs);
        wk_en = 1'b0;
        $display("[wipe] 检查 %0d 拍：上半 %0d 拍、下半 %0d 拍，地址错 %0d",
                 wk_chk, wk_lo, wk_hi, wk_bad);
        if (wk_bad == 0 && wk_lo > 1000 && wk_hi > 1000)
            $display("[wipe] PASS：分界两侧 bank 切换正确");
        else
            $display("[wipe] FAIL：分界地址不对");
        rd_bank_new_t = 1'b0;
        rd_wipe_t     = 20'd153600;
        repeat (3) @(posedge vs);

        wait ((act_x == 12'd0) && (act_y == 12'd0));
        @(posedge pix_clk);
        #200;
        dump_ppm("fb_sdram.ppm");
        $display("[tb] FRAME_SDRAM_DONE");
        $finish;
    end

    initial begin
        #600000000;      // 600ms 兜底
        $display("[tb] GLOBAL TIMEOUT");
        $finish;
    end

endmodule
