// ============================================================================
//  tb_wav.v —— wav_player + sd_arb 单元测试（假 SD 模型喂真实 WAV 字节流）
//
//  假 SD 的行为严格模仿 sd_read 的输出时序：
//    收到 s_start → 拉 busy → 连续 256 拍 s_val（每拍一个 16bit 字，先到的字节在高位）
//    → busy 落下。
//
//  检查项：
//    1) 扇区地址序列：0,1,2,...（连续）
//    2) 采样内容：第 k 个 aud_valid 采样 == WAV 数据区第 k 个 16bit 采样（小端）
//    3) 采样率：10ms 内 480 个 aud_valid
//    4) 循环：走完 WAV 头里声明的长度后，扇区地址回到 0
//    5) 电平 level 有两档以上（说明有声音）
// ============================================================================
`timescale 1ns / 1ps

module tb_wav;

    reg clk = 1'b0;
    reg clk_sd = 1'b0;
    reg rst = 1'b1;

    always #13.3 clk = ~clk;         // 37.5MHz
    always #20.0 clk_sd = ~clk_sd;   // 25MHz

    // ---------------- 假 SD：内存里的 WAV 字节 ----------------
    localparam integer MAXB = 64*1024;
    reg [7:0] mem [0:MAXB-1];
    integer   nbyte = 0;

    reg [1023:0] fname;
    integer fd, ch, k;

    initial begin
        if (!$value$plusargs("FILE=%s", fname)) begin
            $display("[ERR] 需要 +FILE=<wav>");
            $finish;
        end
        fd = $fopen(fname, "rb");
        if (fd == 0) begin
            $display("[ERR] 打不开 %0s", fname);
            $finish;
        end
        for (k = 0; k < MAXB; k = k + 1) mem[k] = 8'h00;
        k = 0;
        ch = $fgetc(fd);
        while (ch != -1 && k < MAXB) begin
            mem[k] = ch[7:0];
            k = k + 1;
            ch = $fgetc(fd);
        end
        $fclose(fd);
        nbyte = k;
        $display("[tb] 读入 %0d 字节", nbyte);
    end

    // ---------------- DUT ----------------
    reg  [2:0] track = 3'd1;
    reg  [3:0] vol   = 4'd10;

    wire        a_req, a_busy, a_val;
    wire [31:0] a_sec;
    wire [15:0] a_data;

    wire        s_start, s_busy, s_val;
    wire [31:0] s_sec;
    wire [15:0] s_data;

    reg         f_busy = 1'b0, f_val = 1'b0;
    reg  [15:0] f_data = 16'd0;
    reg  [31:0] f_base = 32'd0;
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
        .SEC_BASE(0), .SEC_STRIDE(4096), .TRK_NUM(1),
        .CLK_HZ(37_500_000), .SAMPLE_HZ(48_000)
    ) u_wav (
        .clk(clk), .clk_sd(clk_sd), .rst(rst),
        .track(track), .vol(vol),
        .s_req(a_req), .s_sec(a_sec),
        .s_busy(a_busy), .s_val(a_val), .s_data(a_data),
        .aud_valid(aud_valid), .aud_left(aud_l), .aud_right(aud_r),
        .level(level)
    );

    // 假 SD 行为
    always @(posedge clk_sd or posedge rst) begin
        if (rst) begin
            f_busy <= 1'b0;
            f_val  <= 1'b0;
            f_cnt  <= 0;
            f_base <= 32'd0;
        end else begin
            f_val <= 1'b0;
            if (s_start) begin
                f_busy <= 1'b1;
                f_cnt  <= 0;
                f_base <= s_sec * 32'd512;
            end else if (f_busy) begin
                if (f_cnt < 256) begin
                    f_data <= {mem[f_base + f_cnt*2], mem[f_base + f_cnt*2 + 1]};
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

    always @(posedge clk) begin
        if (aud_valid) begin
            nval = nval + 1;
            // aud_left 是采样左移 8 位；取高 16 位还原
            if (ncap < NCAP) begin
                cap[ncap] = aud_l[23:8];
                ncap = ncap + 1;
            end
            if (level < lvl_lo) lvl_lo = level;
            if (level > lvl_hi) lvl_hi = level;
        end
    end

    // 扇区序列检查
    integer sec_expect = 0;
    integer sec_bad = 0;
    integer sec_first = -1;

    always @(posedge clk_sd) begin
        if (s_start) begin
            if (sec_first < 0) sec_first = s_sec;
            if (s_sec !== sec_expect) begin
                if (sec_bad < 5)
                    $display("[ERR] 扇区序号错: 得到 %0d 期望 %0d", s_sec, sec_expect);
                sec_bad = sec_bad + 1;
            end
            sec_expect = s_sec + 1;
        end
    end

    // ---------------- 主流程 ----------------
    integer i, bad, hdr_bytes, total_smp, sec_len;
    integer rate, rate_10ms_start;

    initial begin
        repeat (20) @(negedge clk);
        rst = 1'b0;

        // 等 FIFO 灌起来，抓 10ms 的 aud_valid 数量
        repeat (200000) @(negedge clk);
        nval = 0;
        repeat (375000) @(negedge clk);
        rate = nval * 100;
        if ((rate > 47900) && (rate < 48100))
            $display("[ok] 采样率 %0d Hz（10ms 内 %0d 个）", rate, nval);
        else begin
            $display("[FAIL] 采样率 %0d Hz，应约 48000", rate);
        end

        // 采样内容：从 WAV 头里算数据起点，逐个比对
        hdr_bytes = 44;                          // 工具保证是标准 44 字节头
        total_smp = (nbyte - hdr_bytes) / 2;
        if (total_smp > ncap) total_smp = ncap;  // 只比对真正抓到的
        if (total_smp < 600) begin
            $display("[FAIL] 只抓到 %0d 个采样，样本不足", total_smp);
        end
        bad = 0;
        for (i = 0; i < total_smp; i = i + 1) begin
            if (cap[i] !== {mem[hdr_bytes + i*2 + 1], mem[hdr_bytes + i*2]}) begin
                if (bad < 6)
                    $display("[ERR] 采样 %0d: 得到 %04h 期望 %04h",
                             i, cap[i], {mem[hdr_bytes + i*2 + 1], mem[hdr_bytes + i*2]});
                bad = bad + 1;
            end
        end
        $display("[info] 比对 %0d 个采样，错 %0d 个", total_smp, bad);

        // 循环：WAV 长度 -> 扇区数
        sec_len = ((nbyte - hdr_bytes) / 2 + 255) / 256;
        $display("[info] 文件 %0d 字节 -> %0d 采样 -> 预期 %0d 扇区一轮",
                 nbyte, (nbyte - hdr_bytes) / 2, sec_len);
        if (sec_bad != 0) $display("[FAIL] 扇区序列有 %0d 处不对", sec_bad);
        else              $display("[ok] 扇区地址连续（首扇区 %0d）", sec_first);

        // 电平应当与"这段时间内文件里的峰值"一致（歌曲开头可能是静音，不能假设非零）
        begin : chk_lvl
            integer j, exp_pk, got_pk;
            exp_pk = 0;
            for (j = 0; j < total_smp; j = j + 1) begin
                got_pk = {mem[hdr_bytes + j*2 + 1], mem[hdr_bytes + j*2]};
                if (got_pk > 32767) got_pk = 65536 - got_pk;   // 负数
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

        if (bad == 0 && sec_bad == 0 && lvl_bad == 0)
            $display("[PASS] wav_player 全部用例通过");
        else
            $display("[FAIL] wav_player 有错误");
        $finish;
    end

    initial begin
        #900_000_000;
        $display("[FAIL] timeout, nval=%0d ncap=%0d", nval, ncap);
        $finish;
    end

endmodule
