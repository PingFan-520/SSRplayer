// ============================================================================
//  wav_player.v —— 从 SD 卡播放音乐（裸 PCM / 单声道 16bit / 48kHz）
//
//  ★ 这一版和之前的根本区别：**布局从卡上读，RTL 里不再有绝对扇区常量**
//
//  卡上的布局（tools/make_sd_image.py 保证）：
//    扇区 DIR_SEC(=1024) ：「音乐目录」，512 字节
//        w0 = 0x444D ("MD")   w1 = 0x5249 ("IR")   w2 = 曲目数 | (版本<<8)
//        w4+4i .. w7+4i = 曲目 i+1 : base_lo, base_hi, 扇区数_lo, 扇区数_hi
//    扇区 base(曲目 i)   ：**裸 PCM**，每 16bit 字就是一个采样
//
//  为什么改成这样（都是踩过的坑）：
//    ① 以前 RTL 里写死 MUS_BASE，镜像一改布局（8 图 4 曲 -> 3 图 2 曲）就对不上，
//       卡上读到的是图片像素，当 PCM 播出去就是尖锐噪声；而且**看不出来**。
//    ② 以前要解析 WAV 头（跳 44 字节 + 读 data size）。ffmpeg 会在头里插 LIST 块，
//       data 就不在 44 字节处，读到的“长度”其实是 LIST 的 size，循环点全错。
//    ③ 现在 RTL 只需要“从目录拿 base/长度”，一个字节都不用猜：
//       目录 magic 不对 -> 直接静音 + 数码管报警（绝不把图片当音乐播）。
//
//  结构：
//    SD 域(25MHz)：读目录扇区 -> 按扇区连续读 -> 每字一个采样 -> 异步 FIFO
//    像素域(37.5MHz)：48kHz 节拍取一个采样 -> 乘音量 -> 24bit 送 HDMI
//
//  为什么 FIFO 要 1024 深：
//    一个扇区 = 256 采样 = 5.3ms；1024 深 ≈ 21ms。
//    换图时 SD 总线被图片读取占用（音频优先但仍按扇区抢），需要这点余量兜住。
//    不要再加大：2048 要多占 2 块 M9K，这块板 BRAM 余量很紧。
// ============================================================================
`timescale 1ns / 1ps

module wav_player #(
    parameter integer DIR_SEC    = 1024,     // 音乐目录扇区（永远在图片区之前）
    parameter integer TRK_NUM    = 4,        // 曲目数
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
    output wire        trk_bad,      // 1 = 目录无效（卡不是当前镜像）
    output wire [15:0] dbg_hdr       // 目录扇区第一个字（数码管诊断用）
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
    wire [1:0]  tidx    = trk_s2[1:0] - 2'd1;   // 0..3（trk_s2=0 时不用）

    // ==================================================================
    // 2) SD 域状态机
    // ==================================================================
    localparam [2:0] S_DREQ = 3'd0,   // 请求目录扇区
                     S_DRCV = 3'd1,   // 收目录扇区
                     S_DEND = 3'd2,   // 等 busy 落下 -> 校验 magic
                     S_IDLE = 3'd3,   // 准备读音频
                     S_REQ  = 3'd4,   // 已发请求，等 256 个字
                     S_NEXT = 3'd5;   // 一个扇区收完，等 busy 落下

    localparam [15:0] MAG0 = 16'h444D;   // "MD"（小端：先 'M' 后 'D'）
    localparam [15:0] MAG1 = 16'h5249;   // "IR"

    // FIFO 状态（声明放在使用它的状态机之前）
    wire        fifo_full, fifo_empty, fifo_rvld;
    wire [15:0] fifo_dout;
    wire [10:0] fifo_used;

    reg [2:0]  st;
    reg        bsync;             // 已经看到本扇区的 busy 上升沿
    reg [31:0] sec_cnt;           // 本曲第几个扇区
    reg [8:0]  wcnt;              // 本扇区已收字数

    reg [15:0] dw [0:19];         // 目录扇区前 20 个字（magic + 4 首的 base/长度）
    reg [31:0] tbase [0:3];       // 每首起始扇区
    reg [31:0] tlen  [0:3];       // 每首扇区数（精确，循环点无填充静音）
    reg        dir_ok;            // 目录有效
    reg        dir_tried;         // 至少尝试过一次（trk_bad 才有意义）
    reg [23:0] retry;             // 目录读失败后的重试间隔计数

    wire [15:0] word_le = {s_data[7:0], s_data[15:8]};   // SPI 先到的字节在高位

    wire [31:0] cur_base = tbase[tidx];
    wire [31:0] cur_len  = tlen[tidx];

    integer k;

    always @(posedge clk_sd or posedge rst) begin
        if (rst) begin
            st        <= S_DREQ;
            s_req     <= 1'b0;
            s_sec     <= 32'd0;
            sec_cnt   <= 32'd0;
            wcnt      <= 9'd0;
            bsync     <= 1'b0;
            dir_ok    <= 1'b0;
            dir_tried <= 1'b0;
            retry     <= 24'd0;
            for (k = 0; k < 4; k = k + 1) begin
                tbase[k] <= 32'd0;
                tlen[k]  <= 32'd0;
            end
        end else begin
            case (st)
                // ---------------- 读目录扇区 ----------------
                S_DREQ: begin
                    s_req <= 1'b1;
                    s_sec <= DIR_SEC[31:0];
                    wcnt  <= 9'd0;
                    bsync <= 1'b0;
                    st    <= S_DRCV;
                end

                S_DRCV: begin
                    if (s_busy) bsync <= 1'b1;
                    if (bsync && s_val) begin
                        if (wcnt < 9'd20) dw[wcnt[4:0]] <= word_le;
                        if (wcnt == 9'd255) begin
                            wcnt  <= 9'd0;
                            s_req <= 1'b0;
                            bsync <= 1'b0;
                            st    <= S_DEND;
                        end else wcnt <= wcnt + 9'd1;
                    end
                end

                S_DEND: begin
                    // 等 busy 真正落下，再判 magic
                    if (!s_busy) begin
                        dir_tried <= 1'b1;
                        if ((dw[0] == MAG0) && (dw[1] == MAG1)) begin
                            dir_ok <= 1'b1;
                            retry  <= 24'd0;
                            for (k = 0; k < 4; k = k + 1) begin
                                tbase[k] <= {dw[4*k+5], dw[4*k+4]};
                                tlen[k]  <= {dw[4*k+7], dw[4*k+6]};
                            end
                        end else begin
                            dir_ok <= 1'b0;
                            retry  <= 24'd0;
                        end
                        st <= S_IDLE;
                    end
                end

                // ---------------- 正常播放 ----------------
                S_IDLE: begin
                    s_req <= 1'b0;
                    if (dir_ok) begin
                        if (en && (cur_len != 32'd0)) begin
                            sec_cnt <= 32'd0;
                            s_sec   <= cur_base;
                            wcnt    <= 9'd0;
                            bsync   <= 1'b0;
                            s_req   <= 1'b1;
                            st      <= S_REQ;
                        end
                    end else if (retry == 24'hFFFFFF) begin
                        st <= S_DREQ;          // 约 0.67 秒后重试读目录
                    end else
                        retry <= retry + 24'd1;
                end

                S_REQ: begin
                    if (s_busy) bsync <= 1'b1;
                    if (bsync && s_val) begin
                        if (wcnt == 9'd255) begin
                            wcnt  <= 9'd0;
                            s_req <= 1'b0;
                            bsync <= 1'b0;
                            st    <= S_NEXT;
                        end else
                            wcnt <= wcnt + 9'd1;
                    end
                end

                S_NEXT: begin
                    s_req <= 1'b0;
                    // FIFO 快满就先别读（留 324 字余量 > 一整个扇区），
                    // 否则写不进去的采样会被静默丢掉
                    if (!s_busy && (fifo_used < 11'd700)) begin
                        if (sec_cnt + 32'd1 >= cur_len) begin
                            sec_cnt <= 32'd0;
                            s_sec   <= cur_base;              // 循环
                        end else begin
                            sec_cnt <= sec_cnt + 32'd1;
                            s_sec   <= cur_base + sec_cnt + 32'd1;
                        end
                        s_req <= 1'b1;
                        st    <= S_REQ;
                    end
                end

                default: st <= S_IDLE;
            endcase

            // 切曲 / 关闭：只中断**正在进行的音频扇区**。
            //   ★ 不能无条件把 st 拉回 S_IDLE：上电时 en 还是 0（track 要同步两级），
            //     那样会连目录都读不到，然后卡在 S_IDLE 等 0.67 秒重试。
            //     目录与曲目无关，任何情况下都不打断目录读。
            if ((trk_chg || !en) && ((st == S_REQ) || (st == S_NEXT))) begin
                st      <= S_IDLE;
                s_req   <= 1'b0;
                sec_cnt <= 32'd0;
                wcnt    <= 9'd0;
                bsync   <= 1'b0;
            end
        end
    end

    // ==================================================================
    // 3) 异步 FIFO：SD 域写、像素域读
    // ==================================================================
    reg         fifo_rd;
    // 每个字就是一个采样（裸 PCM，没有头要跳过）。
    // bsync 必不可少：只有“本扇区 busy 起来之后”收到的字才算数据，
    // 否则上一扇区尾巴/仲裁切主时残留的字会被写进 FIFO，整条流从此错位。
    wire        fifo_wr = s_val & bsync & en & dir_ok & ~fifo_full;

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
    reg [11:0]        starve;      // 连续多少次节拍没拿到数据

    // 音量 0..10 -> 9 位增益（与 tone_gen 同一张表）
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

    assign level   = mag[15:7];                     // 0..255
    assign trk_bad = dir_tried & ~dir_ok;           // 卡上目录无效
    assign dbg_hdr = dw[0];                         // 数码管：目录扇区第一个字
                                                    //   444D = "MD"（正常，不该看到）
                                                    //   424D = "BM"（读到的是图片 -> 卡不对）
                                                    //   0000 = 目录扇区是空的（旧镜像/没写进去）

    // ==================================================================
    // 5) 输出：aud_valid 严格 48kHz 连续
    //    HDMI 核按 valid 采样，一旦少给一拍，接收端音频 PLL 会抖 -> 爆音。
    //    FIFO 见底时保持上一个采样；但长期（>80ms）没数据就归零，
    //    否则电平表会一直挂着一根不动的柱子。
    // ==================================================================
    reg tick_d, tick_d2, tick_d3;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            samp      <= 16'sd0;
            starve    <= 12'd0;
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

            if (fifo_rvld) begin
                samp   <= $signed(fifo_dout);
                starve <= 12'd0;
            end else if (tick) begin
                if (starve != 12'hFFF) starve <= starve + 12'd1;
                else                   samp   <= 16'sd0;
            end

            // aud_valid 比 tick 晚 3 拍：此时 samp 已经是本次弹出的采样，
            // 与 aud_left 严格同拍（第 k 个 valid 就是文件第 k 个采样）
            aud_valid <= tick_d3;
            aud_left  <= en ? scaled : 24'd0;
            aud_right <= en ? scaled : 24'd0;
        end
    end

endmodule
