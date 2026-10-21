// ============================================================================
//  seg7.v —— 6 位共阳数码管动态扫描（段码低有效）
//  用于探针工程的状态显示，可复用到后续各阶段。
// ============================================================================
`timescale 1ns / 1ps

module seg7 #(
    parameter integer CLK_HZ = 50_000_000
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [23:0] value,      // 6 个十六进制位，value[23:20] 为最高位
    input  wire [5:0]  dp_mask,    // 1 = 点亮该位小数点
    output reg  [5:0]  seg_sel,    // 位选，低有效
    output reg  [7:0]  seg_data    // {dp, g, f, e, d, c, b, a}，低有效
);

    // 扫描节拍：每位约 1kHz
    reg [15:0] div;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) div <= 16'd0;
        else        div <= div + 16'd1;
    end

    wire [2:0] dsel = div[15:13];          // 50MHz / 8192 = 6.1kHz，6 位轮询 -> 约 1kHz/位

    reg [3:0] nib;

    always @(*) begin
        case (dsel)
            3'd0: nib = value[3:0];
            3'd1: nib = value[7:4];
            3'd2: nib = value[11:8];
            3'd3: nib = value[15:12];
            3'd4: nib = value[19:16];
            default: nib = value[23:20];
        endcase
    end

    // 十六进制 -> 七段（a..g，低有效）
    function [6:0] hex7;
        input [3:0] h;
        begin
            case (h)
                4'h0: hex7 = 7'b1000000;
                4'h1: hex7 = 7'b1111001;
                4'h2: hex7 = 7'b0100100;
                4'h3: hex7 = 7'b0110000;
                4'h4: hex7 = 7'b0011001;
                4'h5: hex7 = 7'b0010010;
                4'h6: hex7 = 7'b0000010;
                4'h7: hex7 = 7'b1111000;
                4'h8: hex7 = 7'b0000000;
                4'h9: hex7 = 7'b0010000;
                4'hA: hex7 = 7'b0001000;
                4'hB: hex7 = 7'b0000011;
                4'hC: hex7 = 7'b1000110;
                4'hD: hex7 = 7'b0100001;
                4'hE: hex7 = 7'b0000110;
                default: hex7 = 7'b0001110;
            endcase
        end
    endfunction

    always @(*) begin
        if (dsel > 3'd5) begin
            seg_sel  = 6'b111111;
            seg_data = 8'hFF;
        end else begin
            seg_sel  = ~(6'b000001 << dsel);
            seg_data = {~dp_mask[dsel], hex7(nib)};
        end
    end

endmodule
