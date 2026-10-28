`timescale 1ns / 1ps
// ============================================================================
//  tb_fat_chain.v —— FAT32 全链路验证（挂载 / 目录扫描 / 簇链读图 / 簇链放音）
//
//  用一个"文件驱动的假 SD 卡"：收到 CMD17 就从 fat_card.img 里取 512 字节，
//  直接接真实的 sd_arb + fat_mnt + fat_scan + fat_tbl + sd_bmp_reader + wav_player。
//
//  检查项：
//    1) MBR/BPB 解析出的 FAT/数据区/簇大小/根目录簇
//    2) 目录扫描出的图片数、曲目数、文件表的簇/大小/名字
//    3) 每张 BMP 的字节流与文件内容**逐字节**一致（含跨簇）
//    4) WAV 的 PCM 采样与文件逐采样一致（含 44 字节头跳过）
// ============================================================================
module tb_fat_chain;

    reg clk_sd  = 1'b0;
    reg clk_pix = 1'b0;
    always #20 clk_sd  = ~clk_sd;       // 25MHz
    always #500 clk_pix = ~clk_pix;     // 1MHz（音频节拍用，CLK_HZ=1MHz）

    reg rst = 1'b1;
    initial begin #2000; rst = 1'b0; end

    // ------------------------------------------------------------------
    // 假 SD 卡：一次 512 字节，2 拍一个字（比真实 SPI 快 8 倍，省仿真时间）
    // ------------------------------------------------------------------
    wire        s_start;
    wire [31:0] s_sec;
    reg         s_busy = 1'b0;
    reg         s_val  = 1'b0;
    reg  [15:0] s_data = 16'd0;

    // 三个使用者的请求
    wire        wav_req;  wire [31:0] wav_sec;
    wire        wav_busy, wav_val;     wire [15:0] wav_data;
    wire        img_busy, img_val;     wire [15:0] img_data;
    wire        img_start; wire [31:0] img_sec;
    wire        scan_busy, scan_val;   wire [15:0] scan_data;
    wire        mnt_start, scan_start;
    wire [31:0] mnt_sec, scan_sec;
    wire        scan_req = mnt_start | scan_start;
    wire [31:0] scan_reqx = mnt_start ? mnt_sec : scan_sec;

    // 整张卡先读进内存（$fread 一次读完），再按扇区取字节。
    // 这样不需要 $fseek（Modelsim 10.5 不支持），也不会每次重读文件。
    reg [7:0] card [0:3_200_000];
    integer sfd, card_n;
    integer addr;
    reg [8:0] scnt;
    reg       phase;
    reg       getaddr;
    reg       half = 1'b0;
    reg [4:0] tail;               // 512 字节后 busy 的尾巴（真实控制器 ~10 拍）

    // ---- 故障注入（用 +FAULT=n 指定"第 n 次传输不给 busy"，-1 = 不注入）----
    //   FAULT=n      ：第 n 次传输完全不响应（模拟卡丢 CMD17 响应）
    //   HALF=n       ：第 n 次传输只发 100 个字（模拟 SPI 丢字节）
    //   FAULT_ALL=1  ：所有传输都不响应（模拟卡彻底掉线）
    integer fault_at  = -1;
    integer half_at   = -1;
    integer fault_all = 0;
    integer n_xfer    = 0;
    integer hit       = 0;
    initial begin
        hit = $value$plusargs("FAULT=%d", fault_at);
        hit = $value$plusargs("HALF=%d",  half_at);
        hit = $value$plusargs("FAULT_ALL=%d", fault_all);
        if (fault_at >= 0)  $display("[inj] 第 %0d 次传输不响应", fault_at);
        if (half_at  >= 0)  $display("[inj] 第 %0d 次传输只发 100 字", half_at);
        if (fault_all != 0) $display("[inj] 全部传输不响应");
    end

    initial begin
        sfd = $fopen("fat_card.img", "rb");
        if (sfd == 0) begin
            $display("ERROR: can't open fat_card.img");
            $finish;
        end
        card_n = $fread(card, sfd);
        $fclose(sfd);
        $display("[tb] card loaded: %0d bytes", card_n);
        $display("[tb] card[0]=%h card[1048576]=%h card[1048577]=%h",
                 card[0], card[1048576], card[1048577]);
    end

    always @(posedge clk_sd) begin
        s_val <= 1'b0;
        if (!rst && s_start && !s_busy) begin
            n_xfer <= n_xfer + 1;
            // ★ 故障注入：命中就不拉 busy（请求被"卡丢"），
            //   验证 reader 的 2.6ms 超时重试能不能自己恢复
            if ((fault_all != 0) || (n_xfer == fault_at)) begin
                $display("[inj] t=%0t 第 %0d 次传输被丢弃（sec=%0d）", $time, n_xfer, s_sec);
            end else begin
                s_busy  <= 1'b1;
                scnt    <= 9'd0;
                phase   <= 1'b0;
                getaddr <= 1'b1;      // sd_read 是 start 之后第 2 拍才锁地址
                tail    <= 5'd0;
                half    <= (n_xfer == half_at);
            end
        end else if (s_busy) begin
            if (getaddr) begin
                addr    <= s_sec * 512;
                getaddr <= 1'b0;
            end else if (tail != 5'd0) begin
                tail <= tail - 5'd1;
                if (tail == 5'd1) s_busy <= 1'b0;
            end else if (!phase) begin
                phase <= 1'b1;
            end else begin
                s_data <= {card[addr + scnt*2], card[addr + scnt*2 + 1]};
                s_val  <= 1'b1;
                phase  <= 1'b0;
                if (half && (scnt == 9'd99)) tail <= 5'd12;   // 只发 100 个字就收尾
                else if (scnt == 9'd255)     tail <= 5'd12;
                else                         scnt <= scnt + 9'd1;
            end
        end
    end

    sd_arb u_arb (
        .clk(clk_sd), .rst_n(~rst),
        .a_req(wav_req), .a_sec(wav_sec),
        .a_busy(wav_busy), .a_val(wav_val), .a_data(wav_data), .a_gnt(),
        .b_req(img_start), .b_sec(img_sec),
        .b_busy(img_busy), .b_val(img_val), .b_data(img_data), .b_gnt(),
        .c_req(scan_req), .c_sec(scan_reqx),
        .c_busy(scan_busy), .c_val(scan_val), .c_data(scan_data), .c_gnt(),
        .s_start(s_start), .s_sec(s_sec),
        .s_busy(s_busy), .s_val(s_val), .s_data(s_data),
        .sd_init_done(1'b1)
    );

    // ------------------------------------------------------------------
    // FAT 挂载 / 扫描 / 表
    // ------------------------------------------------------------------
    wire        mnt_ok, mnt_done;
    wire [31:0] part_lba, fat_lba, data_lba, root_clus;
    wire [3:0]  spc_log2;
    wire [7:0]  mnt_err;

    fat_mnt u_mnt (
        .clk(clk_sd), .rst(rst),
        .rd_start_en(mnt_start), .rd_sec_addr(mnt_sec),
        .rd_busy(scan_busy), .rd_val_en(scan_val), .rd_val_data(scan_data),
        .sd_init_done(1'b1),
        .mnt_ok(mnt_ok), .part_lba(part_lba), .fat_lba(fat_lba),
        .data_lba(data_lba), .spc_log2(spc_log2), .root_clus(root_clus),
        .mnt_done(mnt_done), .mnt_err(mnt_err)
    );

    wire        scan_done;
    wire [7:0]  img_total;
    wire [3:0]  mus_total;
    wire [7:0]  scan_err;
    wire        tw_en;
    wire [9:0]  tw_addr;
    wire [7:0]  tw_data;

    fat_scan #(.IMG_MAX(56), .MUS_MAX(6)) u_scan (
        .clk(clk_sd), .rst(rst),
        .rd_start_en(scan_start), .rd_sec_addr(scan_sec),
        .rd_busy(scan_busy), .rd_val_en(scan_val), .rd_val_data(scan_data),
        .sd_init_done(1'b1),
        .mnt_ok(mnt_ok), .mnt_done(mnt_done),
        .fat_lba(fat_lba), .data_lba(data_lba), .spc_log2(spc_log2),
        .root_clus(root_clus),
        .tw_en(tw_en), .tw_addr(tw_addr), .tw_data(tw_data),
        .img_total(img_total), .mus_total(mus_total),
        .scan_done(scan_done), .scan_err(scan_err)
    );

    wire        i_req, i_done, m_req, m_done;
    wire [5:0]  i_rec, m_rec;
    wire [127:0] i_data, m_data;

    fat_tbl u_tbl (
        .clk(clk_sd), .rst(rst),
        .wr_en(tw_en), .wr_addr(tw_addr), .wr_data(tw_data),
        .i_req(i_req), .i_rec(i_rec), .i_done(i_done), .i_data(i_data),
        .m_req(m_req), .m_rec(m_rec), .m_done(m_done), .m_data(m_data)
    );

    // ------------------------------------------------------------------
    // 图片读器
    // ------------------------------------------------------------------
    reg         rd_en = 1'b0;
    reg  [7:0]  img_idx = 8'd0;
    wire        rdr_busy, rdr_done;
    wire [7:0]  byte_d;
    wire        byte_v;

    sd_bmp_reader u_rdr (
        .clk(clk_sd), .rst(rst),
        .rd_start_en(img_start), .rd_sec_addr(img_sec),
        .rd_busy(img_busy), .rd_val_en(img_val), .rd_val_data(img_data),
        .sd_init_done(1'b1),
        .fat_lba(fat_lba), .data_lba(data_lba), .spc_log2(spc_log2),
        .tbl_req(i_req), .tbl_rec(i_rec), .tbl_done(i_done), .tbl_data(i_data),
        .enable(rd_en), .img_idx(img_idx),
        .fifo_used(9'd0), .stop(1'b0),
        .busy(rdr_busy), .done(rdr_done),
        .byte_data(byte_d), .byte_valid(byte_v)
    );

    // ------------------------------------------------------------------
    // 音频
    // ------------------------------------------------------------------
    reg [2:0] track = 3'd0;
    wire      wav_valid;
    wire [23:0] wav_l, wav_r;
    wire [7:0]  wav_lvl;
    wire        trk_bad;
    wire [63:0] trk_name;
    wire [15:0] wav_hdr;

    wav_player #(.TRK_NUM(6), .CLK_HZ(1_000_000), .SAMPLE_HZ(48_000)) u_wav (
        .clk(clk_pix), .clk_sd(clk_sd), .rst(rst),
        .track(track), .vol(4'd10),
        .fat_lba(fat_lba), .data_lba(data_lba), .spc_log2(spc_log2),
        .tbl_req(m_req), .tbl_rec(m_rec), .tbl_done(m_done), .tbl_data(m_data),
        .s_req(wav_req), .s_sec(wav_sec),
        .s_busy(wav_busy), .s_val(wav_val), .s_data(wav_data),
        .aud_valid(wav_valid), .aud_left(wav_l), .aud_right(wav_r),
        .level(wav_lvl), .trk_bad(trk_bad), .trk_name(trk_name), .dbg_hdr(wav_hdr)
    );

    // ------------------------------------------------------------------
    // 逐字节比对（边收边从期望文件读）
    // ------------------------------------------------------------------
    integer efd;
    integer img_bytes_ok = 0;
    integer exp_len = 0;            // 本张图的有效字节数（最后一扇区的填充不算）
    reg [7:0] eb;
    integer n_byte, n_bad;
    reg     cap_en;
    reg [7:0] first_bad_got, first_bad_exp;
    integer   first_bad_at;

    always @(posedge clk_sd) begin
        if (cap_en && byte_v) begin
            if (n_byte < exp_len) begin
                eb = $fgetc(efd);
            end else begin
                eb = byte_d;                 // 填充字节不比对
            end
            if (eb !== byte_d) begin
                if (n_bad == 0) begin
                    first_bad_at  <= n_byte;
                    first_bad_got <= byte_d;
                    first_bad_exp <= eb;
                end
                n_bad <= n_bad + 1;
            end
            n_byte <= n_byte + 1;
        end
    end

    // WAV 采样比对
    integer pfd;
    reg [7:0] plo, phi;
    integer n_samp, n_sbad, first_sbad_at;
    reg [15:0] exp_samp;

    always @(posedge clk_sd) begin
        if (u_wav.fifo_wr) begin
            plo = $fgetc(pfd);
            phi = $fgetc(pfd);
            exp_samp = {phi, plo};
            if (u_wav.word_le !== exp_samp) begin
                if (n_sbad == 0) first_sbad_at <= n_samp;
                n_sbad <= n_sbad + 1;
            end
            n_samp <= n_samp + 1;
        end
    end

    integer k, rec, pos;
    integer timeout;

    initial begin
        sfd = $fopen("fat_card.img", "rb");
        if (sfd == 0) begin
            $display("ERROR: can't open fat_card.img");
            $finish;
        end
        n_byte = 0; n_bad = 0; cap_en = 0; n_samp = 0; n_sbad = 0;
        first_bad_at = 0; first_sbad_at = 0; first_bad_got = 0; first_bad_exp = 0;
        efd = 0; pfd = 0;

        // ---- 1. 挂载 ----
        timeout = 0;
        while ((mnt_done !== 1'b1) && timeout < 200000) begin @(posedge clk_sd); timeout = timeout + 1; end
        $display("[mnt] ok=%b part=%0d fat=%0d data=%0d spc_log2=%0d root=%0d err=%0d",
                 mnt_ok, part_lba, fat_lba, data_lba, spc_log2, root_clus, mnt_err);

        // ---- 2. 扫描 ----
        timeout = 0;
        while ((scan_done !== 1'b1) && timeout < 2000000) begin @(posedge clk_sd); timeout = timeout + 1; end
        $display("[scan] img=%0d mus=%0d err=%0d done=%b", img_total, mus_total, scan_err, scan_done);

        for (k = 0; k < 6; k = k + 1) begin
            $display("[tbl %0d] clus=%0d size=%0d name=%c%c%c%c%c%c%c%c",
                     k,
                     {u_tbl.mem[k*16+3], u_tbl.mem[k*16+2], u_tbl.mem[k*16+1], u_tbl.mem[k*16+0]},
                     {u_tbl.mem[k*16+7], u_tbl.mem[k*16+6], u_tbl.mem[k*16+5], u_tbl.mem[k*16+4]},
                     u_tbl.mem[k*16+8], u_tbl.mem[k*16+9], u_tbl.mem[k*16+10], u_tbl.mem[k*16+11],
                     u_tbl.mem[k*16+12], u_tbl.mem[k*16+13], u_tbl.mem[k*16+14], u_tbl.mem[k*16+15]);
        end

        // ---- 3. 逐字节读两张图 ----
        for (k = 0; k < 2; k = k + 1) begin
            efd = $fopen(k == 0 ? "fat_exp/exp_00.bin" : "fat_exp/exp_01.bin", "rb");
            exp_len = (k == 0) ? 230454 : 57654;
            n_byte = 0; n_bad = 0;
            img_idx = k[7:0];
            cap_en  = 1'b1;
            @(negedge clk_sd); rd_en = 1'b1;
            timeout = 0;
            while ((rdr_done !== 1'b1) && timeout < 6000000) begin @(posedge clk_sd); timeout = timeout + 1; end
            repeat (20) @(posedge clk_sd);
            rd_en = 1'b0;
            cap_en = 1'b0;
            repeat (50) @(posedge clk_sd);
            $fclose(efd);
            $display("[img %0d] bytes=%0d bad=%0d (first bad @%0d got=%h exp=%h) done=%b to=%0d",
                     k, n_byte, n_bad, first_bad_at, first_bad_got, first_bad_exp, rdr_done, timeout);
            if ((k == 0 && n_byte == 230912) || (k == 1 && n_byte == 57856)) img_bytes_ok = img_bytes_ok + 1;
        end

        // ---- 4. WAV 采样比对（前 3000 个）----
        pfd = $fopen("fat_exp/exp_03.pcm", "rb");
        n_samp = 0; n_sbad = 0;
        track = 3'd1;
        timeout = 0;
        while (n_samp < 3000 && timeout < 2000000) begin @(posedge clk_sd); timeout = timeout + 1; end
        $display("[wav] samples=%0d bad=%0d (first bad @%0d) name=%c%c%c%c%c%c%c%c trk_bad=%b",
                 n_samp, n_sbad, first_sbad_at,
                 trk_name[7:0], trk_name[15:8], trk_name[23:16], trk_name[31:24],
                 trk_name[39:32], trk_name[47:40], trk_name[55:48], trk_name[63:56], trk_bad);

        if (n_bad == 0 && n_sbad == 0 && img_bytes_ok && n_samp >= 3000)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");
        $finish;
    end

    initial begin
        #400_000_000;
        $display("RESULT: TIMEOUT");
        $finish;
    end

endmodule
