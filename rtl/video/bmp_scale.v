// ============================================================================
//  bmp_scale.v —— BMP 自适应缩放（整数缩放 + 三种显示模式）
//
//  帧缓存里的图片区 960x540（显示时 4:3 上采样铺满 1280x720）。
//  本模块把任意尺寸的 BMP 映射进这个框：
//
//   mode = 0  FIT     等比缩小 + 居中，整幅图可见（可能有黑边）
//           1280x720 -> 960x540 精确 3/4 抽取（满屏，无黑边）
//           1920x1080 -> 960x540 精确 1/2 抽取（满屏）
//           其它尺寸 -> 2^k 缩小 + 居中
//   mode = 1  FILL    1:1 中心裁切，铺满整个框（四边可能被裁掉）
//           1280x720 -> 取中间 640x480 区域，放大填满画面
//   mode = 2  STRETCH 水平缩到刚好铺满宽度，垂直 1:1 中心裁切
//           1280x720 -> 整幅宽度压到 640，纵向取中间 480 行（无黑边）
//
//  实现：每轴独立的 2^k 缩放指数 + 有符号居中偏移（负偏移 = 裁切）。
//    横向：源列号低 kx 位为 0 才输出，目标列 = xoff + (sx>>kx)
//    纵向：源行号低 ky 位为 0 才输出，目标行 = yoff + (sy>>ky)
//    越界的目标坐标直接不输出（对负偏移即裁切）
//  全程移位 + 有符号加法，无除法/无乘法/无行缓存 -> 不占 BRAM、不反压。
//
//  限制：放大做不到。纵向插行需要行缓存（640x16bit x 2 行 ≈ 2 块 M9K），
//        而这块板 BRAM 余量紧（曾因读 FIFO 加深导致布线失败），故不做。
//        所以小于 640x480 的图在 FILL/STRETCH 下仍是 1:1 居中。
//
//  为什么必须做"清屏"：缩放后图片往往铺不满 640x480，
//  不写那些行会残留上一张图的内容。清屏把整个框写成黑色，跑一次 153600 字。
// ============================================================================
`timescale 1ns / 1ps

module bmp_scale #(
    parameter integer DW = 960,       // 目标框宽
    parameter integer DH = 540        // 目标框高
)(
    input  wire        clk,
    input  wire        rst,

    // ---------------- 源像素（bmp_decode 输出，按文件顺序到达） ----------------
    input  wire        s_we,
    input  wire [11:0] s_sx,
    input  wire [11:0] s_sy,
    input  wire [15:0] s_rgb,
    input  wire [15:0] img_w,          // 表头解析出的尺寸（hdr 后有效）
    input  wire [15:0] img_h,
    input  wire [1:0]  mode,           // 0=FIT 1=FILL 2=STRETCH（菜单"缩放"）

    // ---------------- 清屏 ----------------
    input  wire        clr,            // 电平；需先拉低一次才能再次触发
    output reg         clr_done,       // 清屏完成（单拍）
    output wire        clr_busy,

    // ---------------- 输出（框内坐标 0..DW-1 / 0..DH-1） ----------------
    input  wire        o_rdy,          // 下游可接收（帧缓存 wr_ready）
    output reg         o_we,
    output reg  [11:0] o_x,
    output reg  [11:0] o_y,
    output reg  [15:0] o_rgb,

    output wire [2:0]  o_k,            // 当前水平缩放级别（调试用）
    output wire        o_busy,         // 1 = 下游满 / 有像素待发，上游应停止送数
    output wire        o_full          // 1 = 这张图缩放后正好铺满整个框（无黑边）
);

    localparam [15:0] DWP = DW;
    localparam [15:0] DHP = DH;

    // ------------------------------------------------------------------
    // 缩放指数选择
    // ------------------------------------------------------------------
    wire [15:0] w1 = img_w >> 1, w2 = img_w >> 2, w3 = img_w >> 3, w4 = img_w >> 4;
    wire [15:0] h1 = img_h >> 1, h2 = img_h >> 2, h3 = img_h >> 3, h4 = img_h >> 4;

    // FIT：两轴同一个 k，保证整幅图都塞进框
    reg [2:0] k_fit;
    always @(*) begin
        if      ((img_w <= DWP) && (img_h <= DHP)) k_fit = 3'd0;
        else if ((w1     <= DWP) && (h1     <= DHP)) k_fit = 3'd1;
        else if ((w2     <= DWP) && (h2     <= DHP)) k_fit = 3'd2;
        else if ((w3     <= DWP) && (h3     <= DHP)) k_fit = 3'd3;
        else                                         k_fit = 3'd4;
    end

    // STRETCH：只看宽度，缩到宽度刚好 <= 框宽
    reg [2:0] k_w;
    always @(*) begin
        if      (img_w <= DWP) k_w = 3'd0;
        else if (w1     <= DWP) k_w = 3'd1;
        else if (w2     <= DWP) k_w = 3'd2;
        else if (w3     <= DWP) k_w = 3'd3;
        else                    k_w = 3'd4;
    end

    wire [2:0] kx = (mode == 2'd0) ? k_fit : ((mode == 2'd2) ? k_w : 3'd0);
    wire [2:0] ky = (mode == 2'd0) ? k_fit : 3'd0;

    assign o_k = kx;

    // ------------------------------------------------------------------
    // 下游反压
    //   原来 px_ok 不看 o_rdy：帧缓存写 FIFO 一满，像素就被静默丢掉，
    //   丢掉一个偶数像素 → 后一个奇数像素和它配对，写到错误的字里，
    //   画面上就是"零散的错位像素点"。
    //   这里改成：o_rdy=0 时把像素存进 1 深保持寄存器，同时 o_busy 拉高，
    //   上层用它把字节流停住（bmp_decode 是按字节推进的，停字节就不会再出像素）。
    // ------------------------------------------------------------------
    reg        hold;
    reg [11:0] hx, hy;
    reg [15:0] hrgb;

    assign o_busy = ~o_rdy | hold;

    // ------------------------------------------------------------------
    // 3/4 精确抽取：源正好是框的 4/3（1280x720 -> 960x540）
    //   每 4 个源像素丢掉第 4 个，目标列 = (sx>>2)*3 + sx[1:0]
    //   纵向同理，每 4 行丢 1 行。SD 送来的像素本来就是流水，丢掉即可。
    // ------------------------------------------------------------------
    wire [15:0] DW43 = (DW / 3) * 4;
    wire [15:0] DH43 = (DH / 3) * 4;
    wire        use34 = (mode == 2'd0) && (img_w == DW43) && (img_h == DH43);

    wire [11:0] tx34 = ({2'b00, s_sx[11:2]} << 1) + {2'b00, s_sx[11:2]} + {10'd0, s_sx[1:0]};
    wire [11:0] ty34 = ({2'b00, s_sy[11:2]} << 1) + {2'b00, s_sy[11:2]} + {10'd0, s_sy[1:0]};

    wire [15:0] ws = use34 ? DWP : (img_w >> kx);      // 缩放后宽
    wire [15:0] hs = use34 ? DHP : (img_h >> ky);      // 缩放后高

    // 居中偏移（有符号）：源比框大时为负 -> 裁切
    wire signed [12:0] ox_s = ($signed({1'b0, DWP}) - $signed({1'b0, ws})) >>> 1;
    wire signed [12:0] oy_s = ($signed({1'b0, DHP}) - $signed({1'b0, hs})) >>> 1;

    // 铺满判断：放大后的尺寸 >= 目标框就没有黑边，整块都会被覆盖。
    // 上层用它决定"换图时还要不要清屏"——满屏图直接覆盖旧图，不用清。
    assign o_full = (ws >= DWP) && (hs >= DHP);

    // 采样掩码：低 k 位为 0 才输出（k=4 时 1<<4 在 4 位里回绕成 0，0-1=15，正确）
    wire [3:0] kmask_x = (kx == 3'd0) ? 4'd0 : ((4'd1 << kx) - 4'd1);
    wire [3:0] kmask_y = (ky == 3'd0) ? 4'd0 : ((4'd1 << ky) - 4'd1);

    wire sel_col = use34 ? (s_sx[1:0] != 2'd3) : ((s_sx[3:0] & kmask_x) == 4'd0);
    wire sel_row = use34 ? (s_sy[1:0] != 2'd3) : ((s_sy[3:0] & kmask_y) == 4'd0);

    // 目标坐标（有符号）+ 越界裁切
    wire signed [12:0] tx_s = $signed({1'b0, (s_sx >> kx)}) + ox_s;
    wire signed [12:0] ty_s = $signed({1'b0, (s_sy >> ky)}) + oy_s;

    wire in_x = use34 ? 1'b1 : ((tx_s >= 13'sd0) && (tx_s < $signed({1'b0, DWP})));
    wire in_y = use34 ? 1'b1 : ((ty_s >= 13'sd0) && (ty_s < $signed({1'b0, DHP})));

    wire [11:0] px_tx = use34 ? tx34 : tx_s[11:0];
    wire [11:0] px_ty = use34 ? ty34 : ty_s[11:0];

    wire px_ok = s_we & sel_col & sel_row & in_x & in_y;

    // ------------------------------------------------------------------
    // 清屏
    // ------------------------------------------------------------------
    reg        clr_run;
    reg        clr_rearm;        // 1 = 等 clr 落低
    reg [11:0] cx, cy;

    assign clr_busy  = clr_run;
    wire   clr_start = clr & ~clr_run & ~clr_rearm;

    // ------------------------------------------------------------------
    // 输出（清屏优先于像素流水）
    // ------------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            o_we     <= 1'b0;
            o_x      <= 12'd0;
            o_y      <= 12'd0;
            o_rgb    <= 16'd0;
            clr_run  <= 1'b0;
            clr_rearm<= 1'b0;
            clr_done <= 1'b0;
            cx       <= 12'd0;
            cy       <= 12'd0;
            hold     <= 1'b0;
            hx       <= 12'd0;
            hy       <= 12'd0;
            hrgb     <= 16'd0;
        end else begin
            o_we     <= 1'b0;
            clr_done <= 1'b0;

            if (!clr) clr_rearm <= 1'b0;

            if (clr_run) begin
                if (o_rdy) begin
                    o_we  <= 1'b1;
                    o_x   <= cx;
                    o_y   <= cy;
                    o_rgb <= 16'd0;

                    if (cx == DW - 1) begin
                        cx <= 12'd0;
                        if (cy == DH - 1) begin
                            cy        <= 12'd0;
                            clr_run   <= 1'b0;
                            clr_rearm <= 1'b1;
                            clr_done  <= 1'b1;
                        end else begin
                            cy <= cy + 12'd1;
                        end
                    end else begin
                        cx <= cx + 12'd1;
                    end
                end
            end else if (clr_start) begin
                clr_run <= 1'b1;
                cx      <= 12'd0;
                cy      <= 12'd0;
            end else if (hold) begin
                if (o_rdy) begin
                    o_we  <= 1'b1;
                    o_x   <= hx;
                    o_y   <= hy;
                    o_rgb <= hrgb;
                    hold  <= 1'b0;
                end
            end else if (px_ok) begin
                if (o_rdy) begin
                    o_we  <= 1'b1;
                    o_x   <= px_tx;
                    o_y   <= px_ty;
                    o_rgb <= s_rgb;
                end else begin
                    hx   <= px_tx;
                    hy   <= px_ty;
                    hrgb <= s_rgb;
                    hold <= 1'b1;
                end
            end
        end
    end

endmodule
