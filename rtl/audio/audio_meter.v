// ============================================================================
//  audio_meter.v —— 音频电平可视化（32 柱频谱条）
//
//  赛题扩展要求 (5) "音频可视化表现：结合音频数据生成频谱或波形显示"。
//
//  做法：
//    - 每 512 个音频采样（48kHz，即 10.7ms）把这段时间的**峰值**推进一根柱子，
//      32 根柱子构成一个 0.34 秒的滑动历史 —— 视觉上就是"声音在跳动"。
//     - 柱子画在图片区下方的黑底区域（y 624..711），不遮挡画面和菜单。
//     - 柱子颜色按高度分三段：底部绿、中部黄、顶部红（像 VU 表）。
//     - 纯比较器 + 32x8 移位寄存器，不占 BRAM/DSP/乘法器。
//
//  为什么不做真正的频谱：FFT 要几百个乘法器和一堆 BRAM；
//  而且本设计的音源是单音（每步一个频率），做出来也只会有一根柱子。
//  用"包络峰值历史"既能真实反映音量/节奏，又便宜得多。
// ============================================================================
`timescale 1ns / 1ps

module audio_meter #(
    parameter integer X0   = 480,     // 面板左上角（屏幕坐标）
    parameter integer Y0   = 624,
    parameter integer BARW = 8,       // 每根柱子占 8 像素（6 实 + 2 空）
    parameter integer NBAR = 32,      // 柱子数
    parameter integer MAXH = 88       // 柱区高度（像素）
)(
    input  wire        clk,
    input  wire        rst,

    input  wire [11:0] x,             // 已与视频对齐的坐标
    input  wire [11:0] y,
    input  wire [7:0]  level,         // 音频包络（含音量），48kHz 更新
    input  wire        enable,        // 0 = 不显示

    output reg         on,
    output reg  [23:0] rgb,
    output reg  [3:0]  alpha
);

    // ------------------------------------------------------------------
    // 柱子历史：每 512 采样推一列
    // ------------------------------------------------------------------
    reg [7:0] bars [0:NBAR-1];
    reg [7:0] peak;
    reg [8:0] cnt;

    integer i;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            peak <= 8'd0;
            cnt  <= 9'd0;
            for (i = 0; i < NBAR; i = i + 1)
                bars[i] <= 8'd0;
        end else begin
            if (level > peak)
                peak <= level;

            if (cnt == 9'd511) begin
                for (i = NBAR - 1; i > 0; i = i - 1)
                    bars[i] <= bars[i-1];
                bars[0] <= peak;
                peak    <= 8'd0;
                cnt     <= 9'd0;
            end else begin
                cnt <= cnt + 9'd1;
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

    // BARW=8 -> 柱索引取 dx[7:3]；柱内 2 像素间隙不画
    // bars[0] 是最新的一列，画在最右边（和示波器/频谱仪的习惯一致）
    wire [4:0]  bi = 5'd31 - dx[7:3];
    wire        ingap = (dx[2:0] >= 3'd6);

    wire [7:0]  lv = bars[bi];
    wire [8:0]  hh = {1'b0, lv[7:1]};                 // 0..127
    wire [8:0]  hcl = (hh > MAXH[8:0]) ? MAXH[8:0] : hh;
    wire [11:0] thr = MAXH[11:0] - {3'b000, hcl};

    wire filled = in_rect && ~ingap && (dy >= thr);

    // 颜色按柱内高度分段（顶部红、中部黄、底部绿）
    wire is_red    = (dy < MAXH[11:0] / 8);
    wire is_yellow = (dy < (MAXH[11:0] * 2) / 5);

    always @(*) begin
        on    = filled;
        alpha = filled ? 4'd7 : 4'd0;
        rgb   = is_red    ? 24'hFF3020 :
                is_yellow ? 24'hFFD020 :
                            24'h20E040;
    end

endmodule
