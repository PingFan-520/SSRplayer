// ============================================================================
//  cfg_latch.v —— 参数影子寄存器：只在 cfg_commit（帧首单拍）提交
//
//  菜单里的按键随时可能落下，若参数立刻改变，当前这一帧会被"撕开"
//  （上半帧还是旧亮度、下半帧已经是新亮度）。这里把菜单写出的
//  cfg_* 先存一份影子，等 vsync 边界再统一生效。
// ============================================================================
`timescale 1ns / 1ps

module cfg_latch (
    input  wire       clk,
    input  wire       rst,
    input  wire       commit,        // 帧首单拍

    input  wire [1:0] in_trans,
    input  wire [3:0] in_bright,
    input  wire [3:0] in_contrast,
    input  wire [1:0] in_scale,
    input  wire [2:0] in_mus,
    input  wire       in_auto,
    input  wire [3:0] in_vol,
    input  wire       in_meter,
    input  wire [2:0] in_hold,
    input  wire       in_style,

    output reg  [1:0] trans,
    output reg  [3:0] bright,
    output reg  [3:0] contrast,
    output reg  [1:0] scale,
    output reg  [2:0] mus,
    output reg        auto_en,
    output reg  [3:0] vol,
    output reg        meter,
    output reg  [2:0] hold,
    output reg        style,

    output reg  [3:0] ver              // 参数版本号，调试用
);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            trans    <= 2'd0;
            bright   <= 4'd10;
            contrast <= 4'd10;
            scale    <= 2'd0;
            mus      <= 3'd0;      // 上电默认 OFF（不放内置音乐）
            auto_en  <= 1'b0;      // 上电不自动轮播
            meter    <= 1'b0;      // 上电默认关频谱
            hold     <= 3'd1;      // 默认 5 秒
            style    <= 1'b0;      // 默认底部条形
            vol      <= 4'd6;
            ver      <= 4'd0;
        end else if (commit) begin
            trans    <= in_trans;
            bright   <= in_bright;
            contrast <= in_contrast;
            scale    <= in_scale;
            mus      <= in_mus;
            auto_en  <= in_auto;
            meter    <= in_meter;
            hold     <= in_hold;
            style    <= in_style;
            vol      <= in_vol;
            ver      <= ver + 4'd1;
        end
    end

endmodule
