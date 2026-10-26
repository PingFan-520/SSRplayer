// ============================================================================
//  audio_meter.v —— 32 段频谱柱（每根柱对应一个频段，独立跳动）
//
//  这是第三次改造，前两次的教训写在这里：
//    ① v1：每 512 采样推一列 —— 一帧推 3 列，柱子横向跳，看起来是频闪。
//    ② v2：每帧写一个"总电平"的瀑布图 —— 128 列其实是**同一个标量**的历史，
//       所以整排一起起伏，用户一眼就看出"这不是频谱"。
//    ③ 现在：柱高来自 spectrum.v 的 32 个**频段能量**（对数分布 50Hz~16kHz），
//       每段能量本来就不同 → 每根柱自然独立跳动。
//
//  几何：x 128..1151（32 段 × 32px = 1024），y 468..579（高 112）
//        每段 29 像素实 + 3 像素隙。
//  配色：纵向 14 级彩虹（dy[6:3] 直接做索引，零 ROM 零乘法器）。
//  输出寄存一拍（坐标用 xd3/yd3 提前一拍算），像素通路只有"一级混合 + 一个选择器"。
// ============================================================================
`timescale 1ns / 1ps

module audio_meter #(
    parameter integer X0   = 128,     // 面板左上角（比图片框更宽，铺满 1024）
    parameter integer Y0   = 468,     // 叠在图片下部
    parameter integer BARW = 32,      // 每根柱 32 像素（29 实 + 3 隙）
    parameter integer NBAR = 32,      // 频段数（32 x 32 = 1024 宽）
    parameter integer MAXH = 112      // 柱区高度（像素）
)(
    input  wire        clk,
    input  wire        rst,

    input  wire [11:0] x,             // 已与视频对齐的坐标
    input  wire [11:0] y,
    input  wire [NBAR*8-1:0] bars,    // 每段的显示值 0..255（低频在低位）
    input  wire        enable,        // 0 = 不显示

    output reg         on,
    output reg  [23:0] rgb,
    output reg  [3:0]  alpha
);

    localparam integer XW = NBAR * BARW;      // 1024

    wire [11:0] dx = x - X0;
    wire [11:0] dy = y - Y0;

    wire in_area = (x >= X0) && (x < X0 + XW) && (y >= Y0) && (y < Y0 + MAXH);

    // 第几段：BARW=32 -> dx[9:5]
    wire [4:0]  cidx = dx[9:5];
    wire        ingap = (dx[4:0] >= 5'd29);       // 3 像素间隙

    // 段高度：level(0..255) -> 0..MAXH
    wire [7:0]  lv = bars[{cidx, 3'b000} +: 8];
    wire [7:0]  hh = (lv > 8'd200) ? MAXH[7:0] : ((lv * 7) >> 3);

    // 顶端条：柱顶再亮 2 像素，像真正的频谱仪
    wire [7:0]  thr  = MAXH[7:0] - hh;
    wire        filled = (dy[7:0] >= thr);

    // 纵向彩虹渐变：14 级（每 8 像素一级，正好 dy[6:3]，纯移位）
    wire [3:0]  zc = dy[6:3];
    reg  [23:0] col;

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

    wire filled_ok = in_area & enable & ~ingap & filled;

    // 输出寄存一拍：上层用 xd3/yd3（比视频早一拍）算，寄存后正好与视频对齐
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            on    <= 1'b0;
            rgb   <= 24'd0;
            alpha <= 4'd0;
        end else begin
            on    <= filled_ok;
            rgb   <= col;
            alpha <= filled_ok ? 4'd8 : 4'd0;
        end
    end

endmodule

// ======================================================================
//  下面是频谱分析（原本单独一个文件；TD 命令行不会重新读取新增的源文件条目，
//  放在 audio_meter.v 里就始终能被编译到）
// ======================================================================
// ============================================================================
//  spectrum.v —— 32 段实时频谱（Goertzel 滤波器组）
//
//  为什么不用"总响度瀑布"：
//    之前的彩条画的是**同一个标量**（总电平）在不同帧的历史，
//    128 列只是它的过去，所以看起来"整排一起跳动"。
//    真正的频谱要让每根柱对应一个**频段**，各频段能量本来就不一样，
//    才会出现"每条独立跳动"。
//
//  为什么用 Goertzel 而不是 FFT：
//    · FFT 的频点是等间隔的（48k/128 = 375Hz 一格），低频全挤在一起，
//      而这个板子的音乐能量主要在 100Hz~3kHz，需要**对数**分布；
//      Goertzel 可以对任意指定频率求能量，直接做成对数频段。
//    · 不需要位反转、不需要蝶形级联和整块 RAM，控制简单得多。
//    · 资源：1 个乘法器 + 32×2 个 24bit 状态（时间复用，每采样 32 拍完成）。
//
//  算法（单频点 Goertzel）：
//      s[n] = x[n] + 2cos(w)·s[n-1] − s[n-2]
//      能量  ≈ s1² + s2²            （略去交叉项，只用于显示，单调即可）
//    每 BLOCK 个采样算一次能量，然后把状态清零重新开始。
//
//  实现要点：
//    · 32 个频段的状态放在**旋转队列**里：每次只处理队首，算完推回队尾。
//      这样不需要 32 选 1 的大 mux，也不占 RAM。
//    · 每 4 拍处理一个频段（取系数→乘→更新），一个采样 128 拍；
//      48kHz 有 781 拍可用，余量充足。
//    · 显示：视频帧首（30Hz）做一次"取大 + 衰减"，每根柱独立下落。
// ============================================================================

module spectrum #(
    parameter integer NB    = 32,      // 频段数
    parameter integer BLOCK = 1024,    // 每多少个采样算一次能量（1024/48k = 21.3ms，47Hz 分辨率）
    parameter integer DECAY = 6        // 每帧最大下落量（30fps 下约 1 秒落地）
)(
    input  wire               clk,
    input  wire               rst,
    input  wire signed [15:0] sample,        // 48kHz 单声道
    input  wire               sample_valid,
    input  wire               frame_start,   // 视频帧首
    output wire [NB*8-1:0]    bars           // 每段 0..255（低频在低位）
);

    // ---------------- 状态数组（旋转队列） ----------------
    reg signed [23:0] s1 [0:NB-1];
    reg signed [23:0] s2 [0:NB-1];
    reg        [7:0]  mag  [0:NB-1];     // 本块能量（已压成 8bit）
    reg        [7:0]  disp [0:NB-1];     // 显示值（带衰减）

    localparam [2:0] S_IDLE = 3'd0,
                     S_UA   = 3'd1,      // 取系数、发乘法
                     S_UB   = 3'd2,      // 用乘法结果更新并旋转
                     S_PA   = 3'd3,      // 块结束：算 s1^2 / s2^2 / coef*s1
                     S_PC   = 3'd5,      // 块结束：算 coef*s1*s2
                     S_PB   = 3'd4;      // 块结束：求和、压对数、清零

    reg [2:0]  st;
    reg [4:0]  bi;                 // 当前处理的频段
    // 块内 |x| 累加：整块都没有输入（静音）时直接把各段置 0。
    //   高 Q 谐振器在 24bit 定点下偶尔会出现很小的极限环（x=0 但状态不归零），
    //   听感上是"音乐停了柱子却挂住"。有输入才显示，是最简单也最不会错的判据。
    reg [23:0] xacc;
    // 去直流：减去"上一段"的平均值。
    //   ★ 一开始写的是 y = x - x_prev + y*(1-1/256) 的一极点高通，
    //     但整数下 y - (y>>>8) 在 y<256 时恒等于 y —— 永远衰减不下去，
    //     于是 xq 里留了一个固定直流，被 60Hz 那个高 Q 谐振器放大上万倍，
    //     表现就是"所有低频柱一起亮到 130 左右、音乐停了也不落"。
    //     按块减均值既彻底又只有一次减法。
    reg signed [31:0] xsum;        // 本块采样和
    reg signed [23:0] xmean;       // 上一块的均值
    reg signed [9:0]  xq;          // 当前采样（缩到 10bit，控制位宽）
    reg signed [39:0] mu1, mu2, mu3;   // 乘法结果
    reg signed [39:0] mu4;
    reg [10:0] blk;                // 块内采样计数
    reg        merging;            // 正在做显示合并
    reg        merge_req;          // 收到帧首（可能当时 FSM 正忙，先存着）
    reg [4:0]  dbi;

    localparam signed [15:0] K_DAMP = 16'sd16058;   // r^2，r=0.998 -> 极点略在单位圆内
                                                 //   ★ 必须用 r^2 做常数项，只把中间系数乘 r
                                                 //     会让极点仍在单位圆上（等于改频点），
                                                 //     量化误差会累积成低频斜坡，低频段全部爆表。

    // 去直流后的采样
    wire signed [23:0] hp_x = $signed(sample) - xmean;

    integer k;

    // ---------------- 频段系数（Q14：2cos(2*pi*f/48000)） ----------------
    // 50Hz ~ 16kHz，对数分布；高段给音乐留余量
    reg signed [15:0] coef;
    always @(*) begin
        case (bi)
            5'd0 : coef = 16'sd32439  ;   //     60 Hz
            5'd1 : coef = 16'sd32439  ;   //     72 Hz
            5'd2 : coef = 16'sd32438  ;   //     86 Hz
            5'd3 : coef = 16'sd32437  ;   //    103 Hz
            5'd4 : coef = 16'sd32436  ;   //    123 Hz
            5'd5 : coef = 16'sd32434  ;   //    148 Hz
            5'd6 : coef = 16'sd32432  ;   //    177 Hz
            5'd7 : coef = 16'sd32428  ;   //    212 Hz
            5'd8 : coef = 16'sd32422  ;   //    254 Hz
            5'd9 : coef = 16'sd32415  ;   //    304 Hz
            5'd10: coef = 16'sd32404  ;   //    364 Hz
            5'd11: coef = 16'sd32388  ;   //    435 Hz
            5'd12: coef = 16'sd32365  ;   //    521 Hz
            5'd13: coef = 16'sd32332  ;   //    624 Hz
            5'd14: coef = 16'sd32285  ;   //    748 Hz
            5'd15: coef = 16'sd32218  ;   //    895 Hz
            5'd16: coef = 16'sd32121  ;   //   1072 Hz
            5'd17: coef = 16'sd31983  ;   //   1284 Hz
            5'd18: coef = 16'sd31786  ;   //   1537 Hz
            5'd19: coef = 16'sd31503  ;   //   1841 Hz
            5'd20: coef = 16'sd31099  ;   //   2204 Hz
            5'd21: coef = 16'sd30523  ;   //   2640 Hz
            5'd22: coef = 16'sd29703  ;   //   3161 Hz
            5'd23: coef = 16'sd28539  ;   //   3785 Hz
            5'd24: coef = 16'sd26897  ;   //   4532 Hz
            5'd25: coef = 16'sd24593  ;   //   5427 Hz
            5'd26: coef = 16'sd21393  ;   //   6499 Hz
            5'd27: coef = 16'sd17015  ;   //   7782 Hz
            5'd28: coef = 16'sd11154  ;   //   9319 Hz
            5'd29: coef = 16'sd3566   ;   //  11159 Hz
            5'd30: coef = -16'sd5752  ;   //  13362 Hz
            5'd31: coef = -16'sd16220 ;   //  16000 Hz
            default: coef = 16'sd0;
        endcase
    end

    // ---------------- 能量 -> 8bit（对数压缩） ----------------
    // p 最大约 2^35；直接取高位做对数，让弱信号也能看见
    function [7:0] log8;
        input [39:0] p;
        integer i, idx, v;
        begin
            idx = 0;
            for (i = 0; i < 40; i = i + 1)
                if (p[i]) idx = i;
            if (idx <= 17) begin
                log8 = 8'd0;
            end else begin
                v = (idx - 17) * 11
                  + (p[idx-1] ? 5 : 0) + (p[idx-2] ? 3 : 0) + (p[idx-3] ? 1 : 0);
                if (v > 255) v = 255;
                log8 = v[7:0];
            end
        end
    endfunction

    // ---------------- 主状态机 ----------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            st      <= S_IDLE;
            bi      <= 5'd0;
            blk     <= 11'd0;
            xacc    <= 24'd0;
            xsum    <= 32'sd0;
            xmean   <= 24'sd0;
            xq      <= 10'sd0;
            mu1     <= 40'sd0;
            mu2     <= 40'sd0;
            mu3     <= 40'sd0;
            mu4     <= 40'sd0;
            merging   <= 1'b0;
            merge_req <= 1'b0;
            dbi       <= 5'd0;
            for (k = 0; k < NB; k = k + 1) begin
                s1[k]   <= 24'sd0;
                s2[k]   <= 24'sd0;
                mag[k]  <= 8'd0;
                disp[k] <= 8'd0;
            end
        end else begin
            // ---- 显示合并：帧首触发，32 拍做完 ----
            //   ★ 必须用 pending 标志：frame_start 只有 1 拍，如果正好落在
            //     Goertzel 处理中（一个采样要几十拍），直接判 st==S_IDLE 会丢帧，
            //     显示就冻住了（仿真里表现为柱子不衰减）。
            if (frame_start) merge_req <= 1'b1;
            if (!merging && merge_req) begin
                merging   <= 1'b1;
                merge_req <= 1'b0;
                dbi       <= 5'd0;
            end
            if (merging) begin
                disp[dbi] <= (mag[dbi] > disp[dbi]) ? mag[dbi]
                          : ((disp[dbi] > DECAY) ? (disp[dbi] - DECAY) : 8'd0);
                if (dbi == NB-1) merging <= 1'b0;
                else             dbi     <= dbi + 5'd1;
            end

            // ---- Goertzel 更新 ----
            case (st)
                S_IDLE: if (sample_valid) begin
                    xsum <= xsum + $signed(sample);
                    xq   <= hp_x >>> 6;              // 缩到 10bit（-512..511）
                    xacc <= xacc + ((hp_x[23] ? -hp_x : hp_x) >>> 6);   // 累加 |x|
                    bi   <= 5'd0;
                    st   <= S_UA;
                end

                S_UA: begin
                    mu1 <= coef * s1[0];      // 16 x 24
                    mu2 <= K_DAMP * s2[0];    // 阻尼项：极点半径 = r
                    st  <= S_UB;
                end

                S_UB: begin
                    // 队首算完推回队尾，其余整体前移一格
                    for (k = 0; k < NB-1; k = k + 1) begin
                        s1[k] <= s1[k+1];
                        s2[k] <= s2[k+1];
                    end
                    s1[NB-1] <= $signed({{14{xq[9]}}, xq}) + ((mu1 + 40'sd8192) >>> 14)
                                     - ((mu2 + 40'sd8192) >>> 14);
                    s2[NB-1] <= s1[0];

                    if (bi == NB-1) begin
                        bi <= 5'd0;
                        if (blk == BLOCK-1) begin
                            blk <= 11'd0;
                            st  <= S_PA;
                        end else begin
                            blk <= blk + 11'd1;
                            st  <= S_IDLE;
                        end
                    end else begin
                        bi <= bi + 5'd1;
                        st <= S_UA;
                    end
                end

                // ---- 块结束：每个频段算能量、压成 8bit、状态清零 ----
                //  |X|^2 = s1^2 + s2^2 - coef*s1*s2 （漏掉交叉项会让低频段整体抬高）
                S_PA: begin
                    mu1 <= s1[0] * s1[0];
                    mu2 <= s2[0] * s2[0];
                    mu3 <= coef * s1[0];
                    st  <= S_PC;
                end

                S_PC: begin
                    mu4 <= mu3 * s2[0];
                    st  <= S_PB;
                end

                S_PB: begin
                    mag[bi] <= (xacc == 24'd0) ? 8'd0
                             : log8(mu1 + mu2 - ((mu4 + 40'sd8192) >>> 14));
                    for (k = 0; k < NB-1; k = k + 1) begin
                        s1[k] <= s1[k+1];
                        s2[k] <= s2[k+1];
                    end
                    s1[NB-1] <= 24'sd0;
                    s2[NB-1] <= 24'sd0;
                    if (bi == NB-1) begin
                        bi   <= 5'd0;
                        xacc <= 24'd0;          // 本块用完清零，开始统计下一块
                        xmean <= xsum >>> 10;   // 下一块用它做去直流（BLOCK=1024）
                        xsum  <= 32'sd0;
                        // 一次性清零全部状态：旋转"旋入 0"依赖索引完全对齐，
                        // 一旦错位就会残留 => 柱子挂住不动。直接清零最稳。
                        for (k = 0; k < NB; k = k + 1) begin
                            s1[k] <= 24'sd0;
                            s2[k] <= 24'sd0;
                        end
                        st   <= S_IDLE;
                    end else begin
                        bi <= bi + 5'd1;
                        st <= S_PA;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

    // ---------------- 输出 ----------------
    genvar g;
    generate
        for (g = 0; g < NB; g = g + 1) begin : out_bars
            assign bars[g*8 +: 8] = disp[g];
        end
    endgenerate

endmodule
