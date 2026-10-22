// ============================================================================
//  bmp_decode.v —— BMP(24bit, 无压缩) 解码器
//
//  输入：来自 SD 卡的字节流（从文件第 0 字节开始，顺序到达）
//  输出：RGB565 像素 + 屏幕坐标（居中放在 FB_WIDTH x FB_HEIGHT 的画布里）
//
//  支持：
//    - 'BM' 文件头，bfOffBits 任意（自动跳过调色板/扩展头）
//    - 24bit 未压缩；biHeight > 0 为自底向上，< 0 为自顶向下
//    - 行按 4 字节对齐
//  不支持：8/16/32bit、RLE 压缩（hdr_ok=0 时直接丢弃数据）
//
//  字节流假设：相邻字节至少间隔 1 个时钟（SD SPI 实际约 30 个时钟/字节），
//  因此本模块不做反压，s_ready 恒为 1。
// ============================================================================
`timescale 1ns / 1ps

module bmp_decode #(
    parameter integer FB_WIDTH  = 1280,
    parameter integer FB_HEIGHT = 720
)(
    input  wire        clk,
    input  wire        rst,

    // 字节流
    input  wire [7:0]  s_data,
    input  wire        s_valid,
    output wire        s_ready,

    // 像素输出（o_we 单拍）
    output reg         o_we,
    output reg  [11:0] o_x,
    output reg  [11:0] o_y,
    output reg  [15:0] o_rgb565,

    output reg         o_frame_done,   // 一张图解码完成（单拍）
    output reg  [15:0] o_img_w,
    output reg  [15:0] o_img_h,
    output reg         o_hdr_ok
);

    assign s_ready = 1'b1;

    localparam [3:0] S_HDR  = 4'd0,
                     S_SKIP = 4'd1,
                     S_ROW  = 4'd2,
                     S_PAD  = 4'd3,
                     S_DONE = 4'd4,
                     S_BAD  = 4'd5;

    reg [7:0]  hdr [0:63];
    reg [5:0]  hcnt;
    reg [31:0] skip_cnt;
    reg [15:0] img_w, img_h;      // img_h 已取绝对值
    reg        top_down;
    reg [15:0] x0, y0;

    reg [3:0]  state;
    reg [15:0] row;
    reg [15:0] col;
    reg [1:0]  bcnt;
    reg [23:0] pix;
    reg [1:0]  pad_left;

    wire [15:0] row_pad = (4 - ((img_w * 16'd3) & 16'd3)) & 16'd3;
    wire [15:0] scr_y   = top_down ? (y0 + row) : (y0 + img_h - 16'd1 - row);

    function [15:0] to565;
        input [7:0] r, g, b;
        begin
            to565 = {r[7:3], g[7:2], b[7:3]};
        end
    endfunction

    // 解析出的临时值
    reg [15:0] h_raw;
    reg [15:0] h_abs;
    reg [31:0] off_raw;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            hcnt         <= 6'd0;
            skip_cnt     <= 32'd0;
            img_w        <= 16'd0;
            img_h        <= 16'd0;
            top_down     <= 1'b0;
            x0           <= 16'd0;
            y0           <= 16'd0;
            state        <= S_HDR;
            row          <= 16'd0;
            col          <= 16'd0;
            bcnt         <= 2'd0;
            pix          <= 24'd0;
            pad_left     <= 2'd0;
            o_we         <= 1'b0;
            o_x          <= 12'd0;
            o_y          <= 12'd0;
            o_rgb565     <= 16'd0;
            o_frame_done <= 1'b0;
            o_img_w      <= 16'd0;
            o_img_h      <= 16'd0;
            o_hdr_ok     <= 1'b0;
            h_raw        <= 16'd0;
            h_abs        <= 16'd0;
            off_raw      <= 32'd0;
        end else begin
            o_we         <= 1'b0;
            o_frame_done <= 1'b0;

            if (s_valid) begin
                case (state)
                // ----------------------------------------------
                S_HDR: begin
                    hdr[hcnt] <= s_data;
                    if (hcnt == 6'd53) begin
                        off_raw  = {hdr[13], hdr[12], hdr[11], hdr[10]};
                        h_raw    = {hdr[23], hdr[22]};
                        top_down <= hdr[25][7];
                        h_abs    = hdr[25][7] ? (~h_raw + 16'd1) : h_raw;

                        if (hdr[0] != 8'h42 || hdr[1] != 8'h4D ||
                            (hdr[29] != 8'd0) || (hdr[28] != 8'd24) ||
                            (hdr[31] != 8'd0) || (hdr[30] != 8'd0)) begin
                            o_hdr_ok <= 1'b0;
                            state    <= S_BAD;
                        end else begin
                            img_w    <= {hdr[19], hdr[18]};
                            img_h    <= h_abs;
                            o_img_w  <= {hdr[19], hdr[18]};
                            o_img_h  <= h_abs;
                            o_hdr_ok <= 1'b1;
                            x0       <= (FB_WIDTH  - {hdr[19], hdr[18]}) >> 1;
                            y0       <= (FB_HEIGHT - h_abs) >> 1;
                            skip_cnt <= off_raw - 32'd54;
                            // bfOffBits 正好等于 54 时，下一个字节就是像素数据
                            state    <= (off_raw > 32'd54) ? S_SKIP : S_ROW;
                        end
                    end else begin
                        hcnt <= hcnt + 6'd1;
                    end
                end
                // ----------------------------------------------
                S_SKIP: begin
                    // 本字节是最后一个填充字节，切到像素数据，不再多消耗
                    if (skip_cnt <= 32'd1) begin
                        state <= S_ROW;
                        col   <= 16'd0;
                        bcnt  <= 2'd0;
                        row   <= 16'd0;
                    end else begin
                        skip_cnt <= skip_cnt - 32'd1;
                    end
                end
                // ----------------------------------------------
                S_ROW: begin
                    if (bcnt == 2'd0) begin
                        pix[7:0] <= s_data;              // B
                        bcnt     <= 2'd1;
                    end else if (bcnt == 2'd1) begin
                        pix[15:8] <= s_data;             // G
                        bcnt      <= 2'd2;
                    end else begin
                        bcnt     <= 2'd0;
                        o_we     <= 1'b1;
                        o_x      <= x0 + col;
                        o_y      <= scr_y;
                        o_rgb565 <= to565(s_data, pix[15:8], pix[7:0]);   // R = s_data

                        if (col == img_w - 16'd1) begin
                            col      <= 16'd0;
                            pad_left <= row_pad[1:0];
                            if (row_pad != 16'd0)
                                state <= S_PAD;
                            else if (row == img_h - 16'd1) begin
                                o_frame_done <= 1'b1;
                                state        <= S_DONE;
                            end else begin
                                row   <= row + 16'd1;
                                state <= S_ROW;
                            end
                        end else begin
                            col <= col + 16'd1;
                        end
                    end
                end
                // ----------------------------------------------
                S_PAD: begin
                    if (pad_left <= 2'd1) begin
                        pad_left <= 2'd0;
                        if (row == img_h - 16'd1) begin
                            o_frame_done <= 1'b1;
                            state        <= S_DONE;
                        end else begin
                            row   <= row + 16'd1;
                            state <= S_ROW;
                        end
                    end else begin
                        pad_left <= pad_left - 2'd1;
                    end
                end
                // ----------------------------------------------
                S_DONE: ;
                S_BAD:  ;
                default: state <= S_HDR;
                endcase
            end
        end
    end

endmodule
