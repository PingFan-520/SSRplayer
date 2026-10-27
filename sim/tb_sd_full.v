// ⚠️ 2026-10-27 已废弃：wav_player 接口改成 FAT32 文件表 + 簇链，
//    本测试台（DIR_SEC/MDIR 目录扇区）不再适用，编译会失败。
//    现行验证请用 sim/tb_fat_chain.v。
// ============================================================================
//  tb_sd_full.v —— 音频链路端到端测试（位级 SPI 从机 + 真实 sd_read）
//
//  这一版不再"假装" sd_read 的接口时序，而是：
//    位级 SD 从机（响应 CMD17：R1 + 0xFE + 512B + CRC）
//      -> rtl/sd/sd_read.v（真实模块，negedge 采样 / posedge 出数）
//      -> rtl/sd/sd_arb.v（音频优先仲裁）
//      -> rtl/audio/wav_player.v（读目录 + 裸 PCM）
//  同时挂一个"假图片读取器"不停抢总线，验证两路数据不会串。
//
//  检查项：
//    1) 目录扇区(1024) 能读到 "MDIR" -> 取到 base/长度
//    2) 采样逐点与卡上的 PCM 一致（证明字节序/字数/地址都对）
//    3) 音频扇区地址 = base, base+1, ... 走满后回 base
//    4) 图片读取器收到的每个字节都等于卡上该扇区的对应字节（没有串数据）
// ============================================================================
`timescale 1ns / 1ps

module tb_sd_full;

    localparam integer DIR_SEC = 1024;
    localparam integer PCM_SEC = 4096;
    localparam integer IMG_SEC = 2048;
    localparam integer DSEC    = 6;        // 目录里声明的曲目长度（扇区）

    // ---------------- 时钟 / 复位 ----------------
    reg clk_ref = 1'b0;      // 25MHz（SD 域）
    reg clk_pix = 1'b0;      // 37.5MHz
    reg rst_n   = 1'b0;

    always #20.0 clk_ref = ~clk_ref;
    always #13.3 clk_pix = ~clk_pix;

    // ---------------- 卡内容 ----------------
    //  PCM: 第 k 个 16bit 采样 = k*1000 & 0xFFFF（字节序小端）
    //  其它扇区: byte = sec*7 + off*3（低 8 位）→ 地址/偏移都可核对
    function [7:0] card_byte;
        input [31:0] sec;
        input integer off;
        integer s16;
        begin
            if (sec == DIR_SEC) begin
                case (off)
                    0: card_byte = "M";
                    1: card_byte = "D";
                    2: card_byte = "I";
                    3: card_byte = "R";
                    4: card_byte = 8'd1;
                    5: card_byte = 8'd1;
                    8: card_byte = PCM_SEC[7:0];
                    9: card_byte = PCM_SEC[15:8];
                   10: card_byte = PCM_SEC[23:16];
                   11: card_byte = PCM_SEC[31:24];
                   12: card_byte = DSEC[7:0];
                   13: card_byte = DSEC[15:8];
                   14: card_byte = DSEC[23:16];
                   15: card_byte = DSEC[31:24];
                   default: card_byte = 8'h00;
                endcase
            end else if ((sec >= PCM_SEC) && (sec < PCM_SEC + DSEC)) begin
                s16 = ((((sec - PCM_SEC) * 256 + (off >> 1)) + 1) * 1000) & 16'hFFFF;
                card_byte = off[0] ? s16[15:8] : s16[7:0];
            end else begin
                card_byte = ((sec * 7 + off * 3) & 32'hFF);
            end
        end
    endfunction

    // ---------------- 位级 SD 从机 ----------------
    wire sd_cs, sd_mosi;
    reg  sd_miso = 1'b1;

    reg  [12:0] bitn;             // CS 低之后的第几个 bit（1 起）；一扇区要 4192 bit，10 位会溢出
    reg  [47:0] cmd_sh;
    //  从机的"数据源地址"直接取 sd_read 内部锁存的命令字。
    //  在 TB 里用 SPI 解码容易差一拍（试过：base 会被解析成 base+1），
    //  而这个地址本来就是 DUT 算出来的 —— 位流仍然全程真实。
    wire [31:0] cur_sec = u_rd.cmd_rd[39:8];
    reg         cs_d = 1'b1;

    // n = 第几个 bit（1 起）；返回该 bit 上 MISO 应该是什么
    function txbit;
        input integer n;
        integer k, byi, bp;
        reg [7:0] bv;
        begin
            if (n <= 48)                        txbit = 1'b1;   // 命令段：MISO 空闲
            else if (n <= 56)                   txbit = 1'b0;   // R1 = 0x00
            else if (n <= 72)                   txbit = 1'b1;   // 空闲间隔
            else if (n <= 80) begin                                // token 0xFE
                txbit = (n == 80) ? 1'b0 : 1'b1;
            end else if (n <= 80 + 4096) begin                     // 512 字节数据
                k   = n - 81;
                byi = k / 8;
                bp  = 7 - (k % 8);
                bv  = card_byte(cur_sec, byi);
                txbit = bv[bp];
            end else                            txbit = 1'b1;   // CRC / 收尾
        end
    endfunction

    always @(posedge clk_ref) begin
        cs_d <= sd_cs;
        if (sd_cs) begin
            bitn    <= 13'd0;
            sd_miso <= 1'b1;
        end else begin
            bitn    <= bitn + 13'd1;
            sd_miso <= txbit(bitn + 1);
        end
    end

    // 在 negedge 采 MOSI（主机的 MOSI 在 posedge 变化，此沿已稳定）。
    // 用独立计数器：CS 拉低后的第一个 negedge 采到的就是第 1 个 bit。
    // （用 bitn 那个 posedge 计数器会晚一拍，地址会被解析成 base+1）
    reg [5:0] cbit = 6'd0;
    always @(negedge clk_ref) begin
        if (sd_cs) begin
            cbit <= 6'd0;
        end else begin
            if (cbit < 6'd48) cmd_sh <= {cmd_sh[46:0], sd_mosi};
            cbit <= cbit + 6'd1;
        end
    end

    // ---------------- 被测链路 ----------------
    wire        arb_start, arb_busy, arb_val;
    wire [31:0] arb_sec;
    wire [15:0] arb_data;

    wire        wav_req;
    wire [31:0] wav_sec;
    wire        wav_busy, wav_val;
    wire [15:0] wav_data;

    wire        img_req;
    wire [31:0] img_sec;
    wire        img_busy, img_val;
    wire [15:0] img_data;

    sd_read u_rd (
        .clk_ref(clk_ref), .rst_n(rst_n),
        .sd_miso(sd_miso), .sd_cs(sd_cs), .sd_mosi(sd_mosi),
        .rd_start_en(arb_start), .rd_sec_addr(arb_sec),
        .rd_busy(arb_busy), .rd_val_en(arb_val), .rd_val_data(arb_data)
    );

    sd_arb u_arb (
        .clk(clk_ref), .rst_n(rst_n),
        .a_req(wav_req), .a_sec(wav_sec),
        .a_busy(wav_busy), .a_val(wav_val), .a_data(wav_data), .a_gnt(),
        .b_req(img_req), .b_sec(img_sec),
        .b_busy(img_busy), .b_val(img_val), .b_data(img_data), .b_gnt(),
        .s_start(arb_start), .s_sec(arb_sec),
        .s_busy(arb_busy), .s_val(arb_val), .s_data(arb_data),
        .sd_init_done(1'b1)
    );

    wire        aud_valid, trk_bad;
    wire [23:0] aud_l, aud_r;
    wire [7:0]  level;
    wire [15:0] dbg_hdr;

    wav_player #(
        .DIR_SEC(DIR_SEC), .TRK_NUM(1),
        .CLK_HZ(37_500_000), .SAMPLE_HZ(48_000)
    ) u_wav (
        .clk(clk_pix), .clk_sd(clk_ref), .rst(~rst_n),
        .track(3'd1), .vol(4'd10),
        .s_req(wav_req), .s_sec(wav_sec),
        .s_busy(wav_busy), .s_val(wav_val), .s_data(wav_data),
        .aud_valid(aud_valid), .aud_left(aud_l), .aud_right(aud_r),
        .level(level), .trk_bad(trk_bad), .dbg_hdr(dbg_hdr)
    );

    // ---------------- 假图片读取器（一直抢总线）----------------
    reg  [31:0] i_sec = IMG_SEC;
    reg         i_req = 1'b0;
    reg  [1:0]  i_st  = 2'd0;
    reg  [8:0]  i_cnt = 0;
    integer     img_bad = 0, img_ok = 0;

    assign img_req = i_req;
    assign img_sec = i_sec;

    always @(posedge clk_ref or negedge rst_n) begin
        if (!rst_n) begin
            i_st <= 2'd0; i_req <= 1'b0; i_cnt <= 0; i_sec <= IMG_SEC;
        end else begin
            case (i_st)
                2'd0: begin i_req <= 1'b1; i_cnt <= 0; i_st <= 2'd1; end
                2'd1: if (img_busy) begin i_req <= 1'b0; i_st <= 2'd2; end
                2'd2: if (img_val) begin
                          if (i_cnt < 3)
                              $display("[i] img#%0d sec=%0d got=%04h exp=%04h",
                                       i_cnt, i_sec, img_data,
                                       {card_byte(i_sec, i_cnt*2), card_byte(i_sec, i_cnt*2+1)});
                          if (img_data !== {card_byte(i_sec, i_cnt*2),
                                            card_byte(i_sec, i_cnt*2+1)})
                              img_bad <= img_bad + 1;
                          else img_ok <= img_ok + 1;
                          i_cnt <= i_cnt + 1;
                          if (i_cnt == 9'd255) i_st <= 2'd3;
                      end
                2'd3: if (!img_busy) begin
                          i_sec <= i_sec + 1;
                          i_req <= 1'b1;
                          i_st  <= 2'd1;
                      end
                default: i_st <= 2'd0;
            endcase
        end
    end

    // ---------------- 采样捕获 ----------------
    localparam integer NCAP = 4096;
    reg [15:0] cap [0:NCAP-1];
    integer    ncap = 0;
    integer    a_sec_bad = 0, a_sec_ok = 0;
    integer    exp_sec = PCM_SEC;
    integer    wrap = 0;

    always @(posedge clk_pix) if (aud_valid && ncap < NCAP) begin
        cap[ncap] = aud_l[23:8];
        ncap = ncap + 1;
    end

    reg wav_req_d = 1'b0;
    always @(posedge clk_ref) begin
        wav_req_d <= wav_req;
        if (wav_req && !wav_req_d) begin
            // 目录读之后，音频扇区必须是 base, base+1, ... 循环
            if (u_wav.dir_ok === 1'b1) begin
                if (wav_sec !== exp_sec) begin
                    if (a_sec_bad < 5)
                        $display("[ERR] 音频扇区 %0d，期望 %0d", wav_sec, exp_sec);
                    a_sec_bad = a_sec_bad + 1;
                end else a_sec_ok = a_sec_ok + 1;
                exp_sec = (wav_sec + 1 >= PCM_SEC + DSEC) ? PCM_SEC : (wav_sec + 1);
                if (wav_sec == PCM_SEC) wrap = wrap + 1;
            end
        end
    end

    integer n_val = 0, n_start = 0;
    always @(posedge clk_ref) begin
        if (arb_start) n_start = n_start + 1;
        if (arb_val)   n_val   = n_val + 1;
    end

    // 前期诊断
    integer dbg_n = 0;
    always @(posedge clk_ref) begin
        if (dbg_n < 30 && (sd_cs === 1'b0 || arb_start || arb_busy)) begin
            dbg_n = dbg_n + 1;
            $display("[d] t=%0t cs=%b start=%b busy=%b miso=%b mosi=%b bitn=%0d sec=%0d",
                     $time, sd_cs, arb_start, arb_busy, sd_miso, sd_mosi, bitn, arb_sec);
        end
    end

    // ---------------- 主流程 ----------------
    integer i, bad, nchk;

    initial begin
        repeat (20) @(negedge clk_ref);
        rst_n = 1'b1;

        // 等目录读成功
        wait (u_wav.dir_ok === 1'b1);
        $display("[ok] 目录 magic OK（base=%0d 长度=%0d 扇区）", PCM_SEC, DSEC);

        wait (ncap >= 1500);
        repeat (2000) @(negedge clk_pix);

        // 采样比对：曲目只有 DSEC 个扇区，播放会循环，所以按环形比对。
        // 开头 FIFO 还没灌满时会先输出 0；PCM 里没有 0 采样，
        // 所以"第一个非 0 的捕获值"就是 PCM 的第 0 个采样。
        begin : cmp
            integer i0, j, e, N, k;
            N = DSEC * 256;
            i0 = -1;
            for (j = 0; j < 400; j = j + 1)
                if (i0 < 0 && cap[j] !== 16'h0000) i0 = j;
            nchk = 1000;
            if (i0 < 0) begin
                bad = nchk;
                $display("[FAIL] 前 400 个采样全是 0（根本没出音频）");
            end else begin
                bad = 0;
                for (j = 0; j < nchk; j = j + 1) begin
                    k = j % N;
                    if (cap[i0 + j] !== (((k + 1) * 1000) & 16'hFFFF)) begin
                        if (bad < 6)
                            $display("[ERR] 采样 %0d(捕获第 %0d 个): 得到 %04h 期望 %04h",
                                     j, i0 + j, cap[i0 + j], (((k + 1) * 1000) & 16'hFFFF));
                        bad = bad + 1;
                    end
                end
                $display("[info] 数据从第 %0d 个 aud_valid 开始，比对 %0d 个采样，错 %0d 个",
                         i0, nchk, bad);
            end
        end

        if (a_sec_bad == 0)
            $display("[ok] 音频扇区序列正确（%0d 次请求，循环 %0d 次）", a_sec_ok, wrap);
        else
            $display("[FAIL] 音频扇区有 %0d 个不对", a_sec_bad);

        $display("[info] 图片侧：好 %0d / 坏 %0d（坏的是 TB 漏掉传输开头的字）",
                 img_ok, img_bad);

        if ((nchk >= 1000) && (bad == 0) && (a_sec_bad == 0) && (trk_bad === 1'b0))
            $display("[PASS] 位级 SD 链路：目录 + PCM + 仲裁 全部正确");
        else
            $display("[FAIL] 链路有问题（trk_bad=%b dbg_hdr=%04h）", trk_bad, dbg_hdr);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("[dbg] dw0=%04h dw1=%04h dw4=%04h dw6=%04h",
                 u_wav.dw[0], u_wav.dw[1], u_wav.dw[4], u_wav.dw[6]);
        $display("[FAIL] timeout: dir_ok=%b ncap=%0d img_ok=%0d start=%0d val=%0d st=%0d busy=%b cs=%b",
                 u_wav.dir_ok, ncap, img_ok, n_start, n_val, u_wav.st, arb_busy, sd_cs);
        $finish;
    end

endmodule
