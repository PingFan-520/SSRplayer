// ============================================================================
//  pattern_src.v —— 上板自检图案源（模拟 BMP 解码器的输出）
//
//  目的：在没有 SD 卡驱动之前，先用内部生成的图案把
//        pattern_src -> frame_buffer -> SDRAM -> 显示 的整条链路打通。
//
//  图案设计成"任何错位都能一眼看出"：
//    - 8 段竖彩条（每段 80 像素）
//    - 每 64 像素一条 2 像素宽的白色网格线
//    - 左上角 32x32 红色方块（判断方向/翻转）
//    - 右下角 32x32 蓝色方块
//
//  时序：每像素 1 拍，写 640x480 共 307200 拍 ≈ 8.2ms @37.5MHz。
//        ready 为低时暂停（frame_buffer 的写 FIFO 满）。
// ============================================================================
`timescale 1ns / 1ps

module pattern_src #(
    parameter integer IMG_W = 640,
    parameter integer IMG_H = 480,
    parameter integer X0    = 320,      // 图片左上角（活动区坐标）
    parameter integer Y0    = 120
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        start,           // 单拍脉冲：开始写一帧
    input  wire        ready,           // frame_buffer.wr_ready
    output wire        en,
    output wire [11:0] x,
    output wire [11:0] y,
    output wire [15:0] rgb,
    output wire        run,             // 正在写
    output wire        done             // 写完（电平保持）
);

    reg [11:0] cx, cy;
    reg        busy;
    reg        fin;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            cx   <= 12'd0;
            cy   <= 12'd0;
            busy <= 1'b0;
            fin  <= 1'b0;
        end else if (start) begin
            cx   <= 12'd0;
            cy   <= 12'd0;
            busy <= 1'b1;
            fin  <= 1'b0;
        end else if (busy && ready) begin
            if (cx == IMG_W - 1) begin
                cx <= 12'd0;
                if (cy == IMG_H - 1) begin
                    busy <= 1'b0;
                    fin  <= 1'b1;
                end else begin
                    cy <= cy + 12'd1;
                end
            end else begin
                cx <= cx + 12'd1;
            end
        end
    end

    assign en   = busy & ready;
    assign x    = X0 + cx;
    assign y    = Y0 + cy;
    assign run  = busy;
    assign done = fin;

    // ------------------------------------------------------------------
    // 图案
    // ------------------------------------------------------------------
    reg [15:0] bar;
    always @(*) begin
        case (cx[9:7])
            3'd0:    bar = 16'hFFFF;    // 白
            3'd1:    bar = 16'hFFE0;    // 黄
            3'd2:    bar = 16'h07FF;    // 青
            3'd3:    bar = 16'h07E0;    // 绿
            3'd4:    bar = 16'hF81F;    // 品红
            3'd5:    bar = 16'hF800;    // 红
            3'd6:    bar = 16'h001F;    // 蓝
            default: bar = 16'h0841;    // 深灰（不是纯黑，便于和黑边区分）
        endcase
    end

    wire grid   = (cx[5:0] < 6'd2) || (cy[5:0] < 6'd2);
    wire corner = (cx < 12'd32 && cy < 12'd32) ||
                  (cx >= IMG_W - 32 && cy >= IMG_H - 32);

    assign rgb = (cx < 12'd32 && cy < 12'd32) ? 16'hF800 :    // 左上红
                 (cx >= IMG_W - 32 && cy >= IMG_H - 32) ? 16'h001F :  // 右下蓝
                 grid ? 16'hFFFF : bar;

endmodule
