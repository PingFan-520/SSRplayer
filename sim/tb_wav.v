// ⚠️ 2026-10-27 已废弃：wav_player 接口改成 FAT32 文件表 + 簇链，
//    本测试台（DIR_SEC/MDIR 目录扇区）不再适用，编译会失败。
//    现行验证请用 sim/tb_fat_chain.v。
// ============================================================================
//  tb_wav.v —— wav_player（目录扇区 + 裸 PCM）单元测试
//
//  假 SD 严格模仿 sd_read 的输出时序：
//    收到 s_start → 拉 busy → 连续 256 拍 s_val（每拍一个 16bit 字，
//    先到的字节在 [15:8]）→ busy 落下
//
//  卡内容由本 TB 现场构造：
//    扇区 1024        = 目录（"MDIR" + base/扇区数）
//    扇区 2048 起     = WAV 的裸 PCM 数据
//
//  检查项：
//    1) 目录 magic 校验通过（trk_bad=0），并从目录里取到 base/长度
//    2) 采样内容：第 k 个 aud_valid 采样 == 文件第 k 个 16bit 采样
//    3) 扇区地址：从 base 连续递增，走满目录里的长度后回到 base
//    4) 采样率 48000Hz
//    5) 电平与文件峰值一致
//    6) +NODIR：目录扇区是空的 → trk_bad=1 且**一个采样都不输出**（不把图片当音乐播）
// ============================================================================
`timescale 1ns / 1ps

module tb_wav;

    reg clk = 1'b0;
    reg clk_sd = 1'b0;
    reg rst = 1'b1;

    always #13.3 clk = ~clk;         // 37.5MHz
    always #20.0 clk_sd = ~clk_sd;   // 25MHz

    localparam integer DIR_SEC  = 1024;
    localparam integer BASE_SEC = 2048;
    localparam integer MAXP     = 512*1024;      // 只读文件前 512KB（够几十个扇区）

    reg [7:0]  pcm [0:MAXP-1];
    reg [7:0]  dirb[0:511];
    integer    npcm = 0;
    integer    dsec = 0;             // 目录里声明的扇区数

    reg [1023:0] fname;
    integer fd, ch, k, i;
    integer nodir = 0;

    // ---------------- 读 WAV，抽出裸 PCM ----------------
    integer n, doff;

    initial begin
        if (!$value$plusargs("FILE=%s", fname)) begin
            $display("[ERR] 需要 +FILE=<wav>"); $finish;
        end
        if ($test$plusargs("NODIR")) nodir = 1;
        fd = $fopen(fname, "rb");
        if (fd == 0) begin $display("[ERR] 打不开 %0s", fname); $finish; end
        for (k = 0; k < MAXP; k = k + 1) pcm[k] = 8'h00;
        n = 0;
        ch = $fgetc(fd);
        while (ch != -1 && n < MAXP) begin pcm[n] = ch[7:0]; n = n + 1; ch = $fgetc(fd); end
        $fclose(fd);

        // 找 "data" 块起点（不假设 44 字节，ffmpeg 会插 LIST）
        doff = -1;
        for (k = 12; k < 200 && doff < 0; k = k + 1)
            if (pcm[k]==8'h64 && pcm[k+1]==8'h61 && pcm[k+2]==8'h74 && pcm[k+3]==8'h61)
                doff = k + 8;
        if (doff < 0) begin $display("[ERR] 找不到 data 块"); $finish; end
        // 把 PCM 前移到 0（后面比对/回放都按裸 PCM 处理）
        for (k = doff; k < n; k = k + 1) pcm[k-doff] = pcm[k];
        npcm = n - doff;
        dsec = (npcm + 511) / 512;
        // 仿真里没必要跑完 263 秒：目录长度压到 6 个扇区，很快就能看到循环点。
        // 比对范围也随之改成这 6 个扇区（1536 个采样），足以证明数据/循环都对。
        if (dsec > 6) dsec = 6;
        $display("[tb] 读入 %0d 字节，PCM 起点 %0d，PCM %0d 字节（%0d 扇区）",
                 n, doff, npcm, dsec);

        // 造目录扇区
        for (k = 0; k < 512; k = k + 1) dirb[k] = 8'h00;
        if (!nodir) begin
            dirb[0] = "M"; dirb[1] = "D"; dirb[2] = "I"; dirb[3] = "R";
            dirb[4] = 8'd1; dirb[5] = 8'd1;           // count=1, ver=1
            dirb[8]  = BASE_SEC[7:0];  dirb[9]  = BASE_SEC[15:8];
            dirb[10] = BASE_SEC[23:16]; dirb[11] = BASE_SEC[31:24];
            dirb[12] = dsec[7:0];  dirb[13] = dsec[15:8];
            dirb[14] = dsec[23:16]; dirb[15] = dsec[31:24];
        end
    end

    // ---------------- DUT ----------------
    reg  [2:0] track = 3'd1;
    reg  [3:0] vol   = 4'd10;

    wire        a_req, a_busy, a_val;
    wire [31:0] a_sec;
    wire [15:0] a_data;

    wire        s_start, s_busy, s_val;
    wire        trk_bad_w;
    wire [15:0] dbg_hdr_w;
    wire [31:0] s_sec;
    wire [15:0] s_data;

    reg         f_busy = 1'b0, f_val = 1'b0;
    reg         f_hold = 1'b0;
    reg  [15:0] f_data = 16'd0;
    reg  [31:0] f_sec  = 32'd0;
    integer     f_cnt = 0;

    assign s_busy = f_busy;
    assign s_val  = f_val;
    assign s_data = f_data;

    sd_arb u_arb (
        .clk(clk_sd), .rst_n(~rst),
        .a_req(a_req), .a_sec(a_sec),
        .a_busy(a_busy), .a_val(a_val), .a_data(a_data), .a_gnt(),
        .b_req(1'b0), .b_sec(32'd0),
        .b_busy(), .b_val(), .b_data(), .b_gnt(),
        .s_start(s_start), .s_sec(s_sec),
        .s_busy(s_busy), .s_val(s_val), .s_data(s_data),
        .sd_init_done(1'b1)
    );

    wire        aud_valid;
    wire [23:0] aud_l, aud_r;
    wire [7:0]  level;

    wav_player #(
        .DIR_SEC(DIR_SEC), .TRK_NUM(1),
        .CLK_HZ(37_500_000), .SAMPLE_HZ(48_000)
    ) u_wav (
        .clk(clk), .clk_sd(clk_sd), .rst(rst),
        .track(track), .vol(vol),
        .s_req(a_req), .s_sec(a_sec),
        .s_busy(a_busy), .s_val(a_val), .s_data(a_data),
        .aud_valid(aud_valid), .aud_left(aud_l), .aud_right(aud_r),
        .level(level), .trk_bad(trk_bad_w), .dbg_hdr(dbg_hdr_w)
    );

    // ---------------- 假 SD 行为 ----------------
    function [7:0] card_byte;
        input [31:0] sec;
        input integer off;
        integer a;
        begin
            if (sec == DIR_SEC)            card_byte = dirb[off];
            else if (sec >= BASE_SEC) begin
                a = (sec - BASE_SEC) * 512 + off;
                card_byte = (a < MAXP) ? pcm[a] : 8'h00;
            end else                       card_byte = 8'h00;
        end
    endfunction

    always @(posedge clk_sd or posedge rst) begin
        if (rst) begin
            f_busy <= 1'b0; f_val <= 1'b0; f_cnt <= 0; f_sec <= 32'd0;
        end else begin
            f_val <= 1'b0;
            if (s_start) begin
                f_busy <= 1'b1;
                f_cnt  <= 0;
                f_hold <= 1'b1;      // 地址在 s_start 之后一拍才稳定（与真实 sd_read 一致）
            end else if (f_busy) begin
                if (f_hold) begin
                    f_sec  <= s_sec;
                    f_hold <= 1'b0;
                end else if (f_cnt < 256) begin
                    f_data <= {card_byte(f_sec, f_cnt*2), card_byte(f_sec, f_cnt*2+1)};
                    f_val  <= 1'b1;
                    f_cnt  <= f_cnt + 1;
                end else begin
                    f_busy <= 1'b0;
                end
            end
        end
    end

    // ---------------- 采样捕获 ----------------
    localparam integer NCAP = 8192;
    reg [15:0] cap [0:NCAP-1];
    integer    ncap = 0;
    integer    nval = 0;
    integer    lvl_lo = 255, lvl_hi = 0;
    integer    lvl_bad = 0;
    integer    trk_bad_v = 0;

    always @(posedge clk) begin
        if (aud_valid) begin
            nval = nval + 1;
            if (ncap < NCAP) begin
                cap[ncap] = aud_l[23:8];       // aud_left = 采样 << 8
                ncap = ncap + 1;
            end
            if (level < lvl_lo) lvl_lo = level;
            if (level > lvl_hi) lvl_hi = level;
        end
    end

    // ---------------- 扇区序列检查（跳过目录扇区）----------------
    integer sec_expect = BASE_SEC;
    integer sec_bad = 0;
    integer sec_first = -1;
    integer sec_last  = -1;
    integer sec_wrap  = 0;      // 走满一轮回到起点的次数

    reg s_start_d = 1'b0;
    always @(posedge clk_sd) begin
        // 仲裁器在 grant 那一拍才把地址锁进 sec_hold，所以要看"下一拍"的 s_sec
        // （真实 sd_read 是打两拍后锁存，这里取一拍足够）
        s_start_d <= s_start;
        if (s_start_d && (s_sec != DIR_SEC)) begin
            if (sec_first < 0) begin
                sec_first  = s_sec;
                sec_expect = s_sec;
            end
            if (s_sec !== sec_expect) begin
                if (sec_bad < 5)
                    $display("[ERR] 扇区号 %0d，期望 %0d", s_sec, sec_expect);
                sec_bad = sec_bad + 1;
            end
            if ((s_sec == BASE_SEC) && (sec_last >= BASE_SEC + dsec - 2)) sec_wrap = sec_wrap + 1;
            sec_last   = s_sec;
            sec_expect = (s_sec + 1 >= BASE_SEC + dsec) ? BASE_SEC : (s_sec + 1);
        end
    end

    // 诊断
    integer n_wr = 0, max_used = 0, n_rd = 0;
    always @(posedge clk_sd) begin
        if (u_wav.fifo_wr) n_wr = n_wr + 1;
        if (u_wav.fifo_used > max_used) max_used = u_wav.fifo_used;
    end
    always @(posedge clk) if (u_wav.fifo_rd) n_rd = n_rd + 1;

    // ---------------- 主流程 ----------------
    integer bad, total_smp, rate;

    initial begin
        repeat (20) @(negedge clk);
        rst = 1'b0;

        if (nodir) begin
            // 目录无效：必须报警且不出声
            repeat (200000) @(negedge clk);
            if (trk_bad_w !== 1'b1) begin
                $display("[FAIL] 目录无效时 trk_bad 没置位（=%b）", trk_bad_w);
                $finish;
            end
            $display("[ok] 目录 magic 无效 -> trk_bad=1（dbg_hdr=%04h）", dbg_hdr_w);
            // aud_valid 是自由跑节拍，ncap 一定会涨；要看的是"有没有真的搬数据"
            if (n_wr != 0 || lvl_hi != 0) begin
                $display("[FAIL] 目录无效时仍写入 %0d 个字、电平到 %0d（会把垃圾当音乐播）",
                         n_wr, lvl_hi);
                $finish;
            end
            $display("[ok] 目录无效时 FIFO 一个字节都没写（电平恒 0）");
            $display("[PASS] 目录防护用例通过");
            $finish;
        end

        // 正常卡：等 FIFO 灌起来
        wait (ncap >= 5000);
        nval = 0;
        repeat (375000) @(negedge clk);   // 10ms
        rate = nval * 100;
        if ((rate > 47800) && (rate < 48200))
            $display("[ok] 采样率 %0d Hz（10ms 内 %0d 个）", rate, nval);
        else begin
            $display("[FAIL] 采样率 %0d Hz，应约 48000", rate);
            bad = bad + 1;
        end

        $display("[info] FIFO: 写入 %0d 字 / 读出 %0d 字 / 峰值占用 %0d",
                 n_wr, n_rd, max_used, u_wav.st, u_wav.sec_cnt);
        if (trk_bad_w !== 1'b0) begin
            $display("[FAIL] 好卡的 trk_bad 应为 0（dbg_hdr=%04h 目录首字）", dbg_hdr_w);
            trk_bad_v = 1;
        end else
            $display("[ok] 目录 magic 校验通过（base=%0d 长度=%0d 扇区）", BASE_SEC, dsec);

        // 采样逐点比对（裸 PCM：第 k 个采样就是文件第 k 个 16bit）
        total_smp = dsec * 256;
        if (total_smp > ncap) total_smp = ncap;
        if (total_smp > npcm / 2) total_smp = npcm / 2;
        bad = 0;
        for (i = 0; i < total_smp; i = i + 1) begin
            if (cap[i] !== {pcm[i*2+1], pcm[i*2]}) begin
                if (bad < 6)
                    $display("[ERR] 采样 %0d: 得到 %04h 期望 %04h",
                             i, cap[i], {pcm[i*2+1], pcm[i*2]});
                bad = bad + 1;
            end
        end
        $display("[info] 比对 %0d 个采样，错 %0d 个", total_smp, bad);

        if (sec_bad != 0) $display("[FAIL] 扇区序列有 %0d 处不对", sec_bad);
        else if (sec_wrap == 0)
            $display("[FAIL] 没看到循环（走满 %0d 扇区后应回到 %0d）", dsec, BASE_SEC);
        else
            $display("[ok] 扇区从 %0d 连续递增，走满 %0d 扇区后回到起点（循环 %0d 次）",
                     sec_first, dsec, sec_wrap);

        // 电平与文件峰值
        begin : chk_lvl
            integer j, exp_pk, got_pk;
            exp_pk = 0;
            for (j = 0; j < total_smp; j = j + 1) begin
                got_pk = {pcm[j*2+1], pcm[j*2]};
                if (got_pk > 32767) got_pk = 65536 - got_pk;
                if (got_pk > exp_pk) exp_pk = got_pk;
            end
            exp_pk = exp_pk >> 7;
            $display("[info] 峰值: 文件 %0d, 电平输出 %0d..%0d", exp_pk, lvl_lo, lvl_hi);
            if ((lvl_hi <= exp_pk + 1) && (lvl_hi + 1 >= exp_pk))
                $display("[ok] 电平与文件峰值一致");
            else begin
                $display("[FAIL] 电平 %0d 与文件峰值 %0d 不符", lvl_hi, exp_pk);
                lvl_bad = 1;
            end
        end

        if (bad == 0 && sec_bad == 0 && lvl_bad == 0 && trk_bad_v == 0 && sec_wrap > 0)
            $display("[PASS] wav_player 全部用例通过");
        else
            $display("[FAIL] wav_player 有错误");
        $finish;
    end

    initial begin
        #900_000_000;
        $display("[FAIL] timeout, nval=%0d ncap=%0d trk_bad=%b", nval, ncap, trk_bad_w);
        $finish;
    end

endmodule
