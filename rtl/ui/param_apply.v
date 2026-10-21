// ============================================================================
//  param_apply.v —— 亮度 / 对比度（输出级）
//
//  out = clamp( ((in-128) * gain >> 7) + 128 + off )
//    gain = 64 + 7*contrast   (contrast 0..10 -> 0.50 .. 1.05 倍)
//    off  = (bright - 10)*16  (bright   0..10 -> -160 .. 0)
// ============================================================================
`timescale 1ns / 1ps

module param_apply (
    input  wire [23:0] rgb_in,
    input  wire [3:0]  bright,
    input  wire [3:0]  contrast,
    output wire [23:0] rgb_out
);

    wire [7:0] gain = 8'd64 + {contrast, 2'b00} + {contrast, 1'b0} + {1'b0, contrast};

    wire signed [9:0] off = ($signed({1'b0, bright}) - 10) <<< 4;

    function [7:0] adj;
        input [7:0] v;
        reg signed [9:0]  d;
        reg signed [17:0] p;
        reg signed [11:0] r;
        begin
            d = $signed({2'b00, v}) - 128;
            p = d * $signed({4'b0000, gain});
            r = (p >>> 7) + 128 + off;

            if (r < 0)        adj = 8'd0;
            else if (r > 255) adj = 8'd255;
            else              adj = r[7:0];
        end
    endfunction

    assign rgb_out = { adj(rgb_in[23:16]), adj(rgb_in[15:8]), adj(rgb_in[7:0]) };

endmodule
