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

    localparam integer XW = NBAR * BARW;
    localparam integer BW = $clog2(NBAR);     // 128 -> 7（BARW=8 时正好是 dx[9:3]）

    // ------------------------------------------------------------------
    // 柱子历史：**环形缓冲 + 写指针**，不做整体移位
    //
    //  ★ 上一版是 128 个寄存器每帧整列移位（`bars[i] <= bars[i-1]`）。
    //    上板表现是"只有右半在动，左半一直停在峰值"——
    //    典型的"综合把这种整列移位映射成了 SRL/移位链，而并行读只认到一部分抽头"。
    //    改成写指针后，每帧只写 1 个单元、读地址做加法，就不再依赖工具怎么理解移位。
    //
    //    最新的一列写在 mem[wp]，下一帧 wp+1；
    //    第 c 列（0=最左、NBAR-1=最右）读 mem[wp + c]（模 NBAR）：
    //      c = NBAR-1 时地址是 wp-1 -> 正好是最新那一列（放在最右边）。
    // ------------------------------------------------------------------
    reg [7:0] hist [0:NBAR-1];
    reg [7:0] peak;                // 本帧内的峰值
    reg [BW-1:0] wp;               // 写指针
    reg [5:0] quiet;               // 连续静音拍数（饱和 45）
    reg       filling;             // 正在把整幅填成当前峰值（出声瞬间/复位后）
    reg [BW-1:0] fill_i;

    // 静音很久之后又来声音 -> 立刻把整幅铺满，免得"从右边慢慢长"看起来像坏了
    wire onset = (level != 8'd0) && (quiet >= 6'd45);

    // 落柱：某一帧正好没有声音时不要直接把柱子清成 0（那样看着像"突然消失"），
    // 而是在上一列的基础上每帧掉 8 格（30fps 下约 1 秒落到地）。
    // 这也是参考工程 FFT_decay_mapper 的"衰减保持"观感。
    localparam [7:0] DECAY = 8'd8;
    wire [BW-1:0] paddr   = wp - 1'b1;
    wire [7:0]    prev_lv = hist[paddr];
    wire [7:0]    next_lv = (peak != 8'd0) ? peak :
                            ((prev_lv > DECAY) ? (prev_lv - DECAY) : 8'd0);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            peak    <= 8'd0;
            wp      <= {BW{1'b0}};
            quiet   <= 6'd45;      // 复位后第一次出声就铺满
            filling <= 1'b0;
            fill_i  <= {BW{1'b0}};
        end else begin
            if (level > peak)
                peak <= level;

            if (level == 8'd0) begin
                if (quiet != 6'd45) quiet <= quiet + 6'd1;
            end else begin
                quiet <= 6'd0;
            end

            if (onset) begin
                filling <= 1'b1;
                fill_i  <= {BW{1'b0}};
            end else if (filling) begin
                hist[fill_i] <= (peak > level) ? peak : level;
                if (fill_i == (NBAR-1)) filling <= 1'b0;
                else                    fill_i  <= fill_i + 1'b1;
            end else if (frame_start) begin
                hist[wp] <= next_lv;       // 每帧只写一个单元（无声时按 DECAY 下落）
                wp       <= wp + 1'b1;
                peak     <= 8'd0;
            end
        end
    end

    // ------------------------------------------------------------------
    // 逐像素判断
    // ------------------------------------------------------------------

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

    // 读地址 = wp + cidx（模 NBAR）：最右列(cidx=127) 读到 wp-1 = 最新
    wire [BW-1:0] raddr = wp + cidx;
    wire [7:0]  lv = hist[raddr];
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
