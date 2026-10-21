// ============================================================================
//  test_pattern_b.v —— 第二路测试图（转场用）：渐变 + 网格 + 移动竖条
// ============================================================================
`timescale 1ns / 1ps

module test_pattern_b #(
    parameter integer HACTIVE = 1280,
    parameter integer VACTIVE = 720
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [11:0] x,
    input  wire [11:0] y,
    output reg  [23:0] rgb
);

    // 垂直渐变 + 64px 网格 + 每帧右移的亮条
    reg [11:0] bar_x;
    reg [11:0] y_d;
    wire       frame_end = (y == VACTIVE - 1) && (y_d != VACTIVE - 1);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            bar_x <= 12'd0;
            y_d   <= 12'd0;
        end else begin
            y_d <= y;
            if (frame_end) begin
                if (bar_x >= HACTIVE - 64) bar_x <= 12'd0;
                else                       bar_x <= bar_x + 12'd16;
            end
        end
    end

    wire [7:0] grad  = y[9:2] + y[8:1];                 // 纵向渐变
    wire       gridx = (x[5:0] == 6'd0) || (x[5:0] == 6'd1);
    wire       gridy = (y[5:0] == 6'd0) || (y[5:0] == 6'd1);
    wire       bar   = (x >= bar_x) && (x < bar_x + 12'd64);

    always @(*) begin
        if (bar)
            rgb = 24'hFF_FF_FF;
        else if (gridx || gridy)
            rgb = 24'h20_28_30;
        else
            rgb = {grad[7:1], grad, 8'hC0};
    end

endmodule
