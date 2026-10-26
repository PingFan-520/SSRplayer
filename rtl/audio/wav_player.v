// ============================================================================
//  wav_player.v —— 从 SD 卡播放 WAV（单声道 16bit 48kHz）
//
//  格式约定（PC 端 tools/make_sd_image.py 保证）：
//    每个曲目 = 标准 44 字节 WAV 头 + PCM 数据，单声道 / 16bit / 48kHz。
//    单声道是关键：SD 每来一个 16bit 字正好是一个采样
//    （SPI 先收到的字节落在 data[15:8]，所以 sample = {data[7:0], data[15:8]}）。
//    立体声就得两字节配对，多一层状态机，而音乐相框并不需要立体声。
//
//  结构：
//    SD 域(25MHz)：按扇区连续读 → 跳过 44 字节头 → 每字一个采样 → 异步 FIFO
//    像素域(37.5MHz)：按 48kHz 节拍取一个采样 → 乘音量 → 24bit 送 HDMI
//    长度直接解析 WAV 头里的 data size（第 20/21 个字），循环点精确、无填充静音。
//
//  为什么 FIFO 要 1024 深：
//    一个扇区 = 256 采样 = 5.3ms；1024 深 ≈ 21ms。
//    换图时 SD 总线被图片读取占用（音频优先但仍按扇区抢），需要这点余量兜住。
// ============================================================================
`timescale 1ns / 1ps

module wav_player #(
    parameter integer SEC_BASE   = 45312,   // 音乐区起始扇区
    parameter integer SEC_STRIDE = 8952,    // 每首占的扇区数
    parameter integer TRK_NUM    = 4,       // 曲目数
    parameter integer HDR_WORDS  = 22,      // 44 字节头 = 22 个 16bit 字
    parameter integer CLK_HZ     = 37_500_000,
    parameter integer SAMPLE_HZ  = 48_000
)(
    input  wire        clk,          // 37.5MHz 像素域（消费侧）
    input  wire        clk_sd,       // 25MHz（SD 侧）
    input  wire        rst,          // 高有效

    input  wire [2:0]  track,        // 1..TRK_NUM 播放；0 = 关闭
    input  wire [3:0]  vol,          // 0..10

    // ---- 到 sd_arb ----
    output reg         s_req,
    output reg  [31:0] s_sec,
    input  wire        s_busy,
    input  wire        s_val,
    input  wire [15:0] s_data,

    // ---- 音频（像素域）----
    output reg         aud_valid,
    output reg  [23:0] aud_left,
    output reg  [23:0] aud_right,
    output wire [7:0]  level,        // 当前电平（给可视化）
    output wire        trk_bad       // 1 = 曲目起点的头不是 RIFF（卡镜像/参数不匹配）
);

    // ==================================================================
    // 1) track 从像素域同步到 SD 域 + 变化检测
    // ==================================================================
    reg [2:0] trk_s1, trk_s2, trk_d;

    always @(posedge clk_sd or posedge rst) begin
        if (rst) begin
            trk_s1 <= 3'd0;
            trk_s2 <= 3'd0;
            trk_d  <= 3'd0;
        end else begin
            trk_s1 <= track;
            trk_s2 <= trk_s1;
            trk_d  <= trk_s2;
        end
    end

    wire        en      = (trk_s2 != 3'd0) && (trk_s2 <= TRK_NUM[2:0]);
    wire        trk_chg = (trk_s2 != trk_d);
    wire [31:0] trk_base = SEC_BASE[31:0] +
                           (({29'd0, trk_s2} - 32'd1) * SEC_STRIDE);

    // ==================================================================
    // 2) SD 域：按扇区读 + 跳头 + 拆采样
    // ==================================================================
    localparam [2:0] S_IDLE = 3'd0,
                     S_REQ  = 3'd1,   // 已发请求，等 256 个字
                     S_NEXT = 3'd2;   // 一个扇区收完，等 busy 落下

    // FIFO 状态（声明要放在使用它的状态机之前）
    wire        fifo_full, fifo_empty, fifo_rvld;
    wire [15:0] fifo_dout;
    wire [10:0] fifo_used;

    reg [2:0]  st;
    reg        bsync;             // 已经看到本扇区的 busy 上升沿
    reg [31:0] sec_cnt;           // 本曲第几个扇区
    reg [8:0]  wcnt;              // 本扇区已收字数
    reg [15:0] len_lo, len_hi;    // WAV 头里的 data size
    reg [15:0] hdr0, hdr1;        // 曲目首扇区的头两个字（应为 "RI" "FF"）
    reg        hdr_wav;           // 1 = 该曲目起点确实是 RIFF/WAVE
    reg        hdr_chk;           // 已经读到第 2 个扇区，校验结果有效

    wire [7:0]  hdr_i   = wcnt[7:0];
    wire        is_hdr  = (sec_cnt == 32'd0) && (hdr_i < HDR_WORDS[7:0]);
    wire [15:0] word_le = {s_data[7:0], s_data[15:8]};

    // 由头部长度算出的扇区数（组合，头部一收齐就生效；异常时退回 stride）
    wire [31:0] len_b    = {len_hi, len_lo};
    wire [31:0] sl_raw   = ((len_b >> 1) + 32'd255) >> 8;
    // 长度太短（<8 扇区，约 2 秒）或超出配额，都认为头没读对，退回整段 stride
    wire [31:0] sl       = ((sl_raw < 32'd8) || (sl_raw > SEC_STRIDE[31:0]))
                           ? SEC_STRIDE[31:0] : sl_raw;

    always @(posedge clk_sd or posedge rst) begin
        if (rst) begin
            st      <= S_IDLE;
            s_req   <= 1'b0;
            s_sec   <= 32'd0;
            sec_cnt <= 32'd0;
            wcnt    <= 9'd0;
            len_lo  <= 16'd0;
            len_hi  <= 16'd0;
            bsync   <= 1'b0;
            hdr0    <= 16'd0;
            hdr1    <= 16'd0;
            hdr_wav <= 1'b0;
            hdr_chk <= 1'b0;
        end else begin
            // 曲目起点必须是 RIFF/WAVE，否则说明 SD 卡上的镜像和 RTL 的参数对不上
            // （音乐区扇区号变了、卡没重写）。这时**宁可不放**，也不要拿图片像素
            // 当 PCM 播出去 —— 那正是一段段的"尖锐爆音"。
            hdr_wav <= (hdr0 == 16'h4952) && (hdr1 == 16'h4646);
            if (sec_cnt >= 32'd2) hdr_chk <= 1'b1;

            case (st)
                S_IDLE: begin
                    s_req <= 1'b0;
                    wcnt  <= 9'd0;
                    bsync <= 1'b0;
                    if (en) begin
                        sec_cnt <= 32'd0;
                        s_sec   <= trk_base;
                        s_req   <= 1'b1;
                        st      <= S_REQ;
                    end
                end

                S_REQ: begin
                    // 先等 busy 起来 = 这一扇区真正开始，之后收到的字才算本扇区的数据。
                    // 没有这一步，上一扇区尾巴/CRC 的字会被当成本扇区的开头，
                    // 整条流就永久错位（听感是持续的"尖锐沙沙"）。
                    if (s_busy) bsync <= 1'b1;

                    if (bsync && s_val) begin
                        // 抓长度：第 20/21 个字（字节 40..43 = data size）
                        if ((sec_cnt == 32'd0) && (hdr_i == 8'd20)) len_lo <= word_le;
                        if ((sec_cnt == 32'd0) && (hdr_i == 8'd21)) len_hi <= word_le;
                        // 抓曲目开头的魔术字："RIFF" -> 字 0 = 0x4952、字 1 = 0x4646
                        if ((sec_cnt == 32'd0) && (hdr_i == 8'd0)) hdr0 <= word_le;
                        if ((sec_cnt == 32'd0) && (hdr_i == 8'd1)) hdr1 <= word_le;

                        if (wcnt == 9'd255) begin
                            wcnt  <= 9'd0;
                            s_req <= 1'b0;
                            bsync <= 1'b0;
                            st    <= S_NEXT;
                        end else begin
                            wcnt <= wcnt + 9'd1;
                        end
                    end
                end

                S_NEXT: begin
                    s_req <= 1'b0;
                    // FIFO 快满就先别读：否则写不进去的采样会被直接丢掉
                    //（仿真里表现为"隔一段少几个采样"）。留 324 字余量 > 一整个扇区。
                    if (!s_busy && (fifo_used < 11'd700)) begin
                        if (sec_cnt + 32'd1 >= sl) begin
                            sec_cnt <= 32'd0;
                            s_sec   <= trk_base;              // 循环
                        end else begin
                            sec_cnt <= sec_cnt + 32'd1;
                            s_sec   <= trk_base + sec_cnt + 32'd1;
                        end
                        s_req <= 1'b1;
                        st    <= S_REQ;
                    end
                end

                default: st <= S_IDLE;
            endcase

            // 切曲 / 关闭：回到起点
            if (trk_chg || !en) begin
                st      <= S_IDLE;
                s_req   <= 1'b0;
                sec_cnt <= 32'd0;
                wcnt    <= 9'd0;
                hdr0    <= 16'd0;          // 换曲后重新校验一次
                hdr1    <= 16'd0;
                hdr_chk <= 1'b0;
            end
        end
    end

    // ==================================================================
    // 3) 异步 FIFO：SD 域写、像素域读
    // ==================================================================
    reg         fifo_rd;
    // ★ 写 FIFO 必须同时满足 bsync：只有"本扇区 busy 起来之后"收到的字才算数据。
    //   少了 bsync，上一扇区的尾巴/CRC、或仲裁器切主时残留的字都会被写进 FIFO，
    //   整个采样流从此错位半个采样 —— 听感就是"尖锐的沙沙/爆音"。
    wire        fifo_wr = s_val & bsync & hdr_wav & ~is_hdr & ~fifo_full;

    // 深度固定 1024（21ms）。**不要再加大**：2048 要多占 2 块 M9K，
    // 这块板的 BRAM/布线余量很紧，实测会花屏（Incremental route 挤爆）。
    afifo #(.DW(16), .AW(10)) u_fifo (
        .clk_w(clk_sd), .clk_r(clk),
        .aclr(rst | trk_chg),
        .wr_en(fifo_wr), .wr_data(word_le), .wr_full(fifo_full),
        .rd_en(fifo_rd), .rd_data(fifo_dout), .rd_empty(fifo_empty),
        .rd_valid(fifo_rvld), .wr_used(fifo_used)
    );

    // ==================================================================
    // 4) 像素域：48kHz 取样 + 音量
    // ==================================================================
    localparam [63:0] SMP_INC = (SAMPLE_HZ * 64'd4294967296) / CLK_HZ;

    reg [32:0] smp_acc;
    always @(posedge clk or posedge rst) begin
        if (rst) smp_acc <= 33'd0;
        else     smp_acc <= {1'b0, smp_acc[31:0]} + SMP_INC[32:0];
    end
    wire tick = smp_acc[32];

    always @(posedge clk or posedge rst) begin
        if (rst)      fifo_rd <= 1'b0;
        else          fifo_rd <= tick & ~fifo_empty;
    end

    reg signed [15:0] samp;

    // 音量 0..10 -> 8 位增益（与 tone_gen 同一张表）
    reg [8:0] vol_g;
    always @(*) begin
        case (vol)
            4'd0:    vol_g = 9'd0;
            4'd1:    vol_g = 9'd26;
            4'd2:    vol_g = 9'd51;
            4'd3:    vol_g = 9'd77;
            4'd4:    vol_g = 9'd102;
            4'd5:    vol_g = 9'd128;
            4'd6:    vol_g = 9'd154;
            4'd7:    vol_g = 9'd179;
            4'd8:    vol_g = 9'd205;
            4'd9:    vol_g = 9'd230;
            default: vol_g = 9'd256;
        endcase
    end

    // 注意：vol_g 满档是 256（9 位），不能截成 8 位，否则满音量会变成 0（静音）
    wire signed [24:0] prod   = samp * $signed({1'b0, vol_g});
    wire signed [15:0] g16    = prod[23:8];
    wire        [23:0] scaled = { {2{g16[15]}}, g16, 8'd0 };
    wire        [15:0] mag    = g16[15] ? (~g16 + 16'd1) : g16;

    assign level = mag[15:7];                  // 0..255
    assign trk_bad = hdr_chk & ~hdr_wav;        // 数码管上用 F 提示"卡不对"

    // aud_valid 必须**严格 48kHz 连续**：HDMI 核按 valid 采样，
    // 一旦少给一拍，接收端音频 PLL 会抖 -> 尖锐爆音。
    // FIFO 万一见底，就保持上一个采样（sample & hold），而不是留空拍。
    reg tick_d, tick_d2, tick_d3;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            samp      <= 16'sd0;
            tick_d    <= 1'b0;
            tick_d2   <= 1'b0;
            tick_d3   <= 1'b0;
            aud_valid <= 1'b0;
            aud_left  <= 24'd0;
            aud_right <= 24'd0;
        end else begin
            tick_d  <= tick;
            tick_d2 <= tick_d;
            tick_d3 <= tick_d2;
            if (fifo_rvld) samp <= $signed(fifo_dout);

            // aud_valid 比 tick 晚 3 拍：此时 samp 已经是本次弹出的采样，
            // 与 aud_left 严格同拍（第 k 个 valid 就是文件第 k 个采样）
            aud_valid <= tick_d3;
            aud_left  <= en ? scaled : 24'd0;
            aud_right <= en ? scaled : 24'd0;
        end
    end

endmodule
