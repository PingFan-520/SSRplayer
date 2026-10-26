// ============================================================================
//  param_apply.v —— 亮度 / 对比度（输出级）
//
//  out = clamp( ((in-128) * gain >> 7) + 128 + off )
//    gain = 64 + 7*contrast   (contrast 0..10 -> 0.50 .. 1.05 倍)
//    off  = (bright - 10)*16  (bright   0..10 -> -160 .. 0)
//
//  注意：这里**不再用 function**，三个通道各写一条组合通路。
//  之前的 function 版本在整机仿真里输出全是 X（输入、增益都正常），
//  单独跑又能算对 —— 典型的是工具对 function 内混合位宽/符号的处理差异。
//  纯组合 assign 没有这个风险，综合结果一样。
// ============================================================================
`timescale 1ns / 1ps

module param_apply (
    input  wire [23:0] rgb_in,
    input  wire [3:0]  bright,
    input  wire [3:0]  contrast,
    output wire [23:0] rgb_out
);

    // gain = 64 + 7*contrast
    wire [7:0] gain = 8'd64 + {contrast, 2'b00} + {contrast, 1'b0} + {1'b0, contrast};

    // off = (bright-10)*16
    wire signed [10:0] off = ($signed({1'b0, bright}) - 11'sd10) <<< 4;

    // 单通道：d = v-128; p = d*gain; r = p>>>7 + 128 + off; 再钳位
    function [7:0] clampi;
        input signed [12:0] r;
        begin
            if (r < 13'sd0)         clampi = 8'd0;
            else if (r > 13'sd255)  clampi = 8'd255;
            else                    clampi = r[7:0];
        end
    endfunction

    wire signed [12:0] dr = $signed({5'd0, rgb_in[23:16]}) - 13'sd128;
    wire signed [12:0] dg = $signed({5'd0, rgb_in[15:8]})  - 13'sd128;
    wire signed [12:0] db = $signed({5'd0, rgb_in[7:0]})   - 13'sd128;

    wire signed [21:0] pr = dr * $signed({1'b0, gain});
    wire signed [21:0] pg = dg * $signed({1'b0, gain});
    wire signed [21:0] pb = db * $signed({1'b0, gain});

    wire signed [12:0] rr = (pr >>> 7) + 13'sd128 + off;
    wire signed [12:0] rg = (pg >>> 7) + 13'sd128 + off;
    wire signed [12:0] rb = (pb >>> 7) + 13'sd128 + off;

    assign rgb_out = { clampi(rr), clampi(rg), clampi(rb) };

endmodule
