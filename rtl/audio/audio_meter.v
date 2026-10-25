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
    parameter integer X0   = 320,     // 面板左上角 = 图片框左边界
    parameter integer Y0   = 468,     // 叠在图片下部
    parameter integer BARW = 8,       // 每根柱子 8 像素（7 实 + 1 空）-> 更窄
    parameter integer NBAR = 80,      // 80 列 x 8 = 640，正好与图片同宽
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

    integer i;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            peak <= 8'd0;
            for (i = 0; i < NBAR; i = i + 1)
                bars[i] <= 8'd0;
        end else begin
            if (level > peak)
                peak <= level;

            if (frame_start) begin
                for (i = NBAR - 1; i > 0; i = i - 1)
                    bars[i] <= bars[i-1];
                bars[0] <= peak;
                peak    <= 8'd0;
            end
        end
    end

    // ------------------------------------------------------------------
    // 逐像素判断
    // ------------------------------------------------------------------
    localparam integer XW = NBAR * BARW;

    wire in_rect = enable &&
                   (x >= X0[11:0]) && (x < (X0 + XW)) &&
                   (y >= Y0[11:0]) && (y < (Y0 + MAXH));

    wire [11:0] dx = x - X0[11:0];
    wire [11:0] dy = y - Y0[11:0];

    // bars[0] 是最新的一列，画在最右边（示波器/瀑布图习惯）
    // BARW=8 -> 柱索引 = dx/8（移位，无除法器），柱内 1 像素间隙（dx[2:0]==7）
    wire [6:0]  bi    = 7'd79 - dx[9:3];
    wire        ingap = (dx[2:0] == 3'd7);

    wire [7:0]  lv = bars[bi];
    // 高度：0.625 x level（略微放大低电平，别让小声时柱子趴在地上）
    wire [8:0]  hh  = {1'b0, lv[7:1]} + {2'b00, lv[7:3]};
    wire [8:0]  hcl = (hh > MAXH[8:0]) ? MAXH[8:0] : hh;
    wire [11:0] thr = MAXH[11:0] - {3'b000, hcl};

    wire filled = in_rect && ~ingap && (dy >= thr);

    // ------------------------------------------------------------------
    // 纵向彩虹渐变：红 -> 橙 -> 黄 -> 绿 -> 青 -> 蓝
    //   （顶部红、底部蓝，频谱仪最常见的配色）
    // ------------------------------------------------------------------
    localparam [11:0] Z1 = (MAXH * 16) / 100;   // 16%
    localparam [11:0] Z2 = (MAXH * 32) / 100;   // 32%
    localparam [11:0] Z3 = (MAXH * 48) / 100;   // 48%
    localparam [11:0] Z4 = (MAXH * 66) / 100;   // 66%
    localparam [11:0] Z5 = (MAXH * 84) / 100;   // 84%

    reg [23:0] col;

    always @(*) begin
        if      (dy < Z1) col = 24'hFF2A18;     // 红
        else if (dy < Z2) col = 24'hFF8C1A;     // 橙
        else if (dy < Z3) col = 24'hFFE01E;     // 黄
        else if (dy < Z4) col = 24'h3CE03C;     // 绿
        else if (dy < Z5) col = 24'h26D2F0;     // 青
        else              col = 24'h3355FF;     // 蓝
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
