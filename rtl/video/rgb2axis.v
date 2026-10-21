// ============================================================================
//  rgb2axis.v —— RGB/DE/VS 转 AXIS 视频流（参数化行宽）
//
//  替换参考工程的 video_rgb_to_axis_640x480（原版把 639 写死）：
//      rgb2axis #(.HACTIVE(1280)) u_rgb2axis (...)
// ============================================================================
`timescale 1ns / 1ps

module rgb2axis #(
    parameter integer HACTIVE = 1280
)(
    input  wire        I_clk,
    input  wire        I_rst,
    input  wire        I_vs,
    input  wire        I_de,
    input  wire [23:0] I_rgb,

    output reg         O_video_user,
    output reg         O_video_valid,
    output reg         O_video_last,
    output reg  [23:0] O_video_data
);

    reg        S_vs_1d;
    reg        S_de_1d;
    reg        S_frame_arm;
    reg [11:0] S_x_cnt;

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            S_vs_1d       <= 1'b0;
            S_de_1d       <= 1'b0;
            S_frame_arm   <= 1'b1;
            S_x_cnt       <= 12'd0;
            O_video_user  <= 1'b0;
            O_video_valid <= 1'b0;
            O_video_last  <= 1'b0;
            O_video_data  <= 24'd0;
        end else begin
            S_vs_1d <= I_vs;
            S_de_1d <= I_de;

            O_video_user  <= 1'b0;
            O_video_valid <= I_de;
            O_video_last  <= 1'b0;
            O_video_data  <= I_rgb;

            // 任意一次 VS 跳变后，把下一次有效行的首像素当作 SOF
            if (S_vs_1d != I_vs)
                S_frame_arm <= 1'b1;

            if (I_de) begin
                if (!S_de_1d) begin
                    S_x_cnt <= 12'd1;          // 行首像素计为第 1 个
                    if (S_frame_arm) begin
                        O_video_user <= 1'b1;
                        S_frame_arm  <= 1'b0;
                    end
                end else begin
                    S_x_cnt <= S_x_cnt + 12'd1;
                end

                // 第 HACTIVE 个像素上打 last
                if (S_x_cnt == HACTIVE - 1)
                    O_video_last <= 1'b1;
            end else begin
                S_x_cnt <= 12'd0;
            end
        end
    end

endmodule
