// ============================================================================
//  bmp_scale.v —— BMP 自适应缩放（2^k 整数缩放，保持宽高比）
//
//  解决的问题：帧缓存里的图片区固定 640x480，原来任何非 640x480 的图都是
//  左上角对齐 + 被裁掉一部分（1280x720 的图只显示左上 1/4）。
//
//  方案：2 的整数次幂缩放 + 居中。
//    - 选最小的 k∈[0,4]，使 (w>>k) <= 640 且 (h>>k) <= 480
//      1280x720 -> k=1 -> 640x360；1920x1080 -> k=2 -> 480x270；640x480 -> k=0 直通
//    - 横向：源列号低 k 位为 0 的像素才输出，目标列 = (sx>>k) + xoff
//    - 纵向：源行号低 k 位为 0 的行才输出，目标行 = (sy>>k) + yoff
//      （bmp_decode 已经把自底向上的行序翻成显示序，这里只按 o_sy 采样）
//    - 居中：xoff=(640-w>>k)/2, yoff=(480-h>>k)/2，全是移位，不需要除法
//
//  为什么必须做"清屏"：缩放后图片往往铺不满 640x480（如 640x360 上下各留 60 行），
//  不写那些行的话会残留上一张图的内容。清屏把整个框写成黑色，跑一次 153600 字。
//
//  不需要行缓存：纵向只做"隔行取"（缩小），不做"插行"（放大），
//  所以本模块是纯流水的，不占 BRAM，也不引入反压。
//  代价：小于 640x480 的图按原尺寸 1:1 居中显示，不放大。
// ============================================================================
`timescale 1ns / 1ps

module bmp_scale #(
    parameter integer DW = 640,       // 目标框宽
    parameter integer DH = 480        // 目标框高
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

    output wire [2:0]  o_k             // 当前缩放级别（调试用）
);

    // ------------------------------------------------------------------
    // 选 k：最小的、能把整幅图塞进框里的 2^k 缩小
    //   w=0（还没解析到表头）时 k=0，不会输出任何像素
    // ------------------------------------------------------------------
    reg [2:0] k;
    always @(*) begin
        if      ((img_w <= DW) && (img_h <= DH))
            k = 3'd0;
        else if (({1'b0, img_w[15:1]} <= DW) && ({1'b0, img_h[15:1]} <= DH))
            k = 3'd1;
        else if (({2'b00, img_w[15:2]} <= DW) && ({2'b00, img_h[15:2]} <= DH))
            k = 3'd2;
        else if (({3'b000, img_w[15:3]} <= DW) && ({3'b000, img_h[15:3]} <= DH))
            k = 3'd3;
        else
            k = 3'd4;
    end

    assign o_k = k;

    wire [15:0] w2 = img_w >> k;
    wire [15:0] h2 = img_h >> k;

    localparam [15:0] DWP = DW;      // integer 参数不能直接位选，先转成位宽明确的常量
    localparam [15:0] DHP = DH;

    // 居中偏移；w2 仍大于 DW 时（超大图 k 被截到 4）退回 0，靠裁切兜底
    wire [11:0] xoff = (w2 >= DWP) ? 12'd0 : ((DWP - w2) >> 1);
    wire [11:0] yoff = (h2 >= DHP) ? 12'd0 : ((DHP - h2) >> 1);

    // 采样掩码：低 k 位为 0 才输出（k=4 时 1<<4 在 4 位里回绕成 0，0-1=15，正确）
    wire [3:0] kmask = (k == 3'd0) ? 4'd0 : ((4'd1 << k) - 4'd1);

    wire       sel_col = ((s_sx[3:0] & kmask) == 4'd0);
    wire       sel_row = ((s_sy[3:0] & kmask) == 4'd0);

    // ------------------------------------------------------------------
    // 清屏
    //   clr_done 之后必须先把 clr 拉低一拍拍，避免上层还没反应过来就重跑一次
    // ------------------------------------------------------------------
    reg        clr_run;
    reg        clr_rearm;        // 1 = 等 clr 落低
    reg [11:0] cx, cy;

    assign clr_busy = clr_run;
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
            end else if (s_we && sel_col && sel_row) begin
                o_we  <= 1'b1;
                o_x   <= xoff + (s_sx >> k);
                o_y   <= yoff + (s_sy >> k);
                o_rgb <= s_rgb;
            end
        end
    end

endmodule
