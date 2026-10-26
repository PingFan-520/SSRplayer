// ============================================================================
//  audio_meter.v —— 音频电平可视化（32 柱瀑布图 + 纵向彩虹渐变）
//
//  参考 设计参考文档/Music-Spectrum-main 的做法（FFT + 峰值衰减 + 彩虹色），
//  本设计没有 FFT（音源是单音，做出来也只是一根柱子），但把它"好看"的
//  几个要素照搬了：
//    ① **逐帧刷新**：每帧只推一列，帧内画面绝对稳定。
//       上一版每 512 拍推一列（一帧推 3 列、横向跳 24 像素），看起来就是"一直在闪"
//    ② **纵向彩虹渐变**（红->橙->黄->绿->青->蓝），像真正的频谱仪
//    ③ **峰值保持**：每列取这一帧内的峰值，而不是瞬时值
//
//  几何：x 500..755（32 列 x 8 px），y 620..715（高 96）
//        位于图片区（y 120..599）与菜单面板（y 110..609）下方的空白带，
//        不遮挡任何内容。
//
//  输出是纯组合的，但路径很短（32:1 mux + 比较 + 颜色 case）。
//  上一版在输出后又串了一级 alpha_blend（3 个 8x4 乘法器），与本级 mux 叠加
//  把像素通路拉长；现在改成**直接选择**（下方是黑底，不需要混合），
//  少了一整级乘法，也消除了"画面边缘撕裂"的隐患。
// ============================================================================
`timescale 1ns / 1ps

module audio_meter #(
    parameter integer X0   = 128,     // 面板左上角（比图片框更宽，铺满 1024）
    parameter integer Y0   = 468,     // 叠在图片下部
    parameter integer BARW = 8,       // 每根柱子占 8 像素（**5 实 + 3 空**，更细）
    parameter integer NBAR = 128,     // 128 列 x 8 = 1024 宽
    parameter integer MAXH = 112      // 柱区高度（像素）
)(
    input  wire        clk,
    input  wire        rst,

    input  wire [11:0] x,             // 已与视频对齐的坐标
    input  wire [11:0] y,
    input  wire        frame_start,   // 帧首单拍：只在此时推进一列
    input  wire [7:0]  level,         // 音频包络（含音量），48kHz 更新
    input  wire        enable,        // 0 = 不显示

    output reg         on,
    output reg  [23:0] rgb,
    output reg  [3:0]  alpha
);

    // ------------------------------------------------------------------
    // 柱子历史：每帧推一列，取这一帧内的峰值
    // ------------------------------------------------------------------
    reg [7:0] bars [0:NBAR-1];
    reg [7:0] peak;
    reg       warm = 1'b0;         // 0 = 还没填过（上电/换曲/静音后第一次推列）
    reg [5:0] quiet;               // 连续静音帧数（到 45 帧 = 1.5s 认为换曲/停播）

    integer i;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            peak <= 8'd0;
            for (i = 0; i < NBAR; i = i + 1)
                bars[i] <= 8'd0;
        end else begin
            if (level > peak)
                peak <= level;

            // 连续 6 帧没声音就重新进入"未预热"状态：
            // 换曲/暂停后再出声时会重新把 128 列铺满，而不是从右边慢慢长
            if (peak == 8'd0 && level == 8'd0) begin
                if (quiet != 6'd45) quiet <= quiet + 6'd1;
            end else begin
                quiet <= 6'd0;
            end

            if (frame_start) begin
                if (quiet >= 6'd45) warm <= 1'b0;
                if (!warm) begin
                    // 上电/换曲后的第一列：把 128 列全部填成当前值。
                    // 否则瀑布图要从右边慢慢长过来，128 列要 4 秒才铺满，
                    // 看起来就像"只有右侧有柱子"。
                    for (i = 0; i < NBAR; i = i + 1)
                        bars[i] <= peak;
                    warm <= 1'b1;
                end else begin
                    for (i = NBAR - 1; i > 0; i = i - 1)
                        bars[i] <= bars[i-1];
                    bars[0] <= peak;
                end
                peak <= 8'd0;
            end
        end
    end

    // ------------------------------------------------------------------
    // 逐像素判断
    // ------------------------------------------------------------------
    localparam integer XW = NBAR * BARW;
    localparam integer BW = $clog2(NBAR);     // 128 -> 7（BARW=8 时正好是 dx[9:3]）

    wire in_rect = enable &&
                   (x >= X0[11:0]) && (x < (X0 + XW)) &&
                   (y >= Y0[11:0]) && (y < (Y0 + MAXH));

    wire [11:0] dx = x - X0[11:0];
    wire [11:0] dy = y - Y0[11:0];

    // bars[0] 是最新的一列，画在最右边（示波器/瀑布图习惯）
    // BARW=8 -> 柱索引 = dx/8（移位）；柱内 5 实 3 空 -> 每根更细
    //
    // ★ 索引的基准必须跟 NBAR 走，不能写死 127：
    //   上一版上层实例化时 NBAR=80，而这里写死 `7'd127 - ...`，
    //   bi 会算到 48..127，对只有 80 项的 bars[] 越界读 ——
    //   综合后取到的是无效数据，上板就只看得到一部分柱子
    //   （"音频条只显示在图片右下角"）。
    //   现在用 (NBAR-1) 推导，并且加一层越界钳位兜底。
    wire [BW-1:0] cidx = dx[BW+2:3];              // dx / 8 = 第几列
    wire [BW-1:0] bi   = (cidx > (NBAR-1)) ? (NBAR-1) : ((NBAR-1) - cidx);
    wire          ingap = (dx[2:0] >= 3'd5);

    wire [7:0]  lv = bars[bi];
    // 高度：0.625 x level（略微放大低电平，别让小声时柱子趴在地上）
    wire [8:0]  hh  = {1'b0, lv[7:1]} + {2'b00, lv[7:3]};
    wire [8:0]  hcl = (hh > MAXH[8:0]) ? MAXH[8:0] : hh;
    wire [11:0] thr = MAXH[11:0] - {3'b000, hcl};

    wire filled = in_rect && ~ingap && (dy >= thr);

    // ------------------------------------------------------------------
    // 纵向彩虹渐变：14 级（每 8 像素一级，正好是 dy[6:3]，纯移位不用除法）
    //   顶部红/玫红 -> 橙 -> 黄 -> 绿 -> 青 -> 蓝 -> 紫（底部）
    //   级别越多，渐变越细腻（参考 Music-Spectrum 的 128 级彩虹表思路，
    //   这里只用 14 级 case，零 ROM 零乘法器）
    // ------------------------------------------------------------------
    wire [3:0] zc = dy[6:3];

    reg [23:0] col;

    always @(*) begin
        case (zc)
            4'd0:  col = 24'hFF1040;   // 玫红
            4'd1:  col = 24'hFF2A18;   // 红
            4'd2:  col = 24'hFF5A10;   // 朱红
            4'd3:  col = 24'hFF8C1A;   // 橙
            4'd4:  col = 24'hFFC01E;   // 琥珀
            4'd5:  col = 24'hFFE81E;   // 黄
            4'd6:  col = 24'hC8F020;   // 黄绿
            4'd7:  col = 24'h3CE03C;   // 绿
            4'd8:  col = 24'h20E890;   // 青绿
            4'd9:  col = 24'h26D2F0;   // 青
            4'd10: col = 24'h2AA0FF;   // 天蓝
            4'd11: col = 24'h3355FF;   // 蓝
            4'd12: col = 24'h7038F0;   // 靛
            default: col = 24'hA050FF; // 紫
        endcase
    end

    // 输出寄存一拍：上层用 xd3/yd3（比视频早一拍）算，寄存后正好与视频对齐。
    // 这样"32:1 mux + 比较 + 颜色 case"不再和菜单混合串在一条组合路径上，
    // 像素通路比加电平表之前还短（上板"画面撕裂"的一半原因是这条路径太长）。
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            on    <= 1'b0;
            rgb   <= 24'd0;
            alpha <= 4'd0;
        end else begin
            on    <= filled;
            rgb   <= col;
            alpha <= filled ? 4'd8 : 4'd0;
        end
    end

endmodule
