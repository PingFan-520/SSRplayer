// ============================================================================
//  wav_player.v —— 从 FAT32 卡播放 WAV（PCM 16bit / 单声道 / 48kHz）
//
//  ★ 2026-10-27 改版：不再读"自制目录扇区"，改成 FAT32 文件表 + 簇链
//
//  流程：
//    1) 曲目变化时向 fat_tbl 要第 (56 + track - 1) 条记录（起始簇 / 大小 / 名字）
//    2) 读文件第 0 个扇区，在头里找 "data" 块，拿到数据偏移和长度
//       （ffmpeg 会在 RIFF 里插 LIST 块，写死 44 字节必错 —— 这里按标签找）
//    3) 按簇链连续读，跳过头部，每 16bit 一个字 = 一个采样，写进异步 FIFO
//    4) 播到 data 末尾回到开头循环
//
//  结构：
//    SD 域(25MHz)：文件表 -> 头解析 -> 簇链读 -> FIFO
//    像素域(37.5MHz)：48kHz 节拍取一个采样 -> 乘音量 -> 24bit 送 HDMI
//
//  FIFO 1024 深 ≈ 21ms：换图时 SD 总线被图片占用也能兜住。
// ============================================================================
`timescale 1ns / 1ps

module wav_player #(
    parameter integer TRK_NUM    = 6,
    parameter integer CLK_HZ     = 37_500_000,
    parameter integer SAMPLE_HZ  = 48_000
)(
    input  wire        clk,          // 37.5MHz 像素域（消费侧）
    input  wire        clk_sd,       // 25MHz（SD 侧）
    input  wire        rst,          // 高有效

    input  wire [2:0]  track,        // 1..TRK_NUM 播放；0 = 关闭
    input  wire [3:0]  vol,          // 0..10

    // ---- FAT 布局 ----
    input  wire [31:0] fat_lba,
    input  wire [31:0] data_lba,
    input  wire [3:0]  spc_log2,

    // ---- 文件表 ----
    output reg         tbl_req,
    output reg  [5:0]  tbl_rec,
    input  wire        tbl_done,
    input  wire [127:0] tbl_data,

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
    output wire        trk_bad,      // 1 = 当前曲目无效（文件读不到）
    output reg  [63:0] trk_name,     // 当前曲目的 8.3 名字（SD 域，稳定）
    output reg  [15:0] dbg_hdr       // 文件头第一个字（诊断）
);

    // ==================================================================
    // 1) track 同步到 SD 域
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

    // ==================================================================
    // 2) SD 域状态机
    // ==================================================================
    localparam [3:0] S_IDLE = 4'd0,
                     S_TBL  = 4'd1,
                     S_H0   = 4'd2,   // 读文件头扇区
                     S_H1   = 4'd3,
                     S_H2   = 4'd4,   // 收 512 字节并找 "data"
                     S_H3   = 4'd5,   // 等 busy 落下，算数据区间
                     S_REQ  = 4'd6,   // 数据扇区
                     S_NEXT = 4'd7,
                     S_F0   = 4'd8,   // FAT 扇区
                     S_F1   = 4'd9,
                     S_F2   = 4'd10;

    // FIFO 状态
    wire        fifo_full, fifo_empty, fifo_rvld;
    wire [15:0] fifo_dout;
    wire [10:0] fifo_used;

    reg [3:0]  st;
    reg        bsync;
    reg [9:0]  bcnt;
    reg [8:0]  wcnt;
    reg        pend_v;
    reg [7:0]  pend;

    reg [31:0] cur_clus;
    reg [7:0]  sec_in;
    reg [31:0] fsize;          // 文件总字节数
    reg [31:0] foff;           // FAT 扇区内偏移
    reg [31:0] nxt_clus;
    reg        fav;

    reg [31:0] data_len;       // 音频数据字节数
    reg [31:0] words_left;     // 还要播多少个 16bit 采样
    reg        got_tag;
    reg [1:0]  sz_k;
    reg [31:0] tag_sr;
    reg [31:0] hdr_sz;
    reg [31:0] hdr_off;

    reg        dir_ok;         // 当前曲目有效
    reg        dir_tried;
    reg        en_d;
    reg [23:0] retry;

    wire [15:0] word_le = {s_data[7:0], s_data[15:8]};   // SPI 先到的字节在高位

    wire [31:0] cl_off = (cur_clus - 32'd2) << spc_log2;
    wire        byte_en = s_val | pend_v;
    wire [7:0]  byte_d  = s_val ? s_data[15:8] : pend;

    reg  [8:0]  skip_cnt;                              // 数据区开头要跳过的字数
    wire        fifo_wr_ok = s_val & bsync & en & dir_ok & (st == S_REQ) & ~fifo_full;
    wire        fifo_wr    = fifo_wr_ok & (skip_cnt == 9'd0);

    always @(posedge clk_sd or posedge rst) begin
        if (rst) begin
            st        <= S_IDLE;
            s_req     <= 1'b0;
            s_sec     <= 32'd0;
            bsync     <= 1'b0;
            bcnt      <= 10'd0;
            wcnt      <= 9'd0;
            pend_v    <= 1'b0;
            pend      <= 8'd0;
            cur_clus  <= 32'd0;
            sec_in    <= 8'd0;
            fsize     <= 32'd0;
            foff      <= 32'd0;
            nxt_clus  <= 32'd0;
            fav       <= 1'b0;
            data_len  <= 32'd0;
            words_left<= 32'd0;
            got_tag   <= 1'b0;
            sz_k      <= 2'd0;
            tag_sr    <= 32'd0;
            hdr_sz    <= 32'd0;
            hdr_off   <= 32'd44;
            dir_ok    <= 1'b0;
            dir_tried <= 1'b0;
            en_d      <= 1'b0;
            retry     <= 24'd0;
            tbl_req   <= 1'b0;
            tbl_rec   <= 6'd56;
            skip_cnt  <= 9'd22;
            trk_name  <= 64'd0;
            dbg_hdr   <= 16'd0;
        end else begin
            en_d <= en;

            // 头部跳过计数
            if (st == S_H3)
                skip_cnt <= got_tag ? hdr_off[9:1] : 9'd22;
            else if (st == S_NEXT && words_left == 32'd0)
                skip_cnt <= got_tag ? hdr_off[9:1] : 9'd22;
            else if (fifo_wr_ok && (skip_cnt != 9'd0))
                skip_cnt <= skip_cnt - 9'd1;

            // 采样计数（决定循环点）
            if (fifo_wr && (words_left != 32'd0))
                words_left <= words_left - 32'd1;

            // 16bit -> 2 字节
            if (s_val) begin
                pend   <= s_data[7:0];
                pend_v <= 1'b1;
            end else if (pend_v) begin
                pend_v <= 1'b0;
            end

            case (st)
                // ---------------- 取文件表 ----------------
                S_IDLE: begin
                    s_req <= 1'b0;
                    if (en && (trk_chg || !en_d || !dir_tried)) begin
                        tbl_rec <= 6'd56 + {3'd0, trk_s2} - 6'd1;
                        tbl_req <= 1'b1;
                        st      <= S_TBL;
                    end
                end

                S_TBL: begin
                    if (tbl_done) begin
                        tbl_req   <= 1'b0;
                        dir_tried <= 1'b1;
                        cur_clus  <= tbl_data[31:0];
                        fsize     <= tbl_data[63:32];
                        trk_name  <= tbl_data[127:64];
                        sec_in    <= 8'd0;
                        bcnt      <= 10'd0;
                        bsync     <= 1'b0;
                        if ((tbl_data[31:0] < 32'd2) || (tbl_data[31:0] >= 32'h0FFFFFF8) ||
                            (tbl_data[63:32] < 32'd64)) begin
                            dir_ok <= 1'b0;
                            st     <= S_IDLE;          // 无效曲目：静音
                        end else begin
                            dir_ok <= 1'b1;
                            st     <= S_H0;
                        end
                    end
                end

                // ---------------- 读文件头，找 data 块 ----------------
                S_H0: begin
                    // ★ 等上一位使用者的 busy 落干净再发（换曲时上一条还在收尾，
                    //   否则会把尾巴当成自己的传输、撤请求后永远等不到数据）
                    if (!s_busy) begin
                        s_sec <= data_lba + cl_off;
                        s_req <= 1'b1;
                        bcnt  <= 10'd0;
                        bsync <= 1'b0;
                        got_tag <= 1'b0;
                        sz_k    <= 2'd0;
                        tag_sr  <= 32'd0;
                        st    <= S_H1;
                    end
                end

                S_H1: begin
                    if (s_busy) begin
                        bsync <= 1'b1;
                        s_req <= 1'b0;            // ★ busy 一起来就撤，避免重复授权
                        st    <= S_H2;
                    end
                end

                S_H2: begin
                    if (bsync && byte_en) begin
                        if (bcnt == 10'd0) dbg_hdr[7:0]  <= byte_d;
                        if (bcnt == 10'd1) dbg_hdr[15:8] <= byte_d;
                        // 逐字节匹配 "data"
                        tag_sr <= {tag_sr[23:0], byte_d};
                        if (sz_k != 2'd0) begin
                            case (sz_k)
                                2'd1: hdr_sz[7:0]   <= byte_d;
                                2'd2: hdr_sz[15:8]  <= byte_d;
                                2'd3: hdr_sz[23:16] <= byte_d;
                            endcase
                            if (sz_k == 2'd3) sz_k <= 2'd0;
                            else              sz_k <= sz_k + 2'd1;
                        end else if ({tag_sr[23:0], byte_d} == 32'h64617461) begin
                            // 'd''a''t''a' 刚凑齐：后面 4 字节是长度
                            hdr_off <= {22'd0, bcnt} + 32'd5;   // 'd' 位置 + 8
                            hdr_sz  <= 32'd0;
                            sz_k    <= 2'd1;
                            got_tag <= 1'b1;
                        end
                        bcnt <= bcnt + 10'd1;
                        if (bcnt == 10'd511) begin
                            bcnt  <= 10'd0;
                            bsync <= 1'b0;
                            s_req <= 1'b0;
                            st    <= S_H3;
                        end
                    end
                end

                S_H3: begin
                    if (!s_busy) begin
                        data_len <= got_tag ? hdr_sz  : (fsize - 32'd44);
                        if (!got_tag || (hdr_sz == 32'd0) ||
                            (hdr_off + 32'd8 > fsize)) begin
                            // 头里没有 data 块：退回"44 字节头 + 剩余全是数据"
                            data_len <= (fsize > 32'd44) ? (fsize - 32'd44) : 32'd0;
                        end
                        words_left <= got_tag ? (hdr_sz >> 1) : ((fsize - 32'd44) >> 1);
                        cur_clus   <= tbl_data[31:0];
                        sec_in     <= 8'd0;
                        wcnt       <= 9'd0;
                        bsync      <= 1'b0;
                        st         <= S_REQ;
                        s_req      <= 1'b1;
                        s_sec      <= data_lba + cl_off;
                    end
                end

                // ---------------- 数据流 ----------------
                S_REQ: begin
                    if (s_busy) bsync <= 1'b1;
                    if (bsync && s_val) begin
                        if (wcnt == 9'd255) begin
                            wcnt  <= 9'd0;
                            bsync <= 1'b0;
                            s_req <= 1'b0;
                            st    <= S_NEXT;
                        end else
                            wcnt <= wcnt + 9'd1;
                    end
                end

                S_NEXT: begin
                    s_req <= 1'b0;
                    if (!s_busy && (fifo_used < 11'd700)) begin
                        if (words_left == 32'd0) begin
                            // 循环：回到数据区开头
                            cur_clus  <= tbl_data[31:0];
                            sec_in    <= 8'd0;
                            words_left<= (got_tag ? (hdr_sz >> 1) : (data_len >> 1));
                            s_sec     <= data_lba + ((tbl_data[31:0] - 32'd2) << spc_log2);
                            s_req     <= 1'b1;
                            st        <= S_REQ;
                        end else if (sec_in + 8'd1 < (8'd1 << spc_log2)) begin
                            sec_in <= sec_in + 8'd1;
                            s_sec  <= data_lba + cl_off + {22'd0, sec_in} + 32'd1;
                            s_req  <= 1'b1;
                            st     <= S_REQ;
                        end else begin
                            foff <= {24'd0, cur_clus[6:0]} << 2;
                            st   <= S_F0;
                        end
                    end
                end

                S_F0: begin
                    s_sec <= fat_lba + {23'd0, cur_clus[31:7]};
                    s_req <= 1'b1;
                    bcnt  <= 10'd0;
                    bsync <= 1'b0;
                    nxt_clus <= 32'hFFFFFFFF;
                    st    <= S_F1;
                end

                S_F1: begin
                    if (s_busy) begin
                        bsync <= 1'b1;
                        s_req <= 1'b0;
                        st    <= S_F2;
                    end
                end

                S_F2: begin
                    if (fav) begin
                        fav <= 1'b0;
                        if ((nxt_clus >= 32'h0FFFFFF8) || (nxt_clus < 32'd2)) begin
                            // 链断了：从当前簇重来（不至于停播）
                            cur_clus <= tbl_data[31:0];
                            sec_in   <= 8'd0;
                            s_sec    <= data_lba + ((tbl_data[31:0] - 32'd2) << spc_log2);
                        end else begin
                            cur_clus <= nxt_clus;
                            sec_in   <= 8'd0;
                            s_sec    <= data_lba + ((nxt_clus - 32'd2) << spc_log2);
                        end
                        s_req <= 1'b1;
                        st    <= S_REQ;
                    end
                    if (bsync && byte_en) begin
                        if (bcnt == foff[9:0])         nxt_clus[7:0]   <= byte_d;
                        if (bcnt == foff[9:0] + 10'd1) nxt_clus[15:8]  <= byte_d;
                        if (bcnt == foff[9:0] + 10'd2) nxt_clus[23:16] <= byte_d;
                        if (bcnt == foff[9:0] + 10'd3) nxt_clus[31:24] <= byte_d;
                        bcnt <= bcnt + 10'd1;
                        if (bcnt == 10'd511) begin
                            bcnt  <= 10'd0;
                            bsync <= 1'b0;
                            s_req <= 1'b0;
                            fav   <= 1'b1;
                        end
                    end
                end

                default: st <= S_IDLE;
            endcase

            // 切曲 / 关闭：只允许打断数据流，不打断表/头解析
            if ((trk_chg || !en) && ((st == S_REQ) || (st == S_NEXT) ||
                                     (st == S_F0) || (st == S_F1) || (st == S_F2))) begin
                st       <= S_IDLE;
                s_req    <= 1'b0;
                bsync    <= 1'b0;
                wcnt     <= 9'd0;
                dir_ok   <= 1'b0;
                dir_tried<= 1'b0;
            end
        end
    end

    // ==================================================================
    // 3) FIFO 写入：跳过 WAV 头
    // ==================================================================
    reg         fifo_rd;

    afifo #(.DW(16), .AW(10)) u_fifo (
        .clk_w(clk_sd), .clk_r(clk),
        .aclr(rst | trk_chg),
        .wr_en(fifo_wr), .wr_data(word_le), .wr_full(fifo_full),
        .rd_en(fifo_rd), .rd_data(fifo_dout), .rd_empty(fifo_empty),
        .rd_valid(fifo_rvld), .wr_used(fifo_used)
    );

    assign trk_bad = dir_tried & ~dir_ok;

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
    reg [11:0]        starve;

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

    wire signed [24:0] prod   = samp * $signed({1'b0, vol_g});
    wire signed [15:0] g16    = prod[23:8];
    wire        [23:0] scaled = { {2{g16[15]}}, g16, 8'd0 };
    wire        [15:0] mag    = g16[15] ? (~g16 + 16'd1) : g16;

    assign level = mag[15:7];

    // ==================================================================
    // 5) 输出：aud_valid 严格 48kHz 连续
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

            aud_valid <= tick_d3;
            aud_left  <= en ? scaled : 24'd0;
            aud_right <= en ? scaled : 24'd0;
        end
    end

endmodule
