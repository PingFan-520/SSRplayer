// ============================================================================
//  alpha_blend.v —— 8 档 alpha 混合（0..8，共 9 档；8 = 完全不透明）
//      out = vid + ((osd - vid) * a) >> 3
//  用移位加法实现，不占 DSP。
// ============================================================================
`timescale 1ns / 1ps

module alpha_blend (
    input  wire [23:0] vid_rgb,
    input  wire [23:0] osd_rgb,
    input  wire [3:0]  alpha,
    output wire [23:0] out_rgb
);

    function [7:0] mix1;
        input [7:0] v;
        input [7:0] o;
        input [3:0] a;
        reg signed [10:0] dv;
        reg signed [14:0] pr;
        reg signed [10:0] rs;
        begin
            dv = $signed({3'b000, o}) - $signed({3'b000, v});
            pr = dv * $signed({7'b0000000, a});
            rs = $signed({3'b000, v}) + (pr >>> 3);

            if (rs < 0)
                mix1 = 8'd0;
            else if (rs > 255)
                mix1 = 8'd255;
            else
                mix1 = rs[7:0];
        end
    endfunction

    assign out_rgb = { mix1(vid_rgb[23:16], osd_rgb[23:16], alpha),
                       mix1(vid_rgb[15:8],  osd_rgb[15:8],  alpha),
                       mix1(vid_rgb[7:0],   osd_rgb[7:0],   alpha) };

endmodule
